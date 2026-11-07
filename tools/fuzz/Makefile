# ------------------------------------------------------ #
# AE1: libFuzzer harnesses for the ref_mtl file loaders  #
#                                                        #
# make          build ASan+UBSan fuzzers (build/)        #
# make seeds    build seed corpus from shipped paks      #
# make smoke    2000 iterations per target (gate)        #
# make run T=fuzz_pcx TIME=1800 SEED=1  long session     #
# make cov      build coverage-instrumented binaries     #
# make replay   replay corpus through the cov binaries   #
# make report   llvm-cov line coverage per loader        #
#                                                        #
# Toolchain notes (AE1):                                 #
#  - clang-mp-20 with ASan hangs at startup on this      #
#    host, silently. Everything here uses clang-mp-23.   #
#  - clang-mp-23 does not accept a _Noreturn function    #
#    for a __attribute__((noreturn))-annotated function  #
#    pointer type (verified on a minimal TU); the        #
#    harness stubs use the attribute spelling.           #
#  - Fallback toolchain (verified): Apple clang plus     #
#    the llvm-20 fuzzer runtime, see README.md.          #
# ------------------------------------------------------ #

# CC is a builtin make variable (cc), so ?= never assigns: use :=
# and override with `make CC=...` on the command line if needed.
CC       := /opt/local/bin/clang-mp-23
PROFDATA := /opt/local/bin/llvm-profdata-mp-23
LLCOV    := /opt/local/bin/llvm-cov-mp-23
PY       ?= python3

SRCDIR   := ../../src
OBJDIR   := obj
COVOBJ   := objcov
BUILD    := build
COVDIR   := build_cov
PROFDIR  := profraw

TARGETS  := fuzz_pcx fuzz_wal fuzz_stb fuzz_models fuzz_pvs

# The exact flags from the round-22 brief: fuzzer + ASan + UBSan,
# UBSan non-recovering so every report kills the run.
FUZZFLAGS := -g -O1 -fno-omit-frame-pointer \
             -fsanitize=fuzzer,address,undefined \
             -fno-sanitize-recover=undefined

# Matching the shipping build's C semantics and build-system defines.
CMFLAGS := -fno-strict-aliasing -fwrapv -Wall \
           -DYQ2OSTYPE=\"unix\" -DYQ2ARCH=\"aarch64\"

COVFLAGS := -g -O1 -fprofile-instr-generate -fcoverage-mapping \
            -fsanitize=fuzzer

# All loader TUs link into every target: FixFileExt() lives in
# stb.c and is needed by pcx.c/wal.c, and dead-stripped extras do
# not hurt. Unused translation units only widen the coverage
# denominator slightly.
LOADERS  := pcx wal stb models pvs
LOADER_OBJS     := $(addprefix $(OBJDIR)/,$(addsuffix .o,$(LOADERS)))
COVLOADER_OBJS  := $(addprefix $(COVOBJ)/,$(addsuffix .o,$(LOADERS)))

COMMON_C := fuzz_engine.c \
            $(SRCDIR)/common/shared.c \
            $(SRCDIR)/common/utils.c \
            $(SRCDIR)/common/md4.c

# The real hunk_unix.c, compiled unmodified but with its public
# entry points renamed; fuzz_engine.c provides the real names as
# counting wrappers (Hunk_Begin minus Hunk_Free/Hunk_End).
HUNKREN  := -DHunk_Begin=FuzzRealHunkBegin \
            -DHunk_Alloc=FuzzRealHunkAlloc \
            -DHunk_End=FuzzRealHunkEnd \
            -DHunk_Free=FuzzRealHunkFree

CORPUS   := corpus
CRASHDIR := crashers

.PHONY: all smoke cov covbins replay report seeds clean fuzzers

all: fuzzers

fuzzers: $(addprefix $(BUILD)/,$(TARGETS))

$(BUILD) $(OBJDIR) $(COVDIR) $(COVOBJ) $(PROFDIR):
	@mkdir -p $@

# --- object rules (fuzz build) ---

$(OBJDIR)/%.o: %.c fuzz_common.h | $(OBJDIR)
	$(CC) $(FUZZFLAGS) $(CMFLAGS) -c -o $@ $<

$(OBJDIR)/%.o: $(SRCDIR)/common/%.c | $(OBJDIR)
	$(CC) $(FUZZFLAGS) $(CMFLAGS) -c -o $@ $<

$(OBJDIR)/%.o: $(SRCDIR)/files/%.c | $(OBJDIR)
	$(CC) $(FUZZFLAGS) $(CMFLAGS) -c -o $@ $<

$(OBJDIR)/hunk_unix.o: $(SRCDIR)/backends/hunk_unix.c | $(OBJDIR)
	$(CC) $(FUZZFLAGS) $(CMFLAGS) $(HUNKREN) -c -o $@ $<

$(BUILD)/fuzz_pcx: $(OBJDIR)/fuzz_pcx.o $(OBJDIR)/fuzz_engine.o $(OBJDIR)/shared.o $(OBJDIR)/utils.o $(OBJDIR)/md4.o $(OBJDIR)/hunk_unix.o $(LOADER_OBJS) | $(BUILD)
	$(CC) $(FUZZFLAGS) -o $@ $^

$(BUILD)/fuzz_wal: $(OBJDIR)/fuzz_wal.o $(OBJDIR)/fuzz_engine.o $(OBJDIR)/shared.o $(OBJDIR)/utils.o $(OBJDIR)/md4.o $(OBJDIR)/hunk_unix.o $(LOADER_OBJS) | $(BUILD)
	$(CC) $(FUZZFLAGS) -o $@ $^

$(BUILD)/fuzz_stb: $(OBJDIR)/fuzz_stb.o $(OBJDIR)/fuzz_engine.o $(OBJDIR)/shared.o $(OBJDIR)/utils.o $(OBJDIR)/md4.o $(OBJDIR)/hunk_unix.o $(LOADER_OBJS) | $(BUILD)
	$(CC) $(FUZZFLAGS) -o $@ $^

$(BUILD)/fuzz_models: $(OBJDIR)/fuzz_models.o $(OBJDIR)/fuzz_engine.o $(OBJDIR)/shared.o $(OBJDIR)/utils.o $(OBJDIR)/md4.o $(OBJDIR)/hunk_unix.o $(LOADER_OBJS) | $(BUILD)
	$(CC) $(FUZZFLAGS) -o $@ $^

$(BUILD)/fuzz_pvs: $(OBJDIR)/fuzz_pvs.o $(OBJDIR)/fuzz_engine.o $(OBJDIR)/shared.o $(OBJDIR)/utils.o $(OBJDIR)/md4.o $(OBJDIR)/hunk_unix.o $(LOADER_OBJS) | $(BUILD)
	$(CC) $(FUZZFLAGS) -o $@ $^

# --- smoke: >=2000 mutated iterations per target, well under 2 min ---
# -runs counts corpus INITED too, and the seed corpora are bigger
# than 2000 files, which would leave zero mutated executions.  Run
# over the seeds once plus a 2000-iteration margin, time-boxed.

smoke: fuzzers
	@for t in $(TARGETS); do \
		n=$$(ls $(CORPUS)/$$t 2>/dev/null | wc -l | tr -d ' '); \
		[ "$$n" -gt 0 ] || n=1; \
		echo "===> smoke $$t (seeds=$$n +2000)"; \
		$(BUILD)/$$t $(CORPUS)/$$t \
			-runs=$$((n + 2000)) -max_total_time=25 -timeout=30 \
			-error_exitcode=1 \
			-rss_limit_mb=4096 \
			-dict=dictionaries/$${t#fuzz_}.dic \
			-artifact_prefix=$(CRASHDIR)/ || exit 1; \
	done

# --- long session: make run T=fuzz_pcx TIME=1800 SEED=1 ---

TIME ?= 1800
SEED ?= 0

run: fuzzers
	$(BUILD)/$(T) $(CORPUS)/$(T) \
		-max_total_time=$(TIME) -error_exitcode=1 \
		-rss_limit_mb=8192 -artifact_prefix=$(CRASHDIR)/ \
		-dict=dictionaries/$${T#fuzz_}.dic \
		-rand_seed=$(SEED)

# --- coverage build (same entry points, profile intrinsics) ---

cov: covbins

covbins: $(addprefix $(COVDIR)/,$(TARGETS))

$(COVOBJ)/%.o: %.c fuzz_common.h | $(COVOBJ)
	$(CC) $(COVFLAGS) $(CMFLAGS) -c -o $@ $<

$(COVOBJ)/%.o: $(SRCDIR)/common/%.c | $(COVOBJ)
	$(CC) $(COVFLAGS) $(CMFLAGS) -c -o $@ $<

$(COVOBJ)/%.o: $(SRCDIR)/files/%.c | $(COVOBJ)
	$(CC) $(COVFLAGS) $(CMFLAGS) -c -o $@ $<

$(COVOBJ)/hunk_unix.o: $(SRCDIR)/backends/hunk_unix.c | $(COVOBJ)
	$(CC) $(COVFLAGS) $(CMFLAGS) $(HUNKREN) -c -o $@ $<

$(COVDIR)/fuzz_pcx: $(COVOBJ)/fuzz_pcx.o $(COVOBJ)/fuzz_engine.o $(COVOBJ)/shared.o $(COVOBJ)/utils.o $(COVOBJ)/md4.o $(COVOBJ)/hunk_unix.o $(COVLOADER_OBJS) | $(COVDIR)
	$(CC) $(COVFLAGS) -o $@ $^

$(COVDIR)/fuzz_wal: $(COVOBJ)/fuzz_wal.o $(COVOBJ)/fuzz_engine.o $(COVOBJ)/shared.o $(COVOBJ)/utils.o $(COVOBJ)/md4.o $(COVOBJ)/hunk_unix.o $(COVLOADER_OBJS) | $(COVDIR)
	$(CC) $(COVFLAGS) -o $@ $^

$(COVDIR)/fuzz_stb: $(COVOBJ)/fuzz_stb.o $(COVOBJ)/fuzz_engine.o $(COVOBJ)/shared.o $(COVOBJ)/utils.o $(COVOBJ)/md4.o $(COVOBJ)/hunk_unix.o $(COVLOADER_OBJS) | $(COVDIR)
	$(CC) $(COVFLAGS) -o $@ $^

$(COVDIR)/fuzz_models: $(COVOBJ)/fuzz_models.o $(COVOBJ)/fuzz_engine.o $(COVOBJ)/shared.o $(COVOBJ)/utils.o $(COVOBJ)/md4.o $(COVOBJ)/hunk_unix.o $(COVLOADER_OBJS) | $(COVDIR)
	$(CC) $(COVFLAGS) -o $@ $^

$(COVDIR)/fuzz_pvs: $(COVOBJ)/fuzz_pvs.o $(COVOBJ)/fuzz_engine.o $(COVOBJ)/shared.o $(COVOBJ)/utils.o $(COVOBJ)/md4.o $(COVOBJ)/hunk_unix.o $(COVLOADER_OBJS) | $(COVDIR)
	$(CC) $(COVFLAGS) -o $@ $^

# Replay the final corpora through the coverage binaries so the
# instrumented run sees exactly the inputs the fuzzing ended with.
# 0 = replay exactly the corpus units, no fresh mutations: the line
# coverage then belongs to the fuzz sessions, not to the replay run.
REPLAY_RUNS ?= 0

replay: covbins
	@rm -f $(PROFDIR)/*.profraw
	@for t in $(TARGETS); do \
		echo "===> replay $$t"; \
		LLVM_PROFILE_FILE=$(PROFDIR)/$$t-%p-%m.profraw \
		$(COVDIR)/$$t $(CORPUS)/$$t \
			-runs=$(REPLAY_RUNS) -timeout=60 \
			-rss_limit_mb=4096 -artifact_prefix=$(CRASHDIR)/ \
			-error_exitcode=1 || exit 1; \
	done
	$(PROFDATA) merge -sparse $(PROFDIR)/*.profraw -o $(PROFDIR)/combined.profdata

# every fuzz_* binary is an -object: each target links all loaders,
# so a loader's counts live in the binary that fuzzed it.
# -name-regex=src/files scopes the report to the loaders.  (llvm-23
# dropped the -show-branches=count spelling the draft used.)
report:
	$(LLCOV) report $(foreach t,$(TARGETS),-object $(COVDIR)/$(t)) \
		-instr-profile=$(PROFDIR)/combined.profdata \
		-name-regex=src/files

# --- seed corpus from shipped paks (not committed) ---

seeds:
	$(PY) mkseedcorpus.py
	$(PY) pvsseeds.py $(CORPUS)/fuzz_pvs

clean:
	rm -rf $(BUILD) $(COVDIR) $(PROFDIR) $(OBJDIR) $(COVOBJ)
