# ------------------------------------------------------ #
# Makefile for the Metal 4 renderer lib for Quake II     #
#                                                        #
# Just type "make" to compile the                        #
#  - Metal 4 renderer lib (ref_mtl.dylib)                #
#                                                        #
# Base dependencies:                                     #
#  - SDL 2 or SDL 3                                      #
#  - Xcode with the macOS 26 SDK (Metal 4 headers)       #
#                                                        #
# Platforms:                                             #
#  - macOS (Metal 4 requires macOS 26, Apple silicon)    #
# ------------------------------------------------------ #

# Variables
# ---------
# ASAN
#   Builds with address sanitizer, includes DEBUG.
# DEBUG
#   Builds a debug build, forces -O0 and adds debug symbols.
# QUIET
#   If defined, "===> CC ..." lines are silenced.
# UBSAN
#   Builds with undefined behavior sanitizer, includes DEBUG.
# VERBOSE
#   Prints full compile, linker and misc commands.
# WERR
#   Treat compiler warnings as errors.
# ----------

# User configurable options
# -------------------------

# WITH_SDL3
# When disabled SDL 2 is used instead of SDL 3.
WITH_SDL3:=yes

# PKG_CONFIG
# Specify program that configures SDL.
PKG_CONFIG ?= pkgconf

# ----------

# Normalize QUIET value to either "x" or ""
ifdef QUIET
	override QUIET := "x"
else
	override QUIET := ""
endif

# ----------

# Check if it's pkgconf or pkg-config.
ifeq (, $(shell which $(PKG_CONFIG)))
ifneq (, $(shell which pkgconf))
PKG_CONFIG:=pkgconf
else
PKG_CONFIG:=pkg-config
endif
endif

# ----------

# Detect the OS. ref_mtl is macOS only: Metal 4 requires
# the macOS 26 SDK and Apple silicon (M1+ / A14+).
YQ2_OSTYPE := $(shell uname -s)

ifneq ($(YQ2_OSTYPE), Darwin)
$(error ref_mtl only supports macOS (Metal 4 requires macOS 26))
endif

YQ2_ARCH ?= $(shell uname -m)

# ----------

# Detect the compiler. Only clang is supported (ships with Xcode).
CC ?= cc
ifeq ($(shell $(CC) -v 2>&1 | grep -c "clang version"), 1)
COMPILER := clang
else
COMPILER := unknown
endif

# ASAN includes DEBUG
ifdef ASAN
DEBUG=1
endif

# UBSAN includes DEBUG
ifdef UBSAN
DEBUG=1
endif

# ----------

# Set up build and bin output directories

# Root dir names
override BINROOT :=
override BUILDROOT := build

ifdef DEBUG
	override BINDIR := $(BINROOT)debug
	override BUILDDIR := $(BUILDROOT)/debug
else
	override BINDIR := $(BINROOT)release
	override BUILDDIR := $(BUILDROOT)/release
endif

# ----------

# Base CFLAGS. The optimization part may be overridden by the
# environment; the warning flags are not (S4: a CFLAGS coming from
# the environment used to silently replace the whole base line,
# warnings included).
ifdef DEBUG
CFLAGS ?= -O0 -g -pipe -Werror=format-security -DDEBUG
ifdef ASAN
override CFLAGS += -fsanitize=address -DUSE_SANITIZER
endif
ifdef UBSAN
override CFLAGS += -fsanitize=undefined -DUSE_SANITIZER
endif
else
CFLAGS ?= -O2 -pipe -fomit-frame-pointer
endif

override CFLAGS += -Wall -Wpointer-arith

# Treat warnings as errors
ifdef WERR
override CFLAGS += -Werror
endif

# Always needed are:
#  -fno-strict-aliasing since the source doesn't comply
#   with strict aliasing rules and it's next to impossible
#   to get it there...
#  -fwrapv for defined integer wrapping. MSVC6 did this
#   and the game code requires it.
#  -fvisibility=hidden to keep symbols hidden. This is
#   mostly best practice and not really necessary.
override CFLAGS += -fno-strict-aliasing -fwrapv -fvisibility=hidden

# OS X architecture.
override CFLAGS += -arch $(YQ2_ARCH)

# S4: state the Metal 4 requirement at build time. Without a
# deployment target clang assumes the build host's OS version, so
# availability warnings for the Metal 4 API surface were silently
# "always new enough"; with this the requirement is consistent and
# also rides in the binary (LC_BUILD_VERSION), next to the runtime
# OS check in RE_InitContext.
override CFLAGS += -mmacosx-version-min=26.0

# ----------

# Switch of some annoying warnings.
ifeq ($(COMPILER), clang)
	# -Wno-missing-braces because otherwise clang complains
	#  about totally valid 'vec3_t bla = {0}' constructs.
	# -fno-common avoids linker warnings due
	#  uninitialized global variables treated as "common".
	#  On most platforms clang sets no-commom by default,
	#  MacOS is a prominent exception.
	override CFLAGS += -Wno-missing-braces -fno-common
endif

# ----------

# Defines the operating system and architecture
override CFLAGS += -DYQ2OSTYPE=\"$(YQ2_OSTYPE)\" -DYQ2ARCH=\"$(YQ2_ARCH)\"

# ----------

# For reproduceable builds, look here for details:
# https://reproducible-builds.org/specs/source-date-epoch/
# S4: this Makefile is macOS-only (OS check above), and BSD date has
# no GNU --date=@EPOCH form, so the epoch is formatted with the BSD
# form: date -u -r EPOCH. %e is BSD's space-padded day of month,
# matching what the GNU form's %_d produced.
ifdef SOURCE_DATE_EPOCH
override CFLAGS += -DBUILD_DATE=\"$(shell date -u -r "$(SOURCE_DATE_EPOCH)" +"%b %e %Y" | sed -e 's/ /\\ /g')\"
endif

# ----------

# Extra CFLAGS for SDL.
ifeq ($(WITH_SDL3),yes)
SDLCFLAGS := $(shell $(PKG_CONFIG) --cflags sdl3)
SDLCFLAGS += -DUSE_SDL3
else
SDLCFLAGS := $(shell sdl2-config --cflags)
endif

# ----------

# Base include path. Homebrew and MacPorts prefixes; the
# latter covers MacPorts installs that are symlinked into
# /opt/homebrew.
INCLUDE ?= -I/opt/homebrew/include -I/opt/local/include

# ----------

# Base LDFLAGS. This is just the library path.
LDFLAGS ?= -L/opt/homebrew/lib -L/opt/local/lib

# Link address sanitizer if requested.
ifdef ASAN
override LDFLAGS += -fsanitize=address
endif

# Link undefined behavior sanitizer if requested.
ifdef UBSAN
override LDFLAGS += -fsanitize=undefined
endif

# Required libraries.
LDLIBS ?= -arch $(YQ2_ARCH) -framework Metal -framework QuartzCore -framework Foundation

# S4: link with the same deployment target (see CFLAGS above) so the
# minos recorded in the dylib's LC_BUILD_VERSION matches.
override LDFLAGS += -mmacosx-version-min=26.0

# ----------

# Extra LDFLAGS for SDL
ifeq ($(WITH_SDL3),yes)
SDLLDFLAGS := -lSDL3
else
SDLLDFLAGS := -lSDL2
endif

# ----------

# When make is invoked by "make VERBOSE=1" print
# the compiler and linker commands.
ifdef VERBOSE
Q :=
else
Q := @
endif

# ----------

# Phony targets (S4: ref_mtl/clean/cleanall so a stray file or
# directory with those names cannot make the target a no-op)
.PHONY : all check-shaders ref_mtl clean cleanall

# ----------

# Builds everything
all: ref_mtl

# ----------

# S2: the MSL that actually runs is the generated C array, not the .msl
# files; a stale src/files/mtl_shaders.c otherwise builds and smokes
# green with the old shader baked in. Regenerate to a temp file and
# compare; on mismatch run the generator into place with
# "sh shaders/gen_msl.sh". tools/fix_verify.sh calls this first, so the
# gate can never pass on a stale embedded shader.
check-shaders:
	@echo "===> CHECK-SHADERS"
	${Q}tmp=$$(mktemp /tmp/mtl_shaders_check.XXXXXX); \
	sh shaders/gen_msl.sh "$$tmp" >/dev/null; \
	if cmp -s "$$tmp" src/files/mtl_shaders.c; then \
		rm -f "$$tmp"; \
	else \
		rm -f "$$tmp"; \
		echo "check-shaders: FAIL: src/files/mtl_shaders.c is stale, run: sh shaders/gen_msl.sh" >&2; \
		exit 1; \
	fi

# S2: also keep the generated file current inside a normal build when a
# .msl is newer. Without python3 the regeneration cannot run, so the
# rule only shouts; check-shaders then blocks the gate.
SRC_MSL := $(wildcard shaders/*.msl)

src/files/mtl_shaders.c: $(SRC_MSL) shaders/gen_msl.sh
	@if command -v python3 >/dev/null; then \
		sh shaders/gen_msl.sh; \
	else \
		echo "src/files/mtl_shaders.c is out of date and python3 is unavailable; regenerate on a machine that has it" >&2; \
		false; \
	fi

# ----------

# Cleanup. clean drops release/* (and debug/*), which includes the
# dylib that tools/fix_verify.sh builds and deploys next to the game
# binary - the next fix_verify run simply rebuilds it.
clean:
	@echo "===> CLEAN"
	${Q}rm -Rf build debug/* release/*

cleanall:
	@echo "===> CLEAN"
	${Q}rm -Rf build debug release

# ----------

ref_mtl:
	@echo "===> Building ref_mtl.dylib"
	${Q}mkdir -p $(BINDIR)
	$(MAKE) $(BINDIR)/ref_mtl.dylib

$(BINDIR)/ref_mtl.dylib : LDFLAGS += -shared

# .c files are plain C, .m files are Objective-C (the Metal
# API is an Objective-C API). Clang handles both by extension.
# -MMD -MP emits a .d depfile next to each .o so that editing a
# header (e.g. mtl.h) rebuilds every TU that includes it; without
# this, stale .o files can mix two struct layouts in one dylib.
DEPFLAGS = -MMD -MP

$(BUILDDIR)/%.o: %.c
	@if [ -z $(QUIET) ]; then\
		echo "===> CC $<";\
	fi
	${Q}mkdir -p $(@D)
	${Q}$(CC) -c $(CFLAGS) $(SDLCFLAGS) $(INCLUDE) $(DEPFLAGS) -o $@ $<

$(BUILDDIR)/%.o: %.m
	@if [ -z $(QUIET) ]; then\
		echo "===> CC $<";\
	fi
	${Q}mkdir -p $(@D)
	${Q}$(CC) -c $(CFLAGS) $(SDLCFLAGS) $(INCLUDE) $(DEPFLAGS) -o $@ $<

# ----------

REFMTL_OBJS_ := \
	src/mtl/mtl_alias.o \
	src/mtl/mtl_main.o \
	src/mtl/mtl_light.o \
	src/mtl/mtl_image.o \
	src/mtl/mtl_model.o \
	src/mtl/mtl_surf.o \
	src/mtl/mtl_warp.o \
	src/files/mtl_shaders.o \
	src/files/models.o \
	src/files/pcx.o \
	src/files/pvs.o \
	src/files/stb.o \
	src/files/surf.o \
	src/files/wal.o \
	src/common/shared.o \
	src/common/utils.o \
	src/common/md4.o \
	src/backends/hunk_unix.o

# ----------

# Rewrite paths to our object directory.
REFMTL_OBJS = $(patsubst %,$(BUILDDIR)/%,$(REFMTL_OBJS_))

# ----------

$(BINDIR)/ref_mtl.dylib : $(REFMTL_OBJS)
	@echo "===> LD $@"
	${Q}$(CC) $(LDFLAGS) $(REFMTL_OBJS) $(LDLIBS) $(SDLLDFLAGS) -o $@

# ----------

# Header dependencies generated by -MMD (-include: no error while the
# .d files do not exist yet, e.g. on a fresh checkout).
-include $(REFMTL_OBJS:.o=.d)
