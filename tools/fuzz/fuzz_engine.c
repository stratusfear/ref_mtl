/*
 * Copyright (C) 2026 ref_mtl port
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at
 * your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301, USA.
 */

/*
 * AE1: Engine-side stubs for the libFuzzer targets.

 * This is the only "engine" the loader translation units see: the ri
 * import table backed by a small in-memory filesystem, longjmp-based
 * error unwinding that mirrors the host's ERR_DROP recovery, and the
 * Hunk_MemoryRemaining() bookkeeping that catches half-built hunks
 * orphaned by an early error return (the AC1 class, Z4's poisoned
 * slot idea made portable: on macOS Hunk_Free() munmaps, so a leaked
 * hunk would be an invisible dangling mapping without this counter).
 *
 * Nothing here allocates per iteration except the malloc'd copies
 * handed out by FS_LoadFile(), which the loaders free exactly like
 * the host's FS does.
 */

#include "fuzz_common.h"

#include "../../src/common/header/stb_budget.h"

#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Error path: ri.Sys_Error() and the global Sys_Error() longjmp back
   into FUZZ_GUARD_BEGIN(), like Com_Error(ERR_DROP) does in the host.
   A clean rejection through this path is a PASS, not a crash.       */
/* ------------------------------------------------------------------ */

/* AG2: the jmp_buf is shared, NOT used from here.  The round-22 plumbing
   called setjmp() inside this file (FuzzSetjmp), so by the time
   ri.Sys_Error() unwound, that frame had long since returned: the
   recovery landed on a dead frame.  Measured on the AG2 nodes harness
   both ways - with ASan it died at a garbage address ("stack-overflow"
   with pc in the stack and no frames at all, even for the pre-existing
   planenum reject, which is why the bug hid: none of the round-22
   corpora contains an input that reaches Sys_Error), and with ASan off
   execution simply continued past the guarded call and counted the
   rejected load as a success.  setjmp must execute in the frame that
   longjmp returns to, so the targets call setjmp(fuzz_abort) themselves
   and this file only arms the guard flag. */
jmp_buf fuzz_abort;
static int fuzz_in_guard;
static char fuzz_last_error[512];

unsigned long fuzz_guard_hits;
unsigned long fuzz_hunk_orphans;
unsigned long fuzz_image_hits;
unsigned long fuzz_load_ok;

void
FuzzGuardArm(void)
{
	fuzz_in_guard = 1;
}

static YQ2_ATTR_NORETURN void
fuzz_error(int level, const char *fmt, va_list ap)
{
	vsnprintf(fuzz_last_error, sizeof(fuzz_last_error), fmt, ap);

	/* Metadata for a crashing input: the last loader complaint is
	   on stderr right before any sanitizer report. */
	fprintf(stderr, "\nloader error (level %d): %s\n", level,
		fuzz_last_error);

	if (fuzz_in_guard)
	{
		/* ERR_DROP is 1, ERR_FATAL is 2; both nonzero out of setjmp. */
		longjmp(fuzz_abort, level ? level : 1);
	}

	/* An error outside a guarded call means the harness is wrong or
	   the loader calls Sys_Error() from a place we do not guard.
	   Surface it loudly instead of unwinding into nothing. */
	fprintf(stderr, "harness bug: loader error outside guard frame\n");
	abort();
}

/* clang-mp-23 quirk (AE1): a _Noreturn function does NOT match the
   __attribute__((noreturn))-annotated ri.Sys_Error pointer type;
   the attribute spelling does. Verified with a minimal TU. */
static __attribute__((noreturn)) void
ri_sys_error(int err_level, const char *str, ...)
{
	va_list ap;

	va_start(ap, str);
	fuzz_error(err_level, str, ap);
}

YQ2_ATTR_NORETURN void
Sys_Error(const char *error, ...)
{
	va_list ap;

	va_start(ap, error);
	fuzz_error(ERR_DROP, error, ap);
}

/* Com_Printf: keep the text, discard the output; the last line is
   printed with any sanitizer report through fuzz_last_error's
   companion below.

   AF2.5: FUZZ_PRINT_ERRORS=1 also echoes every rejection line as it
   is produced.  Triaging a rejection needs the reason, and the
   crash-only echo above never runs for an input the loader turns
   down cleanly - until now the reason was only visible on a game
   host leg.  Off by default: a fuzzing session prints nothing new. */
static int fuzz_print_errors = -1;

void
Com_Printf(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(fuzz_last_error, sizeof(fuzz_last_error), fmt, ap);
	va_end(ap);

	if (fuzz_print_errors < 0)
	{
		fuzz_print_errors = getenv("FUZZ_PRINT_ERRORS") != NULL;
	}
	if (fuzz_print_errors)
	{
		fprintf(stderr, "loader: %s\n", fuzz_last_error);
	}
}

void
Com_DPrintf(const char *fmt, ...)
{
	/* Silence. */
}

/* ------------------------------------------------------------------ */
/* Memory-backed filesystem behind ri.                                */
/* ------------------------------------------------------------------ */

#define MEMFS_SLOTS 16

typedef struct
{
	char	name[256];
	byte	*data;
	int		len;
} memfile_t;

static memfile_t memfs[MEMFS_SLOTS];
static int memfs_count;

void
MemFS_Clear(void)
{
	int i;

	for (i = 0; i < memfs_count; i++)
	{
		free(memfs[i].data);
		memfs[i].data = NULL;
	}
	memfs_count = 0;
}

void
MemFS_Stage(const char *name, const byte *data, int len)
{
	if ((memfs_count >= MEMFS_SLOTS) || (len <= 0))
	{
		return;
	}

	Q_strlcpy(memfs[memfs_count].name, name, sizeof(memfs[0].name));
	memfs[memfs_count].data = (byte *)malloc(len);
	if (!memfs[memfs_count].data)
	{
		return;
	}
	memcpy(memfs[memfs_count].data, data, len);
	memfs[memfs_count].len = len;
	memfs_count++;
}

static int
fs_load_file(const char *name, void **buf)
{
	int i;

	*buf = NULL;

	for (i = 0; i < memfs_count; i++)
	{
		if (strcmp(memfs[i].name, name) == 0)
		{
			/* Hand out a copy: the host's FS_LoadFile() also
			   returns a malloc'd buffer which FS_FreeFile()
			   (and models.c' own free() path) release with
			   free(). */
			byte *copy = (byte *)malloc(memfs[i].len);

			if (!copy)
			{
				return 0;
			}
			memcpy(copy, memfs[i].data, memfs[i].len);
			*buf = copy;
			return memfs[i].len;
		}
	}

	/* Fallback: serve the first staged file for any other name so
	   that name-derived paths (sprite frames, Heretic2 .fm probes,
	   sky textures) also see fuzzer data with one load per input. */
	if (memfs_count && memfs[0].len > 0)
	{
		byte *copy = (byte *)malloc(memfs[0].len);

		if (!copy)
		{
			return 0;
		}
		memcpy(copy, memfs[0].data, memfs[0].len);
		*buf = copy;
		return memfs[0].len;
	}

	return 0;
}

static void
fs_free_file(void *buf)
{
	free(buf);
}

/* ------------------------------------------------------------------ */
/* Hunk bookkeeping: the real hunk_unix.c is linked, but compiled
   with its public entry points renamed (see Makefile HUNKREN), and
   these wrappers below provide the real names while counting.  The
   pending counter is exactly the brief's Hunk_Begin minus
   (Hunk_Free + Hunk_End) accounting: the AC1 class (a load that
   longjmps past its Hunk_Free) ends a guarded call with pending
   nonzero, which is printed and counted even though macOS has no
   LeakSanitizer and Hunk_Free() munmaps invisibly.                */
/* ------------------------------------------------------------------ */

extern void *FuzzRealHunkBegin(int maxsize);
extern void *FuzzRealHunkAlloc(int size);
extern int   FuzzRealHunkEnd(void);
extern void  FuzzRealHunkFree(void *base);

static int fuzz_hunk_pending;   /* Begin - (Free + End) */

void *
Hunk_Begin(int maxsize)
{
	void *r = FuzzRealHunkBegin(maxsize);

	if (r)
	{
		fuzz_hunk_pending++;
	}
	return r;
}

void *
Hunk_Alloc(int size)
{
	return FuzzRealHunkAlloc(size);
}

int
Hunk_End(void)
{
	int r = FuzzRealHunkEnd();

	fuzz_hunk_pending--;
	return r;
}

void
Hunk_Free(void *buf)
{
	FuzzRealHunkFree(buf);
	if (buf)
	{
		fuzz_hunk_pending--;
	}
}

int
FuzzHunk_Begin(void)
{
	return fuzz_hunk_pending;
}

/* The real hunk_unix.c maps a size_t header ahead of membase; this
   is the extradata pointer every loader handed to Hunk_Free. */
extern byte *membase;

void
FuzzHunk_End(int before, const char *what, int expect_mapped)
{
	int delta = fuzz_hunk_pending - before;

	fuzz_in_guard = 0;
	if (delta != 0)
	{
		/* A completed model load deliberately keeps its hunk
		   mapped; that is the product, not a leak. Anything else
		   that ends a guarded call with a hunk still mapped is the
		   AC1 class: recovery gave nothing back. */
		if (!(expect_mapped && (delta == 1)))
		{
			fuzz_hunk_orphans++;
			fprintf(stderr,
				"HUNK_ORPHAN in %s: %d hunk mapping(s) "
				"not returned (pending=%d)\n",
				what, delta, fuzz_hunk_pending);
		}

		/* Unmap whatever the guarded call left behind so the next
		   iteration starts from the same state. */
		while ((fuzz_hunk_pending > before) && membase)
		{
			FuzzRealHunkFree(membase + sizeof(size_t));
			fuzz_hunk_pending--;
		}
	}
}

/* ------------------------------------------------------------------ */
/* Fixed loader callbacks.                                            */
/* ------------------------------------------------------------------ */

struct image_s *
FuzzLoadImage(const char *name, byte *pic, int width, int realwidth,
	int height, int realheight, size_t data_size, imagetype_t type,
	int bits)
{
	/* The loaders never dereference the returned image; the real
	   renderer allocates it. One shared, never-freed stand-in keeps
	   the success path exercised without per-iteration allocation. */
	static struct image_s *stub;

	fuzz_image_hits++;
	if (!stub)
	{
		stub = (struct image_s *)calloc(1, 128);
	}
	(void)name; (void)pic; (void)width; (void)realwidth;
	(void)height; (void)realheight; (void)data_size;
	(void)type; (void)bits;
	return stub;
}

struct image_s *
FuzzFindImage(const char *name, imagetype_t type)
{
	(void)name; (void)type;
	return NULL;
}

/* ------------------------------------------------------------------ */
/* AL1 (round 29): the stb budget bridge (stb_budget.h).  AJ1 gave
   stb.c three callers that live in Metal TUs (MTL_STBMarkImage in
   mtl_image.m, the two budget-value readers in mtl_main.m); the
   harness links no Metal TU, so since 8f7b206 every fuzz target
   failed to link.  The stubs below keep the budget code paths in
   stb.c exercised, honestly: */
/* ------------------------------------------------------------------ */

void
MTL_STBMarkImage(struct image_s *slot, long long canvas_bytes)
{
	/* The real one binds the claim to the image slot and releases
	   it when the slot is wiped.  FuzzLoadImage hands out one
	   shared stand-in that dies with each iteration, so the slot's
	   whole lifetime is this call's end: release the charge
	   immediately.  A return-only stub would be the silent
	   failure mode: charges accumulate to the budget and every
	   later decode is refused without any input-side reason. */
	(void)slot;
	MTL_STBReleaseBytes(canvas_bytes);
}

long long
MTL_STBEffectiveBudgetBytes(void)
{
	/* Engine default: the r_stb_budget cvar default is 1024 MB
	   (mtl_main.m); the cvar does not exist in the harness, so
	   the literal with its provenance is the faithful stand-in.
	   1024 MB also sits 7.6x above the round-27 swept worst case
	   (135 MB peak, mapbudget sweep), so corpus decodes stay
	   admissible and refusals stay input-driven. */
	return 1024LL * 1024 * 1024;
}

long long
MTL_STBBudgetCeilingBytes(void)
{
	/* No Metal device here, so no device term: the ceiling is
	   the absolute hard-max term alone. */
	return STB_BUDGET_HARD_MAX_BYTES;
}

/* ------------------------------------------------------------------ */
/* The import table the loaders actually use: FS_LoadFile,
   FS_FreeFile, Sys_Error. Everything else stays NULL: a loader
   touching an unstubbed import dies on a null call and the crash
   report names the line, which is exactly what we want to know.    */
/* ------------------------------------------------------------------ */

refimport_t ri =
{
	.Sys_Error  = ri_sys_error,
	.FS_LoadFile = fs_load_file,
	.FS_FreeFile = fs_free_file,
};

__attribute__((constructor))
static void
fuzz_engine_init(void)
{
	/* Keep odd inputs from killing a run through a stray write. */
	signal(SIGPIPE, SIG_IGN);
}

/* libFuzzer owns main(), so the per-target quality signal goes out
   at exit instead: how much of the input space actually reached a
   decoder (image_hits) versus bounced off the error path
   (guard_hits), and whether any hunk was left orphaned.  All-zero
   image_hits on a seed corpus means the harness wiring is wrong,
   which is worth spotting on the smoke run, not after an hour. */
__attribute__((destructor))
static void
fuzz_engine_fini(void)
{
	fprintf(stderr, "FUZZ_STATS guard_hits=%lu load_ok=%lu image_hits=%lu "
		"hunk_orphans=%lu\n",
		fuzz_guard_hits, fuzz_load_ok, fuzz_image_hits, fuzz_hunk_orphans);
}
