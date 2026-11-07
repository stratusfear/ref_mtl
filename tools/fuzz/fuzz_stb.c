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
	return 0;
}
