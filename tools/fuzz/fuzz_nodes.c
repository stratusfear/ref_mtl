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
 * AG2: libFuzzer target for the renderer's node-tree loader,
 * Mod_LoadNodes (src/files/models.c).
 *
 * This is the AG2 measurement harness: Mod_LoadNodes is the point where
 * a BSP's node tree becomes the renderer's mnode_t graph, and at its
 * tail it runs the two recursive walks the round-24 brief (AG2) asks
 * about - Mod_SetParent (models.c:2035) and Mod_NumberLeafs
 * (models.c:2053).  Neither has a depth bound or a visited mark, and
 * Mod_LoadNodes itself only checks that every child index is inside the
 * node/leaf arrays (models.c:2163-2183).
 *
 * The BSP path as a whole does not link into any fuzz target (the
 * renderer's Mod_LoadBrushModel lives in src/mtl/mtl_model.m, which
 * pulls in the Metal context), so the harness calls Mod_LoadNodes the
 * way that caller does, with the arrays it already has: a planes array,
 * a leafs array, and the nodes lump.  Input layout:
 *
 *   bytes 0..3    numplanes    (LE)
 *   bytes 4..7    numleafs     (LE)
 *   bytes 8..11   numsurfaces  (LE)   - the AG1 surface-array count
 *   bytes 12..    the nodes lump, verbatim (dnode_t records, 28 bytes)
 *
 * The caps are harness bounds, not loader rules: they only keep one
 * iteration's allocation reasonable.  numleafs is capped a little ABOVE
 * MAX_MAP_LEAFS (65536) on purpose, because that is the constant the
 * loader's two stack arrays in Mod_LoadNodes are sized with; the
 * interesting region is just past it.  Every leaf's contents is left 0,
 * i.e. every leaf is a vis leaf, which is the worst case for
 * r_vistoleaf[] in Mod_NumberLeafs.
 */

#include "fuzz_common.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PLANES_LIMIT 66000
#define MAX_LEAFS_LIMIT  66000
/* AG2: the lump cap is deliberately large.  The exponential shape needs
   only a handful of records, but the "chain of nodes" shape the brief
   mentions is only interesting at a size a real (hostile) BSP can have:
   a 28 MB nodes lump is ~10^6 dnode_t records, which is what it takes to
   see what the recursive walks pay.  libFuzzer's own input cap stays at
   fuzz_nodes_MAXLEN in the Makefile; the cap here only bounds one
   iteration's allocation. */
#define MAX_LUMP         (28 << 20)

static int
le32(const uint8_t *p)
{
	return (int)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
			((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	int numplanes, numleafs, numsurfaces;
	size_t lumplen;
	uint8_t *lump;
	cplane_t *planes;
	mleaf_t *leafs;
	mnode_t *nodes = NULL;
	int numnodes = 0;
	lump_t l;

	if (size < 12)
	{
		return 0;
	}

	numplanes = le32(data);
	numleafs = le32(data + 4);
	numsurfaces = le32(data + 8);
	lumplen = size - 12;

	if ((numplanes < 0) || (numplanes > MAX_PLANES_LIMIT))
	{
		return 0;
	}
	if ((numleafs < 0) || (numleafs > MAX_LEAFS_LIMIT))
	{
		return 0;
	}
	if ((numsurfaces < 0) || (lumplen > MAX_LUMP))
	{
		return 0;
	}

	lump = malloc(lumplen ? lumplen : 1);
	planes = calloc((size_t)(numplanes ? numplanes : 1), sizeof(cplane_t));
	leafs = calloc((size_t)(numleafs ? numleafs : 1), sizeof(mleaf_t));
	if (!lump || !planes || !leafs)
	{
		free(lump);
		free(planes);
		free(leafs);
		return 0;
	}
	memcpy(lump, data + 12, lumplen);

	/* AG2: leaf 0 is the solid content filler of a real BSP leafs lump
	   (CONTENTS_SOLID), and the loader treats solid leaves as freely
	   shared.  Everything above leaf 0 keeps contents 0, i.e. a vis leaf,
	   which is the worst case for the leaf numbering. */
	if (numleafs > 0)
	{
		leafs[0].contents = CONTENTS_SOLID;
	}

	l.fileofs = 0;
	l.filelen = (int)lumplen;

	/* The real caller (mtl_model.m:1312) owns the model hunk and sizes it
	   from the lump table, so a rejection path in Mod_LoadNodes leaves the
	   mapping owned by the caller, not by Mod_LoadNodes.  The guard macros
	   in fuzz_common.h assume the loader owns its hunk (the alias-model
	   loaders do), so this target drives the same helpers directly and
	   tells FuzzHunk_End that one mapping is expected to survive either
	   way - otherwise every ERR_DROP would read as an AC1 orphan. */
	{
		volatile int before = FuzzHunk_Begin();

		FuzzGuardArm();
		if (setjmp(fuzz_abort) != 0)
		{
			fuzz_guard_hits++;
			FuzzHunk_End(before, "Mod_LoadNodes", 1);
			free(lump);
			free(planes);
			free(leafs);
			return 0;
		}

		/* room for the nodes output (count * sizeof(mnode_t)) plus the
		   slack the real caller's lump sums would add */
		(void)Hunk_Begin((int)(lumplen / sizeof(dnode_t)) *
				(int)sizeof(mnode_t) + (1 << 20));

		Mod_LoadNodes("probe", planes, numplanes, leafs, numleafs,
				numsurfaces, &nodes, &numnodes, lump, &l);
		fuzz_load_ok++;
		FuzzHunk_End(before, "Mod_LoadNodes", 1);
	}

	free(lump);
	free(planes);
	free(leafs);
	return 0;
}
