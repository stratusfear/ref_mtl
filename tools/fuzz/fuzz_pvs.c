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
 *                       (vis->numclusters + 7) >> 3);
 *
 * The input's first four bytes are numclusters (file byte order);
 * the rest is the bit stream.  The cluster table is not read by the
 * decompressor, so instead of materializing 8 bytes per cluster the
 * target only applies the two gates Mod_LoadVisibility enforces
 * (src/files/models.c, Z5c block): the table must fit the lump, and
 * bitofs must point inside it.  Both hold for the synthesized call
 * by construction: the stream sits at the end of a malloc'ed lump,
 * so ASan sees the lump end exactly where a heap end would be in
 * the host test; a slack tail models the hunk bytes that follow a
 * real visibility lump, so a runaway stream must cross real
 * allocation bounds before it is reported.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The loader declares this in src/common/header/ref_shared.h; byte
 * is unsigned char there.  Declared locally, like the other
 * targets avoid pulling renderer headers into the harness. */
extern const unsigned char *Mod_DecompressVis(const unsigned char *in,
	int row);

/* the largest numclusters a hostile map could put in a 1 MB lump
   (Z5c: 8 table bytes per cluster); keeps the harness allocation
   bounded */
#define MAX_CLUSTERS (200000)

/* slack past the lump end, modelling the hunk allocation that a
   real visibility lump is embedded in.  After the AE10 bound the
   decompressor reads at most 2 * (MAX_MAP_LEAFS / 8) + 1 bytes
   past bitofs, and a real vis hunk block has that much arena
   behind the lump, so a post-fix read must stay inside this
   allocation; a pre-fix runaway crosses it and is reported. */
#define HUNK_SLACK (2 * (65536 / 8) + 64)

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

	lump = malloc(lumplen + HUNK_SLACK);
	if (!lump)
	{
		return 0;
	}
	memset(lump, 0, (size_t)bitofs);
	memcpy(lump + bitofs, data + 4, size - 4);
	memset(lump + lumplen, 0, HUNK_SLACK);

	row = (n + 7) >> 3;
	Mod_DecompressVis(lump + bitofs, row);

	free(lump);
	return 0;
}
