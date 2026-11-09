/*
 * AE1: libFuzzer target for the stb_image wrappers (src/files/stb.c)
 * and, through R_LoadImage(), the whole image pipeline that stb.c
 * drives: PCX, WAL/M8/M32 and TGA/PNG/JPG dispatch plus the
 * retexturing path.
 *
 * LoadSTB() is static inside stb.c; the engine-reachable way to the
 * vendored stb_image decode (stb_image.h / stb_image_resize.h, both
 * in-tree) is R_LoadImage() with the tga/png/jpg extensions.
 *
 * Entry points:
 *
 *   R_LoadImage()  extension dispatch, paletted PCX conversion
 *                  (colormap side-load), retextruing, all image
 *                  formats
 *   ResizeSTB()    stb_image_resize with input-derived dimensions
 */

#include "fuzz_common.h"

#include "../../src/common/header/stb_budget.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static const char *imgExts[] = { "pcx", "wal", "tga", "png", "jpg" };
	size_t	e;

	if (!data || (size == 0))
	{
		return 0;
	}

	MemFS_Clear();
	MemFS_Stage("probe.tga", data, (int)size);
	MemFS_Stage("probe.png", data, (int)size);
	MemFS_Stage("probe.jpg", data, (int)size);
	MemFS_Stage("probe.pcx", data, (int)size);
	MemFS_Stage("probe.wal", data, (int)size);
	MemFS_Stage("pics/colormap.pcx", data, (int)size);

	/* The full renderer-facing pipeline, with and without the
	   retextruing branch. */
	for (e = 0; e < sizeof(imgExts) / sizeof(imgExts[0]); e++)
	{
		FUZZ_GUARD_BEGIN();
		R_LoadImage("probe", "probe", imgExts[e], it_skin, qtrue,
				FuzzLoadImage);
		FUZZ_GUARD_END("R_LoadImage", 0);

		FUZZ_GUARD_BEGIN();
		R_LoadImage("probe", "probe", imgExts[e], it_wall, qfalse,
				FuzzLoadImage);
		FUZZ_GUARD_END("R_LoadImage", 0);
	}

	/* Resize path with dimensions derived from the input so the
	 * buffer geometry itself is input-controlled.  Needs two
	 * header bytes of its own: libFuzzer's minimiser drives the
	 * unit down to one byte and this block reads data[1] (AE2:
	 * that is a harness defect, not a loader one, so it is
	 * guarded here instead of rejecting the input outright). */
	if (size >= 2)
	{
		int iw = (int)((data[0] & 31) + 1);
		int ih = (int)((data[1] & 31) + 1);
		int ow = (int)((data[0] & 7) + 1);
		int oh = (int)((data[1] & 7) + 1);
		byte *inbuf = (byte *)malloc((size_t)iw * ih * 4);
		byte *outbuf = (byte *)malloc((size_t)ow * oh * 4);

		if (inbuf && outbuf)
		{
			memcpy(inbuf, data, size < ((size_t)iw * ih * 4) ?
					size : (size_t)iw * ih * 4);
			memset(outbuf, 0, (size_t)ow * oh * 4);
			ResizeSTB(inbuf, iw, ih, outbuf, ow, oh);
		}
		free(inbuf);
		free(outbuf);
	}

	MemFS_Clear();

	/* AL1 (round 29): budget-accounting invariant, loud.  The
	   stb_budget.h contract: every reserved canvas byte is either
	   committed (MTL_STBMarkImage - the harness stub releases
	   immediately, the stand-in slot dying with the call) or
	   released by stb.c itself before R_LoadImage returns.  So a
	   non-zero charge here is an accounting defect in stb.c on
	   THIS input, not harness noise: abort and report the input
	   instead of letting the run grind on with a full budget. */
	{
		long long charged = MTL_STBChargedBytes();

		if (charged != 0)
		{
			fprintf(stderr,
				"BUDGET_ACCOUNTING: MTL_STBChargedBytes() = %lld "
				"bytes after input of %zu byte(s); expected 0 "
				"(stb_budget.h: every claim is marked or "
				"released). This is a finding about src/files/"
				"stb.c: stop and report this input.\n",
				charged, size);
			fflush(stderr);
			abort();
		}
	}

	return 0;
}
