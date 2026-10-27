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
- **Xcode 26+** with the macOS 26 SDK (Metal 4 headers, `MTL4Compiler`,
  argument tables, residency sets, drawable synchronization)
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

## Current status: W5d (2D UI) — complete

- Full 27-slot `refexport_t` ABI implemented and load-tested against a
  freshly built SDL 3 host (`API_VERSION` 8).
- `RE_InitContext` creates the Metal 4 device, `MTL4CommandQueue`,
  shared event, long-lived `MTL4CommandBuffer`, three command allocators
  (one per in-flight frame) and the SDL Metal view + `CAMetalLayer`
  (`BGRA8Unorm` non-sRGB — the shaders emit final display values, same
  convention as `ref_vk`'s `B8G8R8A8_UNORM` swapchain; `framebufferOnly`
  disabled, see the Bug B note below; `maximumDrawableCount` 3, Retina
  `contentsScale`). The device-side objects survive mode changes;
  `ShutdownContext` tears down only the view/layer, `RE_Shutdown`
  releases everything.
- Frame sequence: `BeginFrame` (CPU gate via
  `MTLSharedEvent.waitUntilSignaledValue`, allocator reset,
  `nextDrawable`, `beginCommandBufferWithAllocator`) → `RenderFrame`
  (world encoder: clear color/depth + BSP world) → `EndWorldRenderpass`
  (true) → 2D UI encoder (lazily opened by the first UI draw,
  `loadAction=LOAD`, no depth attachment) → `EndFrame`
  (`endCommandBuffer`, `waitForDrawable`, `commit`, `signalDrawable`,
  `present`, GPU-side `signalEvent`).
- **W2: runtime shader compilation and the first textured quad.**
  `R_InitShaders` creates an `MTL4Compiler`, compiles the embedded MSL
  3.2 sources into libraries, and builds the render pipelines
  (`MTL4RenderPipelineDescriptor` + `MTLVertexDescriptor`). Bindings
  ride per-stage `MTL4ArgumentTable`s attached with
  `setArgumentTable:atStages:` at encode time.
- **Metal 4 residency sets.** GPU-visible resources must be part of a
  committed `MTLResidencySet` attached to the queue, otherwise the GPU
  silently reads zeros. The set covers every renderer-created buffer
  and texture; the command buffer gets `useResidencySet:`.
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
- **Bug B (fixed): intermittent magenta corruption under blended UI
  draws.** Symptom: fresh processes randomly (~80% of base1 runs) drew
  constant-value magenta under the HUD icon/crosshair quads and one
  small triangle; CPU-side texture scans were byte-identical to clean
  runs, and with `framebufferOnly=NO` the drawable's own bytes read
  back clean. A/B in one binary: 10/12 buggy captures with
  `framebufferOnly=YES` vs 0/12 with `NO`. Root cause: the drawable's
  private-storage lifetime under window-server zero-copy scan-out in
  the MTL4 preview layer; the fix keeps `framebufferOnly=NO`.
- Verified: paired fresh captures of `ref_mtl` and `ref_gl1` on base1
  and jail1; `WERR=1 make` builds clean with `-Werror`.
- Feature parity remaining (W6+): MSAA, pixel-size downscale,
  underwater warp, `SCR_TileClear` viewport scissor for
  `viewsize < 100`, screenshots, and the remaining gamma gaps
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
