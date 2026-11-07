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
make                 # build the four fuzzers (ASan+UBSan)
make seeds           # corpus/ from shipped paks (NOT committed)
make smoke           # 2000 iterations per target (AE1 gate)
make run T=fuzz_pcx TIME=1800 SEED=1     # 30 min session
make cov && make replay && make report   # line coverage per loader
```

Crash artifacts land in `crashers/` (git-ignored). Dictionaries for
each target live in `dictionaries/`; pass them with `-dict=`.

The seed corpus is generated from the shipped paks and loose game
files by `mkseedcorpus.py` and is never committed.

## Tier 2 status

`Mod_LoadBrushModel` (BSP) lives in `src/mtl/mtl_model.m` next to
the Metal renderer; see the AE3 notes in `REVIEW_EXTERNAL.md` for
the link-or-fallback decision recorded during round 22.
