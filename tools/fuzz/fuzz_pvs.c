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
 * AE4/AE10: libFuzzer target for the renderer's PVS decompressor,
 * Mod_DecompressVis (src/files/pvs.c).
 *
 * It is reached from the BSP path through Mod_ClusterPVS
 * (src/mtl/mtl_model.m:41), which R_MarkLeaves calls per frame
 * (src/mtl/mtl_surf.m:947).  Neither function links into this
 * harness (mtl_model.m pulls in the renderer), so the target
 * synthesizes exactly the call Mod_ClusterPVS makes:
 *
 *     Mod_DecompressVis(vis + vis->bitofs[cluster][DVIS_PVS],
 *                       (const byte *)vis + vis->visLength,
 *                       (vis->numclusters + 7) >> 3);
 *
 * The input's first four bytes are numclusters (file byte order);
 * the rest is the bit stream.  The cluster table is not read by the
 * decompressor, so instead of materializing 8 bytes per cluster the
 * target only applies the two gates Mod_LoadVisibility enforces
 * (src/files/models.c, Z5c block): the table must fit the lump, and
 * bitofs must point inside it.  Both hold for the synthesized call
 * by construction: the stream sits at the end of a malloc'ed lump.
 *
 * AF3: the lump allocation has no slack tail any more.  Mod_Load-
 * Visibility hunk-allocates exactly l->filelen for the visibility
 * image (src/files/models.c), and the host's hunk is an mmap whose
 * mapping ENDS at the current watermark (src/backends/hunk_unix.c),
 * so the byte just past the image is the first byte the decompressor
 * is not allowed to touch.  The harness models that edge exactly:
 * lump end == allocation end, and any read past the image is a
 * heap-buffer-overflow READ.  A stream that cannot fill its row from
 * inside the lump must not read past the image at all.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The loader declares this in src/common/header/ref_shared.h; byte
 * is unsigned char there.  Declared locally, like the other
 * targets avoid pulling renderer headers into the harness. */
extern const unsigned char *Mod_DecompressVis(const unsigned char *in,
	const unsigned char *in_end, int row);

/* the largest numclusters a hostile map could put in a 1 MB lump
   (Z5c: 8 table bytes per cluster); keeps the harness allocation
   bounded */
#define MAX_CLUSTERS (200000)

/* AF3: no slack tail.  The visibility image in the host is exactly
   l->filelen bytes of hunk, and the hunk mapping ends at the
   watermark, so the harness lump ends at lump end.  Everything the
   decompressor may read is inside [lump, lump + lumplen). */

static int
le32(const uint8_t *p)
{
	return (int)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
			((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	int n, row, bitofs;
	size_t lumplen;
	uint8_t *lump;

	if (size < 4)
	{
		return 0;
	}

	n = le32(data);
	if ((n <= 0) || (n > MAX_CLUSTERS))
	{
		/* Z5c rejects negative counts; the cap is the harness's
		   own allocation bound */
		return 0;
	}

	/* the stream is everything after the four cluster words;
	   Z5c: 4 + 8n table bytes must fit the lump - true here by
	   construction since the stream sits past the virtual table */
	lumplen = (size_t)(4 + 8 * n) + (size - 4);
	bitofs = 4 + 8 * n; /* stream offset, inside the lump: Z5c ok */

	lump = malloc(lumplen);
	if (!lump)
	{
		return 0;
	}
	memset(lump, 0, (size_t)bitofs);
	memcpy(lump + bitofs, data + 4, size - 4);

	row = (n + 7) >> 3;
	Mod_DecompressVis(lump + bitofs, lump + lumplen, row);

	free(lump);
	return 0;
}
