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

## Current status: W6a (offscreen scene RT + present pass) — complete

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
- Feature parity remaining (W6b+): MSAA, pixel-size downscale,
  underwater warp, `SCR_TileClear` viewport scissor for
  `viewsize < 100`, and the remaining gamma gaps
  (`world_lmap_fragment` vs `ref_vk`).

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
