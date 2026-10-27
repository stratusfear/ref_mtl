# Bug C — intermittent constant-magenta display corruption (ref_mtl / Metal 4)

Symptom: with ref_mtl's W6 architecture (MTL4 command queue + offscreen scene
RT + present pass), the on-screen display intermittently shows runs of exact
**(234,51,247)** pixels (10–30px horizontal runs, not tile-aligned), confined
to the layer content rect. Never observed via CPU `getBytes` of any texture;
window move clears or creates it. 100% reproducible rate in the standalone
repro below; ~70%/capture in quake2 with `framebufferOnly=NO` offscreen config.

## Repro

    clang -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore repro.m -o repro
    ./sweep.sh 6 default            # 6 runs x 30s, 3 window captures each

`analyze.py` counts strict-mask pixels (±12 around 234/51/247) per capture,
skipping the 64px titlebar, and `animated_diff` to distinguish a live display
from a frozen one. Captures require System Events window bounds (see sweep.sh).

Gotchas:
- render loop must run on a pthread; `[NSApp run]` on main (windowless layer
  starves `nextDrawable` -> hang).
- view frame must be (0,0,w,h), contentsScale 2, BGRA8Unorm.
- without residency-set wiring the failure mode changes to a FROZEN window
  (+ sometimes whole-frame poison), which is a different bug. Do not compare
  rates across the residency boundary.
- `--scan` uses `getBytes` which can block on drawable IOSurface lock once
  presents latch; keep scans on scene_tex only.

## Faithfulness checklist (all required to reproduce)

MTL4 queue + reused CB + 3 allocators; MTL4Compiler pipelines; argument
tables via gpuAddress/gpuResourceID; offscreen scene RT (Load between passes);
end order endCommandBuffer -> waitForDrawable -> commit -> signalEvent ->
signalDrawable -> present; residency sets wired (`addResidencySet:` own set +
`layer.residencySet` — confirmed non-nil: AGXG13XFamilyResidencySet).

## Bisect matrix (old binary, 6 runs x 3 captures, strict ±12)

| variant | result |
|---|---|
| default (MTL4 queue, all 3 passes) | 17/18 poisoned, 40k–350k px |
| --nosyncdraw | 18/18 poisoned (manual sync ops exonerated) |
| --classic | 0/18 clean |
| --hybrid (classic queue draws all, MTL4 PPLs kept, MTL4 queue idle) | 0/18 clean |
| --empty4 (MTL4 commits EMPTY CB + signalEvent, classic draws) | 0/18 clean |
| --hybscene (MTL4 scene passes, present on classic queue) | 18/18 poisoned, 16k–31k px |
| --txn / --yes / --txn --yes | 18/18 poisoned; txn variants also FREEZE display |
| --nodraw (MTL4 encoders, zero draws) | 0/18 poison but frozen |
| --noresset | frozen; 3/6 whole-frame poison (different failure) |

Conclusions:
- Trigger is the **MTL4 queue EXECUTING draws**. Queue existence, commit,
  event signaling, argument tables, MTL4 pipelines, manual sync ops, layer
  knobs are all exonerated.
- Mitigation by moving present-to-drawable onto a classic queue is DEAD
  (hybscene still poisoned): the MTL4 queue corrupts the offscreen scene
  GPU-side; the classic present pass faithfully copies garbage.
- Poison scale correlates with MTL4 draw count (all passes >> scene-only).
- Forensics: display captures show EXACT (234,51,247); simultaneous CPU
  getBytes of scene_tex shows only 4–96 near-poison texels. CPU-visible vs
  GPU-visible content of the Shared texture diverge -> MTL4 residency /
  GPU-mapping corruption, not a shader bug.

## Queued (rebuilt binary) — this sweep round

Methodology guard: a display sleep during a sweep invalidates captures
(screencapture fails and WindowServer stops compositing, which can change
the failure mode). Keep a `caffeinate -i` assertion for the whole sweep;
runrest.sh does this.

- default — revalidated on rebuilt binary: 18/18 poisoned, 28k-300k px, live
  display (animated_diff 48k-76k sampled px). Matches the old binary.
- wonly / uionly — INVALID experiments: without the present pass nothing
  lands on the drawable, animated_diff=0 (static display). They only prove
  a frozen display neither gains nor spreads poison. To split which pass
  corrupts the scene, use --scan (scene CPU counts) instead.
- noattach — 12/18 poisoned BUT all runs frozen (animated_diff=0, sticky
  per-run counts 227972/335239/222412/3411, 3 runs clean): reverting to the
  pre-residency failure mode. Auto-residency model is DEAD as a fix.
- drawres — 18/18 poisoned (live). Drawable residency per frame: DEAD.
- syncpresent — 18/18 poisoned (live). DEAD.
- fullsync — 18/18 poisoned (live). DEAD.

Round 2 (rebuilt binary with --privscene):
- privscene — 18/18 poisoned (live). Private storage for the scene RT does
  NOT help. Shared-vs-Private mapping theory: DEAD.
- newcb — 18/18 poisoned (live). Fresh MTL4CommandBuffer per frame: DEAD.
- maxdraw1 — impossible: CAMetalLayer.maximumDrawableCount range is [2,3]
  on this OS (exception at startup).

Round 3 (knobs added: --direct, --clscene) — all live displays
(animated_diff 42k-73k sampled px):
- direct   — MTL4 queue renders world+UI passes STRAIGHT into the drawable
  (pre-W6 architecture, no offscreen RT, fbonly NO): 0/18 CLEAN.
- clscene  — classic queue WRITES the offscreen scene; MTL4 queue only
  SAMPLES it (present pass) and owns the drawable sync/present: 0/18 CLEAN.
- maxdraw2 — 18/18 poisoned. Pool size irrelevant (maxdraw1 impossible:
  CAMetalLayer range is [2,3]).

REFINED TRIGGER MODEL (replaces "MTL4 executing draws"):
| MTL4 role                              | result |
|----------------------------------------|--------|
| writes an app-created offscreen RT     | poison |
| writes drawables only (direct)         | clean  |
| reads/presents app RT (clscene)        | clean  |
| idle / empty CB only (hybrid/empty4)   | clean  |

=> The bug is: an MTL4-executed render pass whose render target is an
APP-CREATED texture. Writes to CAMetalLayer drawables and pure reads are
safe; the classic queue is safe for the same passes.

Mitigation impact: the clscene split (scene draws on classic queue,
present stays on MTL4) is proven clean, but in ref_mtl it is ~95% of the
full classic-port work (all world/UI encoders+bindings move anyway), so
the port decision does not shrink; the full --hybrid remains the plan
unless hyb_yes/direct_yes (round 4) change the calculus.
Round 4 (running): hyb_yes = hybrid mitigation under framebufferOnly=YES
(the W6 goal flag); direct_yes = repro analog of pre-W6 quake2 YES, which
was ~10/12 poisoned — tests whether fbonly=YES makes the drawable itself
behave like an app-created RT (secondary trigger).

## Port sites in ref_mtl (mtl_main.m) for the chosen fix

- drawres: in RE_BeginFrame after `st->drawable = drawable;` (~line 2295):
  addAllocation:drawable.texture + commit on st->residency_set; remove the
  previous frame's drawable allocation before adding the new one (keep the
  set bounded to maximumDrawableCount entries).
- noattach: remove the `addResidencySet:layer.residencySet` block in
  RE_InitContext (~line 2110; also the removeResidencySet counterpart in
  the teardown path ~line 568).
- classic-queue fallback: replace `newMTL4CommandQueue` + MTL4 encoders +
  commit tail (~2511-2534) with classic queue + classic encoders; keep the
  MTL4Compiler-created pipelines (they are plain id<MTLRenderPipelineState>).
