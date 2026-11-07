/*
 * Copyright (C) 1997-2001 Id Software, Inc.
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
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *
 * =======================================================================
 *
 * The PVS Decompress
 *
 * =======================================================================
 */

#include "../common/header/ref_shared.h"


/*
===================
Mod_DecompressVis
===================
*/
const byte *
Mod_DecompressVis(const byte *in, const byte *in_end, int row)
{
	YQ2_ALIGNAS_TYPE(int) static byte decompressed[MAX_MAP_LEAFS / 8];
	int c;
	byte *out;
	const byte *in_start;
	int budget;

	/* AE10: row is (vis->numclusters + 7) >> 3 from the map file
	   (Mod_ClusterPVS, src/mtl/mtl_model.m:41).  The Z5c guards in
	   Mod_LoadVisibility only check numclusters against the length
	   of the visibility lump, so a large enough lump carries
	   numclusters past MAX_MAP_LEAFS and the loop below writes past
	   decompressed[].  Reproduced on the real host with a crafted
	   base1.bsp (tools/fuzz/bspfuzz/craftpvs.py, cal_bigvis):
	   ASan global-buffer-overflow WRITE at decompressed + 8192;
	   with ship flags the same run instead silently clobbers the
	   dylib globals that sit after this static (nm layout: the
	   stbi__* pipeline flags, va.string, paged_total) with
	   attacker-chosen stream bytes.  In the fuzz harness the same
	   write lands at pvs.c:60.  A row bigger than the output
	   buffer can never be produced; treat it like missing vis:
	   make all visible. */
	if ((row <= 0) || (row > (int)sizeof(decompressed)))
	{
		c = 0;
		while (c < (int)sizeof(decompressed))
		{
			decompressed[c++] = 0xff;
		}

		return decompressed;
	}

	out = decompressed;

	if (!in)
	{
		/* no vis info, so make all visible */
		while (row)
		{
			*out++ = 0xff;
			row--;
		}

		return decompressed;
	}

	/* AE10: the loop below terminates on the decompressed byte count
	   alone, but a 00 00 run header writes zero bytes: a stream of
	   those (or any stream that cannot fill the row) advances the
	   input forever, past the end of the visibility lump.  Host
	   repro: cal_earlyterm in the same generator; in the fuzz
	   harness a heap-buffer-overflow READ at the in[1] fetch.  A
	   stream that can still produce output consumes at most two
	   input bytes per output byte (the 00 c header with c == 1), so
	   past that budget nothing can be decoded: stop and make the
	   rest visible, like the !in path.

	   AF3: the AE10 budget is not a bound against the input itself.
	   Z5c accepts bitofs == l->filelen and anything below it, and the
	   budget then allows bitofs + 2 * row to sit up to 2 * row bytes
	   past the END of the visibility image (the hunk allocation for
	   the lump is exactly l->filelen bytes, Mod_LoadVisibility, and
	   the unix hunk is an mmap whose mapping ends at the current
	   watermark plus 8 bytes, src/backends/hunk_unix.c).  Host repro
	   on crafted maps (tools/fuzz/bspfuzz/craftpvs.py, af3_neigh /
	   af3_guard): a bitofs parked at the lump end decompresses a
	   whole row from hunk bytes that follow the image - a decoded
	   PVS made up entirely of bytes outside the lump; on other
	   layouts (fuzz_pvs seeds, b_spkrow-class targets) the same walk
	   steps off the end of the mapping and faults.  in_end is one
	   past the last byte of the visibility image; a stream that
	   cannot finish the row inside the image must not read past it:
	   stop at the edge and make the rest visible, like the !in path.
	   The AE10 budget stays as the second limit - it also bounds the
	   cost of a hostile image, which clamping alone would not. */
	in_start = in;
	budget = 2 * row;

	do
	{
		/* AF3: the image edge and the AE10 budget, checked before
		   every read of the stream. */
		if ((in >= in_end) || (in - in_start > budget))
		{
			while (out - decompressed < row)
			{
				*out++ = 0xff;
			}

			break;
		}

		if (*in)
		{
			*out++ = *in++;
			continue;
		}

		/* AF3: the second header byte must be inside the image too;
		   a 00 as the very last byte of the lump has no count byte
		   to read, exactly the case that walks off the mapping end
		   pre-fix. */
		if ((in + 1) >= in_end)
		{
			in++;

			while (out - decompressed < row)
			{
				*out++ = 0xff;
			}

			break;
		}

		c = in[1];
		in += 2;

		/* AE11: the header writes c bytes blind, past the row end
		   this loop is bounded by: a header near the end of the
		   row writes up to 254 bytes too many (fuzz_pvs seed:
		   numclusters 65536 so row == sizeof(decompressed), 8191
		   literals, then 00 ff -> write at decompressed + 8192,
		   pvs.c:120).  Well-formed streams never straddle the row
		   end, so stopping the run at the boundary only cuts
		   hostile data. */
		while (c && ((out - decompressed) < row))
		{
			*out++ = 0;
			c--;
		}
	}
	while (out - decompressed < row);

	return decompressed;
}

float
Mod_RadiusFromBounds(const vec3_t mins, const vec3_t maxs)
{
	int i;
	vec3_t corner;

	for (i = 0; i < 3; i++)
	{
		corner[i] = fabs(mins[i]) > fabs(maxs[i]) ? fabs(mins[i]) : fabs(maxs[i]);
	}

	return VectorLength(corner);
}
