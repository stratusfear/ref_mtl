# ref_mtl — Metal 4 renderer for Yamagi Quake II

A native **Metal 4** rendering backend plugin (`ref_mtl.dylib`) for
[Yamagi Quake II](https://www.yquake2.net/), modeled on the upstream
`ref_vk` (Vulkan) renderer. It is loaded by the host at runtime via the
`vid_renderer` cvar — no source changes to the host are required, and a
failed or missing plugin can never brick the game (the host falls back
through `gl3` → `gles3` → `gl1` → `gles1` → `soft`).

## Requirements

- **macOS 26+** (Metal 4 is a macOS 26 feature)
- **Apple silicon** (M1+ / A14+; Metal 4 and MSL 3.2 are Apple-silicon only)
- **Xcode 26+** with the macOS 26 SDK (Metal 4 headers, used for
  `MTL4Compiler` runtime shader compilation; command encoding uses the
  classic Metal queue/encoder API — see the Bug C note below)
- **SDL 3** (primary target) — the Makefile also supports SDL 2 via
  compile-time checks; the plugin reports its SDL major version as
  `framework_version` in the handshake

## Build

```sh
make            # -> release/ref_mtl.dylib
# make DEBUG=1  # -O0 + debug symbols
# make VERBOSE=1
```

Place the resulting `ref_mtl.dylib` **in the same directory as the
`quake2` binary** (the host looks for renderers next to the executable).

## Usage

```cfg
set vid_renderer "mtl"
vid_restart
```

or from the command line: `quake2 +vid_renderer mtl` (note: command-line
cvar sets run *after* video init, so they take effect on the next
`vid_restart`; a config file is the reliable way to select the renderer
at startup — that is why `tools/fix_verify.sh` keeps its `mtl_w0_test`
config as the selection mechanism, adds `+set vid_renderer mtl` belt-
and-braces, and fails the smoke unless the ref_mtl init banner shows up
in the log).

### Handshake / compatibility checks

The host (`VID_LoadRenderer`) performs two checks after `GetRefAPI`:

1. `api_version` must equal the host's `API_VERSION` (currently **8**,
   see `src/common/header/ref_api.h`).
2. `framework_version` (the SDL major version the plugin was built
   against) must equal the host's own SDL major version.

On mismatch the host prints e.g.
`ref_mtl.dylib has incompatible api_version 9!` (or
`... incompatible sdl_version 3!`) and falls back to the next renderer
in its order list. This is expected, safe behavior — e.g. an SDL 3
plugin next to an SDL 2 host.

### Runtime validation (Metal)

Apple's Metal validation layers must be enabled **before launch** via
environment variables (they cannot be toggled at runtime):

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 ./quake2
```

## Current status: W7 (MSAA / `r_msaa_samples` parity) — complete

- Full 27-slot `refexport_t` ABI implemented and load-tested against a
  freshly built SDL 3 host (`API_VERSION` 8).
- `RE_InitContext` creates the Metal 4 device and a **classic
  `MTLCommandQueue`**, plus the SDL Metal view + `CAMetalLayer`
  (`BGRA8Unorm` non-sRGB — the shaders emit final display values, same
  convention as `ref_vk`'s `B8G8R8A8_UNORM` swapchain; `framebufferOnly
  =YES`; `maximumDrawableCount` 3, Retina `contentsScale`). The
  device-side objects survive mode changes; `ShutdownContext` tears down
  only the view/layer, `RE_Shutdown` releases everything.
- Frame sequence: `BeginFrame` (CPU gate on three `slot_busy` flags
  cleared by command-buffer completion handlers, (re)create the
  offscreen `scene_texture` on size change, `nextDrawable`) →
  `RenderFrame` (world pass: clear color/depth + BSP world into
  `scene_texture`) → `EndWorldRenderpass` (true) → 2D UI pass (lazily
  opened by the first UI draw, `loadAction=LOAD`, no depth attachment,
  also into `scene_texture`) → `EndFrame` (present pass into the
  drawable sampling `scene_texture`, `presentDrawable`, then `commit`).
- **W2: runtime shader compilation and the first textured quad.**
  `R_InitShaders` creates an `MTL4Compiler`, compiles the embedded MSL
  3.2 sources into libraries, and builds the render pipelines with the
  classic `newRenderPipelineStateWithDescriptor:` +
  `MTLRenderPipelineDescriptor`, taking the shader functions from the
  compiler-built `MTLLibrary`. Bindings use classic encoder buffers
  (vertex stage_in buffers + per-stage `setVertex*`/`setFragment*`).
- **Metal 4 queue status.** ref_mtl uses the MTL4 *compiler* (library +
  pipeline creation) but drives all work on a classic command queue.
  The MTL4 command queue / allocators / argument tables / residency
  sets / shared event were removed as the mitigation for Bug C (see
  below); `tools/bugc_repro/` contains the standalone reproducer and
  the bisect matrix that pin the defect to MTL4-executed passes whose
  render target is an app-created texture.
- **W3: BSP world.** Portals/vis culling, plain + lightmapped surface
  chains with per-frame vertex/UBO rings (three slots, allocator-backed
  ring buffers), lightstyles, sky (`skytexture` path), water/slimesky,
  `mtl_showtris` (`r_fullbright` is not registered — ref_vk registers
  it but never reads it, dead there too; see the round-8 status table).
- **W4: CPU lightmaps + dynamic lights.** Static lightmap atlas pages
  uploaded once; per-page dynamic copies re-encoded when dlights touch
  them (`mtl_dynamic`), dlight additive blend pass
  (`mtl_flashblend`), `R_PushDlights` before `R_SetupFrame` (matching
  `ref_vk` frame order).
- **W5a–W5d: alias models, sprites, particles, 2D UI.** Alias/frame
  interpolation (`r_lerpmodels`), sprites (oriented + `MTL_DRAW2D`
  fixed-facing), particles (point + textured; the view-flash blend
  cvar was `mtl_polyblend` there, the shared `r_polyblend` since O4), and the
  2D UI pass: pics (`DrawStretchPic`), conchars via an 8×8 atlas,
  crosshair, fades, HUD statusbar icons drawn as individual quads.
- **Bug B (superseded): intermittent magenta corruption under blended
  UI draws.** Symptom: fresh processes randomly (~80% of base1 runs) drew
  constant-value magenta under the HUD icon/crosshair quads and one
  small triangle; CPU-side texture scans were byte-identical to clean
  runs, and with `framebufferOnly=NO` the drawable's own bytes read
  back clean. A/B in one binary: 10/12 buggy captures with
  `framebufferOnly=YES` vs 0/12 with `NO`. The original root-cause note
  (drawable private-storage lifetime) was wrong — this was the same
  system-level corruption later isolated as Bug C; `framebufferOnly=NO`
  was only a rate-reducing workaround. With the classic-queue port,
  `framebufferOnly=YES` is back and the corruption is gone.
- **Bug C (mitigated; Apple Feedback drafted in `tools/bugc_repro/
  FEEDBACK_DRAFT.md`, not filed): intermittent
  constant-(234,51,247) display corruption.** With an MTL4 command
  queue executing render passes whose render target is an app-created
  texture (offscreen scene RT + present copy, or the direct-to-drawable
  pass under `framebufferOnly=YES`), the display intermittently shows
  unaligned jagged runs of the exact color (234,51,247); the poison is
  GPU-side only (CPU `getBytes` of the same texture is clean). The
  standalone reproducer (`tools/bugc_repro/repro.m`) pins the trigger:
  MTL4 queue writing an app-created RT poisons 18/18; MTL4 writing
  drawables only, MTL4 only reading an app RT, or an idle MTL4 queue
  are all 0/18; classic queue with identical MTL4-compiler-built
  pipelines is 0/18. Notably ref_vk (MoltenVK, classic Metal API) shows
  the identical signature at ~10% of game-level captures on the same
  machine, so the defect is AGX/display-path-side, with the MTL4
  pattern as a rate amplifier. ref_mtl's mitigation is the classic
  queue port (0/42 game-level captures since). See
  `tools/bugc_repro/NOTES.md` for the full bisect matrix.
- Verified: paired fresh captures of `ref_mtl` and `ref_vk`/`ref_gl1`
  on base1 and jail1; `WERR=1 make` builds clean with `-Werror`;
  `tools/fix_verify.sh` runs build + deploy + smoke as one gate.
- **W6b (in progress): console commands.** `screenshot [tga|bmp|png|jpg]
  [quality]` registers the ref_vk-equivalent command: blits the offscreen
  scene texture to a shared staging buffer, converts BGRA->RGBA (Metal
  targets are top-row-first, the host's stbi writers want top-down RGBA)
  and hands it to `ri.Vid_WriteScreenshot` at full drawable resolution.
- **W6b: underwater world warp (`mtl_underwater`).** ref_vk's
  `RP_WORLD_WARP` parity: a full-screen pass samples `scene_texture`
  through the ported `world_warp.frag` math and writes `warp_texture`
  while the view is submerged; the UI pass, the present pass and the
  screenshot blit follow `st->ui_target`. The pass runs from
  `MTL_BeginUIPass` (the first 2D draw, like ref_vk's `R_SetVulkan2D`
  hook — the host never calls `RE_EndWorldRenderpass` on normal
  gameplay frames) and from `RE_EndWorldRenderpass` on the menu/loading
  paths, once per frame.
- **Blend-state fix (found via the warp):** blended pipelines set Metal
  blend factors but never `blendingEnabled`, so they silently stayed
  opaque (`One, Zero`) — the view-flash quad replaced the scene instead
  of tinting it (underwater "black world" symptom). Seven pipelines now
  match ref_vk's `blendEnable = VK_TRUE` set (dlight, flash, translucent
  alias, sprite, both particle paths, UI color-rect); ref_vk's UI
  tex/tint pipelines default to blending off and ours match.
- **W6c: world postprocess (`mtl_postprocess`).** ref_vk's
  `postprocess.frag` parity: a full-screen pass, chained after the warp
  stage in the same between-passes slot, samples the warp/plain scene
  and writes `post_texture` with `pow(rgb * 1.5, 2.1 - vid_gamma)`.
  This is ref_vk's world gamma source: its `polygon_lmap.frag` (like our
  `world_lmap_fragment`) applies no pow itself. Like ref_vk the pass
  always runs while the world rendered (the cvar-0 case is the shader's
  passthrough branch). This closed the brightness gap: fresh paired
  jail1 pool captures are now pixel-parity (center 85/54/33 both,
  full-frame mean diff ~1.5 = frame-to-frame noise).
- **W6d: translucent-surface (SURF_TRANS33/66) parity.** Two gaps: the
  world pipeline chain (`pipeline_plain`, the SURF_TRANS33/66 glass and
  liquid workhorse) was missing `blendingEnabled`, and `RE_RenderFrame`
  never called `R_DrawAlphaSurfaces()` — `R_RecursiveWorldNode()` only
  collects alpha surfaces onto `r_alpha_surfaces`; the chain has to be
  unwound back-to-front (the BSP walk is front-to-back), matching
  `ref_vk`'s call site between `R_DrawParticles()` and
  `R_RenderFlash()`. Fresh paired cool1 water-viewpoint captures:
  scene-region mean |diff| 5.2, every channel within a couple of units.
- **W6d: skybox parity (`R_DrawSkyBox`).** The sky quads sit at
  MakeSkyVec's fixed 2300-unit distance. ref_mtl's perspective far
  plane was `width / tan(fov_x)` (~640 at 640 px, fov 90), so the quads
  fell beyond far and Metal clipped them — black sky. ref_vk's far
  plane is a constant 4096 (8192 with `r_farsee`); ref_mtl now uses the
  same values. Sky depth needs no special state: at 2300 the quads land
  at depth ~0.999, under the 1.0 clear, so the plain world Less
  compare passes them (exactly like ref_vk). Fresh
  paired cool1 sky captures (looking up, yaw 324 / pitch -70): top-200
  row means (212.8, 84.3, 5.6) vk vs (213.7, 81.4, 7.1) mtl, sky-band
  region |diff| 2.1.
- **W6e: world pixel-size downscale (`mtl_pixel_size`).** The
  `vk_pixel_size` port: a `CVAR_ARCHIVE` cvar (default 1) renders the
  world pass into a 1/divisor viewport of the scene texture; the warp
  stage (which now also runs whenever the divisor is > 1) restores
  full size with `uv /= pixelSize` and a clamp that matches vk's
  unnormalized `S_NEAREST_UNNORMALIZED` lookup exactly (texel =
  `floor(coord)`, so the lower clamp is 0, not half-texel*divisor);
  particle point size divides by the divisor in the particle UBO.
  Fresh paired jail1 pool captures, scene-region best-shift mean
  |diff|: divisor 2 -> 0.98, divisor 3 -> 1.01-1.13, at or below the
  divisor-1 noise floor (1.78). Fractional divisors sit slightly
  above the floor (~2.6 at 1.5) because vk renders at
  logical-resolution while ref_mtl's scene texture is
  device-resolution, so fractional block edges land on different
  sub-pixel grids; the interiors still match.
- **W6f: viewsize < 100 / `SCR_TileClear` parity.** The world pass is
  now anchored to the vrect (`r_newrefdef` rectangle, device-scaled,
  divided by `mtl_pixel_size` like ref_vk's floor/ceil) with a
  matching scissor rect, so the `SCR_TileClear` tiles the UI pass
  drew into the scene texture before the world survive outside the
  world view instead of being overdrawn. Second bug fixed on the way:
  `MTL_BeginUIPass` ran the warp/postprocess chain on the pre-world
  tile pass, burning the once-per-frame flag while `world_rendered`
  was still false - every `viewsize < 100` frame lost the
  postprocess stage (un-postprocessed gamma). ref_vk itself has a
  nondeterministic field of uninitialized (magenta debug-fill)
  texels inside its vrect at `viewsize < 100` (its RP_WORLD color
  LOADOp); those pixels are undefined behavior we can't match.
  Fresh paired jail1 pool captures at viewsize 50: vrect 1.08-1.09
  (poison excluded), TileClear borders and status bar 0.00
  pixel-exact, and 0.80 vrect with `pixel_size 2` (warp upscale +
  resampled borders); viewsize-100 regression unchanged at the
  1.64-1.78 noise floor.
- **W7: MSAA parity (`r_msaa_samples`).** ref_mtl reads the same
  `r_msaa_samples` cvar as ref_vk and picks the largest supported
  power of two <= the requested value (`supportsTextureSampleCount`,
  16->2 ladder; an M1 Max clamps 8 -> 4 exactly like ref_vk). Only the
  world-pass pipelines are rebuilt at that `rasterSampleCount`
  (`MTL_InitWorldPipelines`), mirroring ref_vk's RP_WORLD-only
  sampleCount; UI/warp/postprocess/present stay 1-sample. The world
  pass renders into multisampled BGRA + Depth32Float attachments and
  resolves them into `scene_texture` with
  `MTLStoreActionMultisampleResolve` (ref_vk's `pResolveAttachments`).
  `MTL_UpdateMSAA` checks the cvar every frame from `BeginFrame` (the
  host's video menu can change it without a mode change) and prints
  ref_vk's "...MSAAx%d is used" banner. Because Metal's resolve
  overwrites the whole resolve texture regardless of the world-pass
  scissor, at `viewsize < 100` the pre-world TileClear contents are
  saved before the world pass and blitted back outside the vrect
  after it. Fresh paired jail1 pool captures: MSAAx4 on both
  renderers 0.74-0.91 scene (better than the MSAA-off floor -
  different sample patterns leave only edge noise), MSAA-off pair
  1.76-1.97 at the floor with 0 poisoned pixels, viewsize 50 + MSAAx4
  vrect 0.99-1.06 with 0.00-exact borders.
- Feature parity remaining: none (W0-W7 complete).
- Review findings F1-F6 (+ F7 found while verifying under the debug
  layer) fixed: F1 MSAA attachments sized from stale dimensions on
  resize (debug-layer repro: resolveTexture size mismatch assert);
  F2 `MTL_UpdateMSAA` failure paths (draw buffers created before the
  pipelines, `msaa_failed_want` one-shot degrade); F3 `slot_busy[]`
  made `_Atomic` with release/acquire; F4 world-UBO ring offsets
  rounded to 16-byte alignment (debug-layer offset assert); F5
  Private storage for depth + MSAA attachments (timedemo demo1 A/B
  neutral); F6 docs left untracked by decision; F7 all world pipelines
  now set `depthAttachmentPixelFormat=Depth32Float` and the pre-W7
  duplicate pipeline blocks in `R_InitShaders` (which leaked six
  pipelines and overwrote the W7 pointers) were removed.
- Second review round G1-G6 fixed: G1 image GPU textures were never
  released on eviction or shutdown (unbounded device-memory growth,
  measured ~150 -> ~310 MB over repeated asset churn; bounded after);
  G2 the world-UBO emit ran inside both draw chains, exhausting the
  512 KiB ring mid-frame on large maps (hoisted to once per frame,
  2 MiB ring, `mtl_mem` now counts ring drops: 95.7% usage -> ~20%,
  0 drops); G3 a single shared warp/postprocess parameter UBO was
  rewritten each frame while the 1-2 older in-flight command buffers
  still read it (params now ride the command buffer via
  `setFragmentBytes:`); G4 dynamic lightmap `replaceRegion:` wrote
  immediately into textures in-flight frames were still sampling (the
  dynamic lightmap range is now three per-frame-slot sets selected by
  `frame_slot`, lazily created); G5 with `mtl_pixel_size` >1 and
  viewsize <100 the warp pass stretched full-size border/menu content
  outside the refdef rect into magnified garbage bands (the
  upscale-restore remap is now gated to refdef pixels; A/B captures
  show the same clean TileClear border as ref_vk, viewsize 100
  unchanged); G6 hygiene bundle (Private storage for the scene/warp/
  post/MSAA-save targets, one-time clear of freshly allocated scene
  textures on resize, MSAA color load action preserves UI already in
  the scene, larger lightmap temp buffer, alignment cast fix,
  MAXLIGHTMAPS style guards).
- Third review round H1-H3: H1 fixed (with `mtl_pixel_size` >1 and
  viewsize <100 the warp pass's 1:1 passthrough composited raw
  down-scaled world texels into the left/top TileClear border bands;
  the pre-world tile save now also feeds a border restore after the
  warp/postprocess stages, MSAA and non-MSAA alike, A/B band MAD
  ~8-10 -> unaffected-border baseline ~6); H2 accepted as a known limitation: the
  static lightmap `replaceRegion:` rebuild on return to base lighting
  can race in-flight frames (see G4), showing at most a one-frame
  flicker at the transition - per-slot staging for 256 full static
  textures was judged not worth hiding that; H3 tooling: the
  `fix_verify.sh` smoke now maps `jail1` (the old `dm1` was absent
  from the installed paks, making the map-content check inert) and
  fails on `Can't find`.
 - Fourth review round I1-I5 (entity/alias feature gaps) fixed: I1
   `RF_BEAM` entities were never drawn (ref_vk draws them as tubes via
   `R_DrawBeam`); beams now draw as tube segments with the beam's
   flat color and no depth write, new `pipeline_beam` + beam shaders
   (winding/cull state corrected by round-5 J1, see below; jail1
   `target_laser` A/B footprint IoU 0.96); I2 the view weapon
   ignored `RF_DEPTHHACK` (the gun poked
   through walls), `r_gunfov` and `hand`: a per-entity depth-hack
   view-projection (the 0.3 band folded into the native Metal [0,1]
   range, near 4) rides the alias UBO record, `r_gunfov -1` follows
   the main FOV, hand 1 mirrors via negated X + front-face culling,
   hand 2 hides the weapon (paired mtl/vk captures: mirrored-bbox IoU
   0.87/0.78 at the frame-noise ceiling, gunfov bbox parity,
   wall-pushup gun-region diff 202 px); I3 malformed glcmd commands
   (`count < 3`) desynced the parser - the vertex words are now
   skipped and reads clamped to the node's command range; I4
   uninitialised `pointcolor` and the `1.0/s` NaN on the degenerate
   lighting paths are now deterministic (zero); I5 the brush chains
   (`MTL_DrawPolyChain`/`MTL_DrawLightmappedChain`) set `depth_state`
   explicitly instead of inheriting the encoder state the
   translucent-alias pass leaves behind (ref_vk bakes it into every
   brush pipeline).
 - Round-5 findings J1-J3: J1 fixed the beam quad's triangle pair so
   back-face culling keeps the front half of the tube - the
   translucent `TE_LASER` core now blends at effective alpha 0.31
   like vk (was a 0.49 double blend with culling disabled); J2
   investigated the toolchain-workaround claim, and round 6 (K1)
   corrected its conclusion: the `VectorCopy(*tri[k], dst)`
   misbehaviour is a macro-precedence trap, not a clang defect -
   `VectorCopy`'s arguments are unparenthesised in the (upstream-
   identical) `shared.h`, so the expansion `*tri[k][j]` parses as
   the valid C `*(tri[k][j])`, the first float of the *next* ring
   element (visible at -O0, silent under UBSan); no live call site
   in any tree passes a prefixed or ternary argument, and the
   explicit component copies stay as the documented sidestep;
   J3 made the beam/dlight/left-hand encoder restores return to
   back-face cull instead of culling off, so a translucent alias
   model drawn after a beam stopped double-blending (jail1
   `misc_blackhole` rig: +25 -> +11, vk +12) - round-6 K2 showed
   that diagnosis to be wrong (Metal's documented fresh-encoder
   default is culling off, not back-cull; the "restore" was a state
   leak, and the common no-beam frame stayed double-blended), and
   replaced it.
 - Round-6 finding K2: the world pass's raster state is made explicit
   and no longer draw-order dependent. Metal's
   documented fresh-encoder state is Clockwise + `MTLCullModeNone`,
   and mtl's clip space does *not* mirror winding against ref_vk, so
   the pass sets that baseline (`MTL_SetPassDefaults`, at pass start
   and at every override's tail) and each override group sets the
   same winding + cull pair ref_vk bakes into its pipeline (qvk.h):
   alias-model draws Clockwise + back-cull (front-cull when `hand`
   mirrors the viewproj), the beam tube Clockwise + back, the dlight
   cubes Clockwise + front. Measured on the jail1 blackhole funnel
   with a freeze protocol (spawn + server-pause in one bind, pinning
   the blackhole's 19-frame anim to frame 0; base captures pause at
   the same level time): mtl funnel G-delta +7.5/+7.5 with and
   without a laser in view vs vk +7.4/+7.4, and mtl's own order-
   dependence is gone (funnel window with vs without beam, mean pixel
   diff 0.009); the old no-beam case double-blended at +24. The
   model-file winding sign was settled by the weapon view model's
   open surfaces: CounterClockwise + back-cull carves front-face
   holes in the stock/grip where Clockwise + back-cull matches vk
   (funnel-window pixel diff to vk mean 0.90 / max 43 vs 1.27 / 78);
   hand 1's mirrored pair matches vk's lefthand pipeline at the
   frame-noise floor; base1 full-frame diff vs pre-K2 stays confined
   to the gun region (open-surface back-face removal, matching vk).
   Free-running cross-run comparisons are phase-noisy (a one-tick
   schedule shift moves the funnel delta by ~7 - which is why the
   J3-era +11 vs +12 agreement was tighter than it looked). Whole-
   pass back-culling with hidden-surface-removal savings (the
   brief's option B) is deferred as a perf-parity milestone; pull it
   forward if glass/alpha double-blend findings, perf goals, or
   further winding-mixup bugs recur.
 - Round-7 findings L1-L5 (+ round-6 leftovers): L1 added
   `MTL_DrainInFlightFrames` at the top of both shutdown paths -
   frame-completion handlers run on Metal worker threads and write
   dylib statics, and the host dlcloses right after `re.Shutdown()`,
   so an undrained quit/`vid_restart` risked executing unmapped
   code (stress: 15+ unload/reload cycles clean). L2 completed the
   teardown: all five console commands are deregistered (pre-fix,
   2 restarts x 2 rounds logged 16 "already defined" and kept the
   stale dylib's handlers wired), `Mod_FreeAll`/
   `Mod_FreeModelsKnown` run before image teardown as in
   `QVk_WaitAndShutdownAll`, and the `s_blocklights`/`s_lerped`/
   `s_cmdverts` scratch is freed; `leaks --atExit` across 2 restarts
   dropped 1,415,936 B (incl. 4 x 320K `calloc in Mod_Reallocate`)
   to a 27,648 B host/runtime baseline. L3 gave `RE_Draw_StretchRaw`
   one raw texture per frame slot (G4 pattern; the single shared
   texture was rewritten by `replaceRegion` while older in-flight
   frames sampled it). L4 made `r_videos_unfiltered` actually pick
   the nearest UI sampler for video, like vk's `S_NEAREST` branch.
   L5 + leftovers: stale-alignment and stale-J3 comments trimmed
   to the current rule, `scale2x/3x` destination allocation guarded
   (vk leaves it unchecked; we fall back to unscaled with a
   one-shot console note), and the `VectorCopy` precedence-trap
   documentation stays at the beam copies (K1). Still open from
   this round: shelled-alias-model capture coverage - base-game
   gamecode never sets `EF_*` shells on monsters (rogue/ctf only,
   not installed) and singleplayer has no chase cam, so no mtl/vk
   pair can be produced; shell draws reuse the same glcmds and the
   same Clockwise + back-cull pair (vk: one fan pipeline), so the
   cull argument there is structural. UI bind-caching
   (`RE_Draw_CharScaled` per-glyph state churn) stays deferred
   until profiling says otherwise.
  - Round-7b follow-ups M7B1-M7B3 (re-verification of the L1-L5
    commits): M7B1 fixed the L5 `scale2x/3x` OOM fallback itself
    dereferencing NULL - on malloc failure `image_scaled` now falls
    back to the caller's `data` and both frees are guarded
    (`image_scaled != data`), so the retexturing-failure path draws
    unscaled instead of faulting (forced-malloc-NULL + synthetic
    StretchRaw call: pre-fix SIGSEGV `KERN_INVALID_ADDRESS at 0x0`,
    post-fix graceful frame + one-shot console note). M7B2 closed
    the live half of L1's open-frame case: an ERR_DROP mid-frame
    while the renderer stays alive (warp numverts/MAX_CLIP_VERTS,
    bad world model, lightmap errors) left the abandoned slot busy
    forever - every third frame then stalled 1 s on the CPU gate
    (measured: 20 x "CPU gate timed out" at frames 91,94,97,...).
    The drain's open-frame block became `MTL_AbandonOpenFrame()`
    (now also ending open encoders before releasing the buffer) and
    RE_BeginFrame calls it before advancing the frame counter, so
    the abandoned frame's own slot is released; post-fix, one
    "discarding frame" DPrintf, zero stalls. M7B3 hardened the
    teardown against a second `RE_Shutdown`:
    `Mod_FreeModelsKnown` left `mod_numknown`/`mod_loaded` set over
    a NULL table, so a second pass would walk it in `Mod_FreeAll`
    (recursive-shutdown test: pre-fix SIGSEGV in `Mod_FreeAll` at
    0x240, post-fix clean); the counters are reset by a new
    `Mod_ResetKnown()` in `mtl_model.m` called from RE_Shutdown -
    `Mod_FreeModelsKnown` itself stays untouched because
    `Mod_Reallocate` depends on the counters (vk dodges the case
    with its `vk_initialized` guard; we have no guard).
 - Round-8 findings M1-M8 (brief `REVIEW_FINDINGS_8.md`; world-context
    init paths, filtering, image loading): M1 made `r_vsync` actually
    steer presentation - `RE_InitContext` never touched the layer's
    `displaySyncEnabled` (default YES), so every present was display-
    synced regardless of the cvar while `RE_IsVSyncActive` only steered
    the host's own pacing wait (measured: r_vsync 0 windowed was capped
    at the 60 Hz display pre-fix, uncapped post-fix). The layer now
    takes vk's `vk_setSyncSource` mapping (1 -> YES, 0/2 -> NO) at
    init, on every layer re-creation, and mid-session on cvar change.
    M2 wired texture filtering: the world/alias/sprite/particle paths
    had constexpr samplers baked into `world.msl` (linear+mip always,
    no anisotropy); five sampling fragments now take explicit
    [[sampler(0)]]/[[sampler(1)]] arguments fed by `world_sampler`/
    `world_sampler_nearest`/`lmap_sampler`, `r_anisotropic` registered
    with vk's name/flag/clamp 1..16 and rebuilt on change, mip-near
    filter selects the nearest sampler at mip generation, and the
    r_nolerp_list images keep point sampling in 3D like vk (paired
    aniso 0-vs-16 captures show the expected shimmer difference).
    M3 made the `RE_BeginFrame` resize pass publish the new sizes only
    when all four scene/depth/warp/post allocations succeeded - one
    failed allocation used to latch "same size" forever and every
    later frame encoded against nil targets. M4 `RE_InitContext`
    nits: view NULL check before `SDL_Metal_GetLayer`, the layer-NULL
    path releases the fresh view, a `supportsFamily:MTLGPUFamilyMetal4`
    gate replaces the OS-version-only test (clear message + GL3
    fallback instead of a cryptic pipeline-creation failure; verified
    with a forced-fail hook), and both early returns release the
    `MTLCreateSystemDefaultDevice` +1. M5 split `MTL_LoadPic`'s
    find-or-allocate loop into name-scan-then-free-slot (vk/upstream
    shape): after `MTL_FreeUnusedImages` punched holes, images past
    the first hole were missed and re-uploaded as duplicate GPU copies
    (forced-hole test: dup 1 -> 0). M6 handled the two half-built-
    image paths: texture-creation failure now logs a one-shot
    `Com_Printf` and substitutes a retained `r_notexture` (was:
    silent + nil-textured invisible surface), 8-bit scaling malloc
    failure rolls the slot back (`memset` + `img_loaded--`) instead
    of leaving a permanent half-built record (forced-failure test:
    111+ poisoned slots -> 0, slot reused per retry; ref_vk has the
    same latent conversion flaw - deviation deliberate, commit body).
    M7 (verify only): one `pipeline_plain` + per-chain `depth_state`
    covers vk's solid+blend warp pipelines (both write depth, blend
    at alpha=1 is identity); paired waste1 translucent-water captures:
    static regions 0.0-0.7 MAD, water-strip diffs are SURF_FLOWING
    scroll phase, not depth/blend behaviour (first vk run showed the
    host's known transient MoltenVK liquid corruption; reruns clean,
    gl3 ground truth agrees with mtl). M8 (optional upload
    profiling): deferred - no profiling evidence demands it.
 - Round-9 findings N1-N5 (brief `REVIEW_FINDINGS_9.md`; world surfaces,
    BSP load, lightmap build): N1 handled lightmap-texture creation
    failure - `MTL_CreateLightmapTexture` logged a `Com_DPrintf` and
    left the slot nil, and both draw chains skip nil lightmaps, so the
    whole BSP block vanished with no console trace (forced all-fail:
    black world, 17 silent failures at developer 1, zero at developer
    0). Now one `Com_Printf` per BSP load plus a white 1x1 substitute
    so those surfaces draw fullbright (deliberate deviation from vk's
    ERR_DROP, same direction as M6's notexture); the upload path skips
    the substitute (a 128x128 region into a 1x1 texture is a
    debug-layer error); a new `mtl_mem` counter "Dropped surface
    draws" tracks chain draws skipped for missing state (forced
    no-substitute run: 590426 counted; clean runs: 0). N3 stopped
    reusing the previous map's static lightmap textures:
    `MTL_BeginBuildingLightmaps` now releases and nils slots
    0..MAX_LIGHTMAPS-1, removing the map-change `replaceRegion`-over-
    live-texture race (H2 class, now at every map change) and up to
    16 MiB of stale blocks (live-slot hook: 17 stale after jail1 ->
    security, post-fix exactly the new map's 11). N2 made
    `MTL_DrawSkyQuad` set `depth_state` explicitly (it worked only by
    inheritance from the pass-start set) and emit its UBO before
    advancing `world_vertex_offset` (a dry ring no longer strands a
    consumed vertex slice); cross-build frame diff at the same-build
    noise floor. N4 nits: the `MTL_UploadLightmapRegion` fast path is
    guarded `x == 0 && y == 0` (a compact `smax == 128` source matches
    the atlas stride by coincidence, and an atlas caller with y > 0
    would upload the wrong rows), and the dead `skytexture` global in
    `mtl_warp.m` (written, never read, no vk counterpart) is gone.
    N5 (optional draw-chain performance: per-source-vertex warp sine
    reuse, one batched drawPrimitives per chain, UBO record dedup):
    deferred - no profiling evidence demands it, same disposition
    as M8.
 - Round-9b follow-ups N9B1-N9B2 (brief `REVIEW_FINDINGS_9B.md`;
    re-verification of the round-9 lightmap fixes): N9B1 closed a
    lifetime hole in N1's white substitute - the retry story differs
    per slot kind. Static slots are released wholesale by
    `MTL_BeginBuildingLightmaps` (N3) at the next BSP load, but the
    dynamic frame-slot sets are only freed in `MTL_FreeLightmaps` and
    `MTL_DynLightmapTexture` created only on a nil slot, so a failed
    dynamic creation left its block fullbright with uploads skipped
    for the whole session (pre-fix sim: 1 forced failure, 27566
    substitute upload skips still growing, shot mean luma 100.8 vs
    18.4 clean). `MTL_DynLightmapTexture` now recognises the
    substitute in a dynamic slot, releases it and retries creation on
    each use until it succeeds (same trigger: exactly 1 failure, 1
    retry, 1 skipped frame, shot back to baseline; all-creates-fail
    stress: 380885 retries, no debug-layer/leak errors). N9B2 made
    the source layout of `MTL_UploadLightmapRegion` an explicit
    `atlas_src` parameter instead of inferring it from
    `src_stride == BLOCK_WIDTH*LIGHTMAP_BYTES`: a compact source with
    `smax == 128` matches that stride by coincidence (the N4 nit's
    y-guard kept it from over-reading) and atlas callers are now
    distinguishable from the three compact per-surface call sites by
    inspection; jail1 and base1 cross-build frame diffs stayed at the
    same-build noise floor.
 - Round-8b follow-ups M8B1-M8B3 (brief `REVIEW_FINDINGS_8B.md`;
    verification pass over the round-8 dispositions): M8B1 confirmed
    the M1 `r_vsync` wiring end to end with a temporary frame-window
    hook (never committed): on this 120 Hz panel `r_vsync 1` pins the
    frame rate at 120.0, `r_vsync 0` removes any Metal-level pacing
    (~203 fps in jail1 at 640x480, debug layer off, ~100 with it on;
    the cap is the CPU, not the layer), and runtime toggles in both
    directions take effect within one 2 s measurement window with
    `displaySyncEnabled` tracking the cvar throughout. Noted (no
    change, owner decision): mtl and vk default `r_vsync` to "0"
    while gl1/gl3/soft and the video menu default differ. M8B2 fixed
    a mip-selection divergence found by paired pixel-exact captures:
    ref_vk's nearest-blit mip generation resolves the 2:1 downscale
    tie to source texel (2x+1, 2y+1), not (2x, 2y) as round-8 M2
    assumed - before: mtl-vs-vk at nearfilter=1 differed on 0.8% of
    pixels (mean absdelta 1.7) vs a 0.1% vk reboot floor; after:
    0.1-0.2%, i.e. vk's own floor, while the box-filter
    (nearfilter=0) pair was already at the floor. M8B3 is docs-only:
    `r_clear` is registered but deliberately unused (mtl always
    clears to black) and moved out of the shared-name parity list in
    `REVIEW_EXTERNAL.md`, which also gained the requested
    registered-cvar status table.
 - Round-10 findings O1-O6 (brief `REVIEW_FINDINGS_10.md`; frame setup,
    cvar surface, 2D border): O1 wired the never-called `R_MarkLeaves`
    into `RE_RenderFrame` after `R_SetupFrame` (PVS leaf marking, same
    place as ref_vk's `RE_RenderView`), which restores the
    `d_pvs`/`r_viewcluster` chain the surface cull reads. O2 ported
    `R_SetLightLevel()` (water/quake/slime/lava damage tint plus the
    `refdef.ambientlight` bump) and calls it every world frame. O3
    special-cased `RDF_NOWORLDMODEL` frames like ref_vk: a grey
    backdrop quad through the UI colour path, the player-setup model
    drawn over it, and no warp/postprocess chain, with the MSAA
    resolve and `ui_target` bookkeeping following suit. O4 renamed
    `mtl_polyblend` to the shared `r_polyblend`, registered
    `r_norefresh` (skips the refdef publish and the world draw while UI,
    warp and present keep running; since T5 each such frame clears the
    scene to ref_vk's debug pink like vk's render-pass clear, instead of
    leaving the last 3D frame frozen), `r_speeds` (same counters as ref_vk)
    and ported the deferred `r_shadows` planar ground shadow (own
    pipeline, matrix rebuilt inside `MTL_DrawAliasShadow` from the
    entity's pitch-restored angles like ref_vk does, per-entity
    stencil-free draw;
    `base1`/`jail1` captures match ref_vk's shadow silhouettes). O5
    found a real bug behind a comment contradiction: at `viewsize <
    100` the whole mtl 2D border rendered as one flat grey, because
    both UI samplers defaulted to clamp-to-edge while
    `RE_Draw_TileClear` maps uv values past 1.0 (the engine even
    passes oversized rects), pinning every tile past the first to the
    backtile's corner texel. A new `ui_sampler_repeat`
    (`MTLSamplerAddressModeRepeat`) selected only for tile clears fixed
    it, and verifying the border's gamma settled the H1 question:
    ref_vk draws its tileclear inside the world pass, so its tiles get
    the postprocess pow at every pixel size; the tile restore moved
    from after the postprocess stage to between warp and postprocess,
    making the border byte-identical to ref_vk at `mtl_pixel_size 1`
    (230400/230400 sampled border pixels) and palette/gamma-matching at
    2, where the residual difference is resolution only (ref_vk's
    border is the half-scale world image upscaled 2x). O6 is the nit
    pass: the `R_SetupFrame` and `RE_RenderFrame` headers no longer
    describe W3.0/W4 scaffolding, the I2 depth-hack comment no longer
    repeats ref_vk's wrong "0.2 / 0.4" wording (`RDF_NOWORLDMODEL` is
    2, so `0.3 - 2 * 0.1` gives c = 0.1 and a [0, 0.2] band), and
    `r_newrefdef = *fd` is published before the frame-machinery early
    return so the 2D-side readers can never lag a submitted frame.
 - Round-11 findings P1-P4 (brief `REVIEW_FINDINGS_11.md`; entity /
    sprite / particle audit): P1 ported `R_DrawNullModel` - the classic
    lit octahedron marker ref_vk draws for refdef entities whose model
    failed to load - into the nil-model branch of both passes of
    `R_DrawEntitiesOnList` (CPU-computed octahedron normals, so the
    alias pipeline needs no new state except an explicit
    `MTLCullModeNone`; marker bbox/centroids match vk within 1 px and
    8/8 sampled marker colours are equal on a jail1 `spawnentity` rig).
    P2 made vertex-ring exhaustion observable and bounded: per-ring dry
    counters for every frame slot ring (`mtl_mem` lines plus
    once-per-session developer messages, mirroring the round-1
    `Dropped surface draws` pattern), and particles moved onto a
    dedicated 1 MiB vertex ring after a gib-shower probe showed the
    shared 4 MiB alias ring could drain mid-frame and drop whole
    particle batches; the gib-shower re-run exercises the particle
    ring directly (it peaks at 45% of the ring) and reports zero drops. P3 verified particle appearance against ref_vk
    with ROI-isolated captures (machinegun sparks at `custom_particles`
    1/2/0 and `mtl_pixel_size 2` + `viewsize 50`; rocket-splash gib
    showers): blob counts/median sizes/colours equivalent within
    run-to-run simulation variance, all three particle modes and the
    pixel-size combo match ref_vk's look; recorded numbers and the
    discarded contaminated capture are in `REVIEW_EXTERNAL.md`. P4 is
    the nit pass: particles write straight into their ring instead of
    a 442 KB static staging array plus `memcpy` per frame, the
    `MAX_PARTICLES` clamp happens in a local instead of mutating
    `r_newrefdef`, a malformed sprite with `numframes == 0` skips the
    draw instead of dividing by zero in the frame wrap, and the
    `R_DrawEntitiesOnList` / `R_DrawBeam` headers record the P1
    nil-model marker.
 - Round-12 findings Q1-Q5 (brief `REVIEW_FINDINGS_12.md`; world.msl
    shader audit against ref_vk's GLSL): Q1 (tileclear repeat
    addressing) and Q4's code half were already closed by round 10's
    O5, so they re-ran as verify rows: at `viewsize 50` the mtl border
    ring (196608 px) is byte-identical between `mtl_pixel_size` 1 and
    2 (sumd 0) and byte-identical to ref_vk's border at pixel size 1
    (sumd 0); ref_vk's own border changes with pixel size because its
    tileclear rides the divided world buffer (resolution difference
    only, accepted in O5). Q2 was a real parity bug:
    `alias_fragment` multiplied the texture by the raw interpolated
    vertex colour while `model.frag` clamps to [0,1] first, so
    overbright-lit models rendered brighter than ref_vk - fixed with
    `clamp(in.color, 0.0, 1.0)` before the multiply (evidence:
    blaster muzzle flash at `r_modulate 3`, pre/post/vk triple). Q3:
    sky images sampled through the repeating `world_sampler`;
    ref_vk gives clamp-to-edge to `it_sky` images only
    (`vk_image.c:1166`), and a minified sky quad pulls the opposite
    cube face through the wrap - added a third runtime sampler
    `world_sampler_sky` (same filtering/anisotropy as `world_sampler`,
    clamp-to-edge; the brief's constexpr sampler would have dropped
    `r_anisotropic`, which M2 keeps runtime) bound by
    `MTL_DrawSkyQuad` and sky surface chains: on power1's `e2u3/sky1`
    dome at `pixel_size 8` (sky at mip ~2) the right-edge band had
    832 differing samples against vk before the fix, 0 after. Q4's
    comment half: the stale G5 note in `warp_fragment` claimed
    ref_vk draws its tileclear after the warp pass - it draws it
    inside RP_WORLD at (0,0) with the quad transform divided by
    `vk_pixel_size`, and the warp's unconditional `uv /= pixelSize`
    scales it back up; comment rewritten. Q5 nits: the world.msl
    header preamble still described `MTL4ArgumentTable` delivery -
    rewritten for `vertexDescriptor`/stage_in plus classic-encoder
    bindings - and the `MTL_BuildWorldSamplers` doc records that
    ref_vk picks lightmap filtering from `vk_lmaptexturemode`
    (default `VK_MIPMAP_LINEAR`) while mtl pins that default; the
    half-open warp bounds note was verified present.
 - Round-13 findings R1-R4 (brief `REVIEW_FINDINGS_13.md`; pipeline
    creation RCs, MSAA sample shading, solid-liquid blend, comment sweep):
    R1 fixed manual-RC imbalance around the `ui_tint` and `alias` pipeline
    creation blocks (the shared `vd` was released twice on the success path
    and leaked on the alias failure path). R2 added per-sample shading
    parity: the world fragment function is specialized with
    `function_constant(0)` `per_sample_shading` when MSAA > 1, driven by the
    new archived cvar `mtl_sampleshading` (default 1), seven sampling
    fragments annotated; a keep-alive UBO probe proved real per-sample
    execution (flag on: 282,898 px shifted, checker averaged by the MSAAx4
    resolve; flag off: within 1 px of baseline), final captures 0-14 px from
    the pre-R2 baseline. R3: opaque liquids went through the blend-on plain
    pipeline everywhere; added the fourth world-pass pipeline
    `pipeline_plain_solid` (same plain shader pair, blending off) selected
    by the `EmitWaterPolys` solid flag, vk
    `vk_drawPolySolidWarpPipeline` parity - the alpha-0.5 probe showed the
    blend-vs-solid pipeline choice moves 16,887 px (sumd 379,907) while
    vanilla captures stay identical (0 px). R4 nits: every pipeline
    descriptor labeled (`ref_mtl.world.plain` ...), the
    "MTL4Compiler-created pipelines" wording corrected (states come from the
    classic descriptor API), "single depth state" reworded to the actual
    three, vestigial argument-table blocks and wording left over from the
    classic-encoder port removed, and the MTL4Archive startup cost plus the
    one-frame MSAA-rebuild hitch recorded as accepted notes. Capture note
    for future rounds: Q2 screenshots are RLE 32bpp TGAs - use
    `tools/drivers/tgadiff.py`, naive decoders silently compare garbage.
 - Round-14 findings S1-S5 (brief `REVIEW_FINDINGS_14.md`; dlights,
    screenshot, palette, registration reviewed clean; build and tooling
    fixes): the reviewed render-code areas (dlights, `RE_SetPalette`,
    `RE_SetSky`, model registration, `RE_ScreenShot_f`, vendored sources)
    needed no code changes. S1 rebuilt `tools/fix_verify.sh` into a real
    assertion gate: `+set vid_renderer mtl`, the ref_mtl init banner and
    the `Map: jail1` banner are required, `kill -0` liveness plus
    wait-status classification catch crashes and silent renderer
    fallback (the old script passed over an abort), and `DEBUG_LAYER=1`
    is a first-class mode (log shows "Metal API Validation Enabled").
    S2 added the embedded-shader freshness guard: `make check-shaders`
    (regenerate-to-temp + `cmp`, called by `fix_verify.sh`) plus a
    `src/files/mtl_shaders.c: shaders/*.msl` make dependency, so a stale
    generated shader can no longer build and smoke green. S3 deleted the
    dead W2 `quad.msl` (its array was still compiled into the dylib,
    never used) and the stale W2/W3 wording. S4 Makefile nits: full
    `.PHONY`, BSD `date -u -r` for `SOURCE_DATE_EPOCH` (the GNU form
    failed on macOS), `-mmacosx-version-min=26.0` compile+link so the
    Metal 4 requirement rides in `LC_BUILD_VERSION`, and warning flags
    moved to `override CFLAGS +=` so an env `CFLAGS` cannot drop them.
    S5 documented the deliberate screenshot quirks (main-thread stall,
    previous-frame capture under `frame_active`, forced opaque alpha).
 - Round-15 findings T1-T6 (brief `REVIEW_FINDINGS_15.md`; verification
    of the round-10..14 fixes against the source, plus the owed T7
    measurement pass):
    T1 guarded `R_MarkLeaves` against frames with no worldmodel — with
    `r_novis 1` the player-setup menu at a fresh start SIGSEGVed in the
    mark-everything branch dereferencing a NULL `r_worldmodel` (ref_vk
    shares the latent flaw; fixed in mtl only).
    T2 fixed a map-registration ordering accident:
    `RE_BeginRegistration` now invalidates *both* halves of the
    viewcluster state (current pair and previous pair), so a new map's
    first frame always marks leaves — previously a previous-map cluster
    colliding with the new spawn cluster early-out the marking and the
    world drew as nothing until the player changed clusters.
    T3 added `tools/fix_verify_selftest.sh`: scripted stand-ins inject
    each failure mode the S1 checks guard (fallback renderer, missing
    map, died early, crashed after the kill, injected Metal-diagnostic
    lines) and must produce the matching FAIL line, closing with a
    green positive control.
    T4 made the shader-regen rule's no-python3 branch warn and succeed
    — a fresh checkout on a python3-less machine builds from the
    checked-in array — while `make check-shaders` keeps the gate closed
    on stale content.
    T5 replaced the `r_norefresh` frozen-last-frame behaviour with
    ref_vk's exact flat debug-pink scene clear ({1.0, 0.0, 0.5, 1.0},
    vk's world-RP clear value), removing the 2D-layer accumulation on
    the backdrop.
    T6 was the doc sweep: stale README statements (`r_fullbright`
    listing, `mtl_polyblend` history, the nonexistent
    `MTL_BuildShadowViewproj`), the `world.msl` "useStageInResources"
    header (the classic encoder calls
    `setVertexBuffer:offset:atIndex:`; regenerated array), and the
    review report's summary, cvar tables (`r_anisotropic`,
    `mtl_sampleshading`) and GPU-memory numbers (fresh post-O1
    `mtl_mem`: 58.5 MB rings over 3 slots x 8 rings, 90-91 MB device
    footprint, 0 drops).

### Intentionally not implemented (parity scope cuts)

Ray tracing, ML/tensor features, MetalFX, mesh/tile shaders, indirect
command buffers, color-attachment mapping, sparse resources, and
dynamic libraries are out of scope — matching what `ref_vk` skips.

## Layout

```
src/mtl/        Metal 4 renderer (Objective-C; the MTL4 SDK is ObjC)
src/files/      model/texture/pvs file loading (shared with ref_vk)
src/common/     shared helpers + the host ABI headers (ref_api.h, ...)
src/backends/   platform allocator backend
src/constants/  lookup tables (anorms, warp sin)
shaders/        MSL 3.2 sources (ported from ref_vk's GLSL; W2+)
Makefile        Darwin-only, builds release/ref_mtl.dylib
```
