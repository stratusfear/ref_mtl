/*
 * AE1: Shared plumbing for the libFuzzer targets in this directory.
 *
 * Every target links the real loader translation units (pcx.c, wal.c,
 * stb.c, models.c), the real hunk allocator (hunk_unix.c) and the
 * shared ref glue (common/shared.c). The engine side is this file: a
 * memory-backed filesystem behind the ri import table and a
 * longjmp-based error path, so that an ERR_DROP (or ERR_FATAL) from a
 * loader unwinds like it does in the host engine instead of exiting.
 *
 * Two things every target must do around each guarded loader call:
 *
 *   FUZZ_GUARD_BEGIN()            setjmp; if nonzero we were thrown
 *                                 back by ri.Sys_Error()/Sys_Error()
 *   ...the loader call...
 *   FUZZ_GUARD_END(before)        Hunk_MemoryRemaining() bookkeeping
 *
 * The hunk accounting (fuzz_engine.c: real hunk_unix.c compiled
 * with renamed entry points behind counting wrappers) is the orphan
 * detector: a loader that throws past a Hunk_Begin() without giving
 * the hunk back (the AC1 class) leaves the Begin-free-Begin count
 * nonzero at the end of the guarded call, which is printed and
 * counted even though macOS LeakSanitizer cannot see mmap'd hunks.
 */

#ifndef FUZZ_COMMON_H
#define FUZZ_COMMON_H

#include "../../src/common/header/ref_shared.h"

/* qtrue/qfalse: host-side constants the ref sources see through the
   engine headers; the harness provides the same spellings. */
#ifndef qtrue
#define qtrue  1
#define qfalse 0
#endif

/* Stage one in-memory file for the ri.FS_LoadFile() stub. The last
   staged entry also serves as the fallback answer for any name that
   is not staged, which is what lets models.c' load_model_file() and
   the sprite frame paths see fuzzer data. */
void MemFS_Clear(void);
void MemFS_Stage(const char *name, const byte *data, int len);

/* Hunk bookkeeping around one guarded loader call. expect_mapped is
   nonzero when the load completed and deliberately left its hunk
   mapped as the returned model (the harness resets it at the next
   iteration); on any error or rejection path the delta must be zero. */
int FuzzHunk_Begin(void);
void FuzzHunk_End(int before, const char *what, int expect_mapped);

/* Counters exported for the main() summary line. */
extern unsigned long fuzz_guard_hits;   /* ERR_DROP/FATAL recoveries */
extern unsigned long fuzz_hunk_orphans; /* unbalanced hunk deltas   */
extern unsigned long fuzz_image_hits;   /* successful load_image()  */
extern unsigned long fuzz_load_ok;      /* guarded call produced a
                                           buffer/model/hunk        */

/* Guard a loader call; returns 1 when re-entered through longjmp. */
#define FUZZ_GUARD_BEGIN()                        \
	do                                          \
	{                                           \
		int _fm_before = FuzzHunk_Begin();  \
		if (FuzzSetjmp() != 0)              \
		{                                   \
			fuzz_guard_hits++;          \
			FuzzHunk_End(_fm_before, __func__, 0); \
			return 0;                   \
		}

#define FUZZ_GUARD_END(what, left_model)              \
		FuzzHunk_End(_fm_before, what, left_model); \
	}                                           \
	while (0)

int FuzzSetjmp(void);

/* Fixed stub callbacks handed to the loaders. */
struct image_s *FuzzLoadImage(const char *name, byte *pic, int width,
	int realwidth, int height, int realheight, size_t data_size,
	imagetype_t type, int bits);
struct image_s *FuzzFindImage(const char *name, imagetype_t type);

/* One input, one load: targets copy the fuzzer bytes under the
   fixed staged names below. */
#define FUZZ_STAGED_NAMES \
	"probe.pcx", "probe.wal", "probe.m8", "probe.m32", \
	"probe.tga", "probe.png", "probe.jpg", \
	"pics/colormap.pcx", "probe", "probe.md2", "probe.md3", \
	"probe.sp2", "spr/probe.wal"

#endif /* FUZZ_COMMON_H */
