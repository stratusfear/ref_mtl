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

## Current status: W2 (runtime MSL compilation + first textured quad) — complete

- Full 27-slot `refexport_t` ABI implemented and load-tested against a
  freshly built SDL 3 host (`API_VERSION` 8).
- `RE_InitContext` creates the Metal 4 device, `MTL4CommandQueue`,
  shared event, long-lived `MTL4CommandBuffer`, three command allocators
  (one per in-flight frame) and the SDL Metal view + `CAMetalLayer`
  (`BGRA8Unorm_sRGB`, `framebufferOnly`, `maximumDrawableCount` 3,
  Retina `contentsScale`). The device-side objects survive mode changes;
  `ShutdownContext` tears down only the view/layer, `RE_Shutdown`
  releases everything.
- Frame sequence: `BeginFrame` (CPU gate via
  `MTLSharedEvent.waitUntilSignaledValue`, allocator reset,
  `nextDrawable`, `beginCommandBufferWithAllocator`) → `RenderFrame`
  (clear pass + full-screen textured quad) → `EndWorldRenderpass`
  (true) → `EndFrame` (`endCommandBuffer`, `waitForDrawable`, `commit`,
  `signalDrawable`, `present`, GPU-side `signalEvent`).
- **W2: runtime shader compilation and the first textured quad.**
  `R_InitShaders` creates an `MTL4Compiler`, compiles the embedded
  `quad.msl` (MSL 3.2) into a library, builds the render pipeline
  (`MTL4RenderPipelineDescriptor` + `MTLVertexDescriptor`, stride 20:
  float3 pos + float2 uv), and allocates the test resources: a
  6-vertex full-screen quad buffer, a 64×64 red/blue checkerboard
  texture (CPU-filled, `BGRA8Unorm_sRGB`), and one argument table per
  stage (`MTL4ArgumentTable`, vertex buffer at index 0 / texture at
  index 0). Bindings are attached with `setArgumentTable:atStages:` at
  encode time. The quad samples the texture with a nearest,
  clamp-to-edge constexpr sampler.
- **Metal 4 residency sets.** GPU-visible resources must be part of a
  committed `MTLResidencySet` attached to the queue, otherwise the GPU
  silently reads zeros (samples return `(0,0,0,0)`, compute writes do
  not land, no error is reported). `R_InitShaders` creates the set for
  the vertex buffer + test texture (`addAllocation:` → `commit` →
  `queue addResidencySet:`); the layer's own residency set (drawables)
  is added in `RE_InitContext`; the command buffer gets
  `useResidencySet:` in `RE_RenderFrame` (Apple's MTL4 template
  pattern).
- Verified: clean `+quit` run (banner + "Successfully initialized Metal
  4 refresher!" + "W2 shaders compiled", exit 0); live run under
  `MTL_DEBUG_LAYER=1` + `MTL_SHADER_VALIDATION=1` with zero validation
  errors; window capture pixel check — the drawable is a pixel-exact
  red `(255,0,0)` / blue `(0,0,255)` checkerboard with the expected
  8×8 cell geometry, confirming texture sampling, sRGB round-trip and
  the residency path end-to-end.
- Fallback verified: broken `api_version` and SDL major mismatch both
  fall back to `ref_gl3` without crashing; a failed `R_InitShaders`
  (e.g. MSL compile error) falls back cleanly and is retried on the
  next mode change.
- **No scene rendering yet.** Feature parity with `ref_vk` (BSP, alias
  models, sprites, particles, decals, classic sky, water/animated
  textures, CPU lightmaps + dlights, lightstyles, translucency, 2D UI,
  MSAA, pixel-size downscale, underwater warp, screenshots) follows in
  W3–W9.

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
