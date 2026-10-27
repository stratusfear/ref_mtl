# Apple Feedback draft — Metal 4 command queue corrupts Shared texture display output

## Title
MTL4CommandQueue executing render draws intermittently corrupts a Shared
offscreen render-target texture; display shows constant (234,51,247) runs

## Metadata
- macOS 27.x (build TBD), Apple Silicon GPU (AGXG13X family)
- Metal 4 API path: MTL4CommandQueue + MTL4CommandBuffer (reused, with
  beginCommandBufferWithAllocator:) + MTL4CommandAllocators +
  MTL4Compiler pipelines + MTL4ArgumentTable bindings + residency sets
- Reproduction binary + source: repro.m in this directory (single file,
  ~600 lines, builds with one clang command)

## Summary
When an offscreen Shared BGRA8Unorm render-target texture is written by
render passes executed on an MTL4CommandQueue, and a separate pass then
copies that texture to a CAMetalLayer drawable, the on-screen result
intermittently contains horizontal runs (10–30 px) of the exact constant
color (234,51,247). The corruption is GPU-visible only: CPU getBytes of
the same texture at the same moment shows (almost) no poison. Moving the
same draws to a classic MTLCommandQueue (keeping everything else,
including the MTL4Compiler-created pipelines) eliminates it entirely.

## Repro rates (6 runs x 3 screen captures, strict ±12 mask, live display)
| configuration | result |
|---|---|
| MTL4 queue executes world+UI+present passes (offscreen RT + copy) | 18/18 poisoned (28k–350k px) |
| MTL4 queue executes only the two offscreen scene passes; classic queue does the present/copy pass (cross-queue shared-event sync) | 18/18 poisoned |
| MTL4 scene RT in Private storage | 18/18 poisoned |
| fresh MTL4CommandBuffer per frame | 18/18 poisoned |
| maximumDrawableCount=2 | 18/18 poisoned |
| MTL4 queue renders straight into the drawable (no offscreen RT) | 0/18 CLEAN |
| classic queue writes the offscreen scene; MTL4 queue only samples + presents it | 0/18 CLEAN |
| classic queue executes all passes; MTL4 pipelines kept; MTL4 queue idle | 0/18 CLEAN |
| MTL4 queue commits an EMPTY command buffer + signalEvent each frame; classic queue draws | 0/18 CLEAN |
| MTL4 encoders open the passes but issue zero draws | 0 poison (display frozen — invalid) |

=> Refined trigger: an MTL4-executed render pass whose render target is an
APP-CREATED texture. MTL4 writing CAMetalLayer drawables is clean; MTL4
reading an app-created RT is clean; an idle/empty-commit MTL4 queue is
clean. Queue creation, event signaling, MTL4 pipelines, argument tables,
manual waitForDrawable/signalDrawable, CAMetalLayer knobs
(framebufferOnly, presentsWithTransaction, maximumDrawableCount), CPU-side
serialization (full sync per frame), storage mode (Shared vs Private) and
drawable residency grants do not change the rate.

## Key forensic facts
1. Poison is the exact constant (234,51,247) — never seen as any other
   value; not tile-aligned; confined to the layer content rect.
2. CPU getBytes of the Shared scene texture concurrently shows only
   4–96 near-poison texels while the GPU-side reader (the present pass,
   and screen captures) shows 16k–31k exact-poison pixels: the CPU- and
   GPU-visible contents of the same Shared texture diverge.
3. Displaying via a classic queue that samples the MTL4-written texture
   still shows the poison: the corruption is created in the MTL4 pass,
   not in presentation.
4. Moving only the draws to a classic queue (identical pipelines from
   MTL4Compiler, identical geometry) is completely clean across many
   hours of runs.

## Suggested bisect for Apple
- privscene variant: scene RT in Private storage instead of Shared —
  still 18/18 poisoned, so the poison is not a CPU-side mapping artifact
  of Shared allocations; it is created GPU-side by the MTL4 execution
  path itself.
- The corruption requires MTL4-executed draws that write an offscreen
  render target that a later pass reads (the hybscene cell); an MTL4
  queue that only commits empty work or only holds pipelines/argument
  tables is harmless.
- 234,51,247 = BGRA bytes F7,33,EA — plausibly an AGX filler pattern
  for a GPU-side fault; is it a known filler?

## Questions for Apple
- Is a constant (234,51,247) run pattern a known AGX filler for a
  GPU-side mapping fault on Shared allocations under MTL4 residency?
- Is mixing CAMetalLayer.residencySet with an app residency set on an
  MTL4CommandQueue supported? (noattach/noresset variants change the
  failure mode to a frozen display, so the manual model appears required
  but is not itself the trigger.)

## Do-not-remove notes
- Without residency wiring the repro FREEZES instead (different bug); do
  not simplify that away when reducing the repro.
- Render loop must be off the main thread with NSApp run on main.
