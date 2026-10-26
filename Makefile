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

# Base CFLAGS. These may be overridden by the environment.
ifdef DEBUG
CFLAGS ?= -O0 -g -Wall -Wpointer-arith -pipe -Werror=format-security -DDEBUG
ifdef ASAN
override CFLAGS += -fsanitize=address -DUSE_SANITIZER
endif
ifdef UBSAN
override CFLAGS += -fsanitize=undefined -DUSE_SANITIZER
endif
else
CFLAGS ?= -O2 -Wall -Wpointer-arith -pipe -fomit-frame-pointer
endif

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
ifdef SOURCE_DATE_EPOCH
override CFLAGS += -DBUILD_DATE=\"$(shell date --utc --date="@${SOURCE_DATE_EPOCH}" +"%b %_d %Y" | sed -e 's/ /\\ /g')\"
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

# Phony targets
.PHONY : all

# ----------

# Builds everything
all: ref_mtl

# ----------

# Cleanup
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
$(BUILDDIR)/%.o: %.c
	@if [ -z $(QUIET) ]; then\
		echo "===> CC $<";\
	fi
	${Q}mkdir -p $(@D)
	${Q}$(CC) -c $(CFLAGS) $(SDLCFLAGS) $(INCLUDE) -o $@ $<

$(BUILDDIR)/%.o: %.m
	@if [ -z $(QUIET) ]; then\
		echo "===> CC $<";\
	fi
	${Q}mkdir -p $(@D)
	${Q}$(CC) -c $(CFLAGS) $(SDLCFLAGS) $(INCLUDE) -o $@ $<

# ----------

REFMTL_OBJS_ := \
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
