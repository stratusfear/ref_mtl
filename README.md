# ref_mtl — Metal 4 renderer for Yamagi Quake II

A native **Metal 4** rendering backend plugin (`ref_mtl.dylib`) for
[Yamagi Quake II](https://www.yquake2.net/), modeled on the upstream
`ref_vk` (Vulkan) renderer. It is loaded by the host at runtime via the
`vid_renderer` cvar — no source changes to the host are required, and a
failed or missing plugin can never brick the game (the host falls back
through `gl3` → `gles3` → `gl1` → `gles1` → `soft`).

## AI assistance

Much of this renderer's code, tooling and review reports was produced
with AI assistance. A local LLM, Qwen3.8-Flash-Next, wrote most of the
implementation and fixes. Claude (Anthropic) wrote the review briefs and
independently verified the results. Everything was run against real game
data and a hostile-input test suite before commit, but treat it as
AI-assisted code and review it accordingly. Human direction and final
decisions: [@stratusfear](https://github.com/stratusfear).

## Requirements

- **macOS 26+** (Metal 4 is a macOS 26 feature)
- **Apple silicon** (M1+ / A14+; Metal 4 and MSL 3.2 are Apple-silicon only)
- **Xcode 26+** with the macOS 26 SDK (Metal 4 headers, used for
  `MTL4Compiler` runtime shader compilation; command encoding uses the
  classic Metal queue/encoder API — see `tools/bugc_repro/NOTES.md`)
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

### Debugging: Metal validation (developers only)

**You do not need this to play.** It is a debugging aid for people
building, forking or extending the renderer, to be used after a build
when tracking down Metal API misuse or shader problems. The validation
layers add overhead, so leave them off for normal play.

Apple's Metal validation layers must be enabled **before launch** via
environment variables (they cannot be toggled at runtime):

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 ./quake2
```

`DEBUG_LAYER=1 tools/fix_verify.sh` runs the repo's smoke test under the
same layers.

## Scope: intentionally not implemented

Ray tracing, ML/tensor features, MetalFX, mesh/tile shaders, indirect
command buffers, color-attachment mapping, sparse resources, and
dynamic libraries are out of scope — matching what `ref_vk` skips.

## Layout

```
src/mtl/        Metal 4 renderer (Objective-C; the MTL4 SDK is ObjC)
src/files/      model/texture/pvs file loading (upstream code shared
                with ref_vk; pcx.c, wal.c and models.c now diverge
                from upstream - Z3/Z6 loader hardening lives here)
src/common/     shared helpers + the host ABI headers (ref_api.h,
                ...; ref_shared.h carries the Z3 validation helper)
src/backends/   platform allocator backend
src/constants/  lookup tables (anorms, warp sin)
shaders/        MSL 3.2 sources (ported from ref_vk's GLSL; W2+)
Makefile        Darwin-only, builds release/ref_mtl.dylib
```
