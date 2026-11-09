# ref_mtl loader fuzzing harness (AE1)

libFuzzer targets for the ref_mtl file loaders. Each target links
the real loader translation unit(s), the real hunk allocator
(`src/backends/hunk_unix.c`) and the shared ref glue
(`src/common/shared.c`, `utils.c`, `md4.c`); the engine side is the
small stub layer in `fuzz_engine.c` (memory-backed `ri` filesystem,
longjmp-based `ERR_DROP`/`ERR_FATAL` recovery, Hunk bookkeeping).

## Targets

| binary          | loader TU(s)        | entry points |
|-----------------|---------------------|--------------|
| `fuzz_pcx`      | `src/files/pcx.c`   | `LoadPCX`, `GetPCXInfo` |
| `fuzz_wal`      | `src/files/wal.c`   | `LoadWal`, `LoadM8`, `LoadM32`, `GetWalInfo`, `GetM8Info`, `GetM32Info` |
| `fuzz_stb`      | `src/files/stb.c` (+`pcx.c` for the pipeline) | `LoadSTB` (TGA/PNG/JPG through vendored `stb_image.h`), `ResizeSTB`, `R_LoadImage` |
| `fuzz_models`   | `src/files/models.c`| `Mod_LoadAliasModel` (MDL/MD2/DKM), `Mod_LoadSP2` |
| `fuzz_pvs`      | `src/files/pvs.c`   | `Mod_DecompressVis` (synthesized `Mod_ClusterPVS` call, AE10; seeds from `pvsseeds.py`) |

Design rules (round-22 brief):

- one libFuzzer binary per target; one load per input
  (`LLVMFuzzerTestOneInput` stages the bytes and performs the loads);
- `ri.Sys_Error()`/`Sys_Error()` `longjmp` back into the target, and
  the harness then runs the host-style recovery check: the delta of
  `Hunk_MemoryRemaining()` across the guarded call must be zero
  unless a completed load deliberately kept its hunk as the model
  (`Hunk_Free(NULL)` resets between iterations). This is the
  portable form of Z4's poisoned-slot trick and reports AC1-class
  orphans even though macOS has no LeakSanitizer;
- a clean `ERR_DROP` rejection is a PASS; only a sanitizer report,
  signal, or an unbalanced hunk counter is a finding;
- UBSan runs non-recovering (`-fno-sanitize-recover=undefined`).

## Toolchain

Required and verified on this machine:

```
/opt/local/bin/clang-mp-23        build + fuzz
/opt/local/bin/llvm-profdata-mp-23  coverage merge
/opt/local/bin/llvm-cov-mp-23       coverage report
```

clang-mp-20 with ASan hangs at startup on this host *silently* - do
not use it. Verified fallback (used if clang-mp-23 ever vanishes):

```
/usr/bin/clang -g -O1 -fno-omit-frame-pointer \
  -fsanitize=address,undefined -fno-sanitize-recover=undefined \
  -fsanitize-coverage=inline-8bit-counters,indirect-calls,trace-cmp,pc-table \
  ... /opt/local/libexec/llvm-20/lib/clang/20/lib/darwin/libclang_rt.fuzzer_osx.a -lc++
```

## Use

```sh
make                 # build all six fuzzers (ASan+UBSan)
make seeds           # corpus/ from shipped paks (NOT committed)
make smoke           # seeds + 2000 mutated iterations per target (AE1 gate)
make run T=fuzz_pcx TIME=1800 SEED=1     # 30 min session
make cov && make replay && make report   # line coverage per loader
```

Crash artifacts land in `crashers/` (git-ignored). Dictionaries for
each target live in `dictionaries/`; `make smoke`/`make run` pass
them with `-dict=` when present (`fuzz_nodes` has never had one -
AL1 made the flag conditional rather than shipping a dict that
would change its mutation distribution after the fact). Since
round-29 AL1 the outer gate (`tools/fix_verify.sh`) also builds all
six fuzz targets on every run, so a loader-side bridge change cannot
 silently break the harness link again.

The seed corpus is generated from the shipped paks and loose game
files by `mkseedcorpus.py` and is never committed.

## Tier 2: BSP via the batched host (`bspfuzz/`)

`Mod_LoadBrushModel` lives in `src/mtl/mtl_model.m` next to the
Metal renderer and did not link into the libFuzzer harness (the
whole renderer context comes with it).  AE3's fallback drives it
through the real game host instead:

```sh
python3 bspfuzz/genbsp.py --datadir <datadir> --out <maps> \
        --count 300 --seed 1
python3 bspfuzz/batchhost.py --host <ASan-host quake2> \
        --datadir <datadir> --maps <maps> --work <scratch>
```

`genbsp.py` mutates shipped BSPs with the weights the brief asks
for: 60% lump-directory (the 19 `lump_t` offset/length pairs), 25%
in-lump count words, 10% raw bytes, 5% header version; it writes a
MANIFEST.tsv so every mutant is reproducible from the seed.
`batchhost.py` runs one host boot per map and classifies the
outcome from `qconsole.log` + captured stderr (`loaded`, `errdrop`,
`asan` with the full report kept under `<work>/reports/`).

Why one boot per map (measured 2026-11-06, this tree): queued
`+map a +map b` does not survive an ERR_DROP - Host_Error clears
the command buffer, the game subsystems shut down, and the client
sits in the attract loop; console stdin is dedicated-only
(`src/backends/unix/system.c`), so the loop cannot type the next
`map` into a running client either.  A boot costs ~5 s with the
ASan host, so several hundred maps per hour chew through the run.

