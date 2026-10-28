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
at startup).

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
  `r_fullbright`/`r_showtris`.
- **W4: CPU lightmaps + dynamic lights.** Static lightmap atlas pages
  uploaded once; per-page dynamic copies re-encoded when dlights touch
  them (`mtl_dynamic`), dlight additive blend pass
  (`mtl_flashblend`), `R_PushDlights` before `R_SetupFrame` (matching
  `ref_vk` frame order).
- **W5a–W5d: alias models, sprites, particles, 2D UI.** Alias/frame
  interpolation (`r_lerpmodels`), sprites (oriented + `MTL_DRAW2D`
  fixed-facing), particles (point + textured, `mtl_polyblend`), and the
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
- **Bug C (mitigated upstream: Apple feedback filed): intermittent
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
