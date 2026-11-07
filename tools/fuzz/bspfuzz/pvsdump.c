/*
 * AF3: byte-identity driver for the PVS decompressor bound.
 *
 * Feeds the REAL visibility lumps of shipped maps through
 * Mod_DecompressVis (src/files/pvs.c) exactly as Mod_ClusterPVS
 * does, and prints an FNV-1a hash of every decoded row plus one
 * combined digest per map.  Run it over the same maps with the
 * pre-fix pvs.o (-DPRE_AVS build against a pre-fix pvs.c snapshot)
 * and the post-fix one and diff the outputs: identical digests mean
 * the bound changes nothing for data that stays inside the lump, and
 * a difference can only appear where the pre-fix decoder read past
 * the image.
 *
 * The harness mirrors the host allocation: the visibility image
 * starts at the front of the block and in_end is image start plus
 * l->filelen, exactly where the host's hunk image ends.  A zeroed
 * slack tail behind the image lets the PRE_AVS baseline complete
 * its walk instead of faulting (the af3_neigh class on the host);
 * whether the host walk faults or not is layout, and the craft-map
 * runs cover that side.  What this driver measures is the DATA:
 * digests equal for a map means the bound changed nothing there;
 * digests differing marks a map whose pre-fix stream crossed the
 * image end.  Maps whose lump fails the Z5c gates are reported and
 * skipped, exactly like the loader's ERR_DROP.
 *
 * Build (post-fix):
 *   clang -g -O1 -I../../src/mtl/header -c pvsdump.c -o obj-dump/pvsdump.o
 *   clang -o build/pvsdump obj-dump/pvsdump.o obj/pvs.o
 * Build (pre-fix baseline):
 *   same but with pvs.o compiled from the pre-fix source snapshot.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef PRE_AVS
/* pre-AF3 baseline (tools/fuzz/bspfuzz/pvsdump.c -DPRE_AVS against
   a pvs.o built from the pre-fix source): two-argument form, no
   image end - the whole point of the baseline run. */
extern const unsigned char *Mod_DecompressVis(const unsigned char *in,
	int row);
#else
extern const unsigned char *Mod_DecompressVis(const unsigned char *in,
	const unsigned char *in_end, int row);
#endif

#define LUMP_VISIBILITY 3

static int
le32(const uint8_t *p)
{
	return (int)(uint32_t)p[0] | ((uint32_t)p[1] << 8) |
		((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

int
main(int argc, char **argv)
{
	int i, nc, bad, row, hashrow;
	uint64_t fnv, digest;
	uint8_t *map, *visimg;
	long sz;
	FILE *f;
	const char *name;
	int *bitofs;

	if (argc < 2)
	{
		fprintf(stderr, "usage: %s map.bsp...\n", argv[0]);
		return 2;
	}

	for (i = 1; i < argc; i++)
	{
		name = argv[i];
		f = fopen(name, "rb");
		if (!f)
		{
			printf("PVSDROP %s cannot-open\n", name);
			continue;
		}
		fseek(f, 0, SEEK_END);
		sz = ftell(f);
		fseek(f, 0, SEEK_SET);
		map = malloc((size_t)sz);
		if (!map || fread(map, 1, (size_t)sz, f) != (size_t)sz)
		{
			printf("PVSDROP %s short-read\n", name);
			fclose(f);
			free(map);
			continue;
		}
		fclose(f);

		if ((sz < 8 + 19 * 8) || (le32(map) != 0x50534249)) /* "IBSP" */
		{
			printf("PVSDROP %s not-a-bsp\n", name);
			free(map);
			continue;
		}

		{
			int vofs = le32(map + 8 + LUMP_VISIBILITY * 8);
			int vlen = le32(map + 8 + LUMP_VISIBILITY * 8 + 4);

			if ((vlen <= 0) || (vofs < 0) ||
				((long long)vofs + vlen > sz))
			{
				printf("PVSDROP %s empty-or-bad-vis-lump len=%d\n",
					name, vlen);
				free(map);
				continue;
			}

			nc = le32(map + vofs);
			/* Z5c gate 1: the cluster table must fit the lump */
			if ((nc < 0) ||
			(4 + (long long)nc * 8 > vlen))
			{
				printf("PVSDROP %s table-does-not-fit nc=%d "
					"len=%d\n", name, nc, vlen);
				free(map);
				continue;
			}

			/* image exactly filelen bytes for the decoder's
			   benefit, plus a zeroed slack tail so the PRE_AVS
			   baseline can COMPLETE: a pre-fix walk past the
			   image end reads those bytes instead of faulting,
			   which is the "lands on mapped hunk bytes" class
			   (af3_neigh on the host).  The digest difference,
			   if any, is the decoder's, not the allocator's:
			   the POST decoder never touches the slack. */
			visimg = malloc((size_t)vlen + (2 * 8192 + 64));
			if (!visimg)
			{
				printf("PVSDROP %s oom\n", name);
				free(map);
				continue;
			}
			memcpy(visimg, map + vofs, (size_t)vlen);
			memset(visimg + vlen, 0, (2 * 8192 + 64));
			bitofs = malloc((size_t)nc * sizeof(int));
			if (!bitofs)
			{
				printf("PVSDROP %s oom\n", name);
				free(visimg);
				free(map);
				continue;
			}

			bad = 0;
			for (int c = 0; c < nc; c++)
			{
				bitofs[c] = le32(visimg + 4 + c * 8); /* DVIS_PVS */
				/* Z5c gate 2: bitofs inside the lump */
				if ((bitofs[c] < 0) || (bitofs[c] > vlen))
				{
					printf("PVSDROP %s bitofs-outside c=%d "
						"ofs=%d len=%d\n", name, c,
						bitofs[c], vlen);
					bad = 1;
					break;
				}
			}

			if (!bad)
			{
				digest = 0xcbf29ce484222325ULL;
				row = (nc + 7) >> 3;
				/* the decompressor's fail-open guard (row bigger
				   than the output buffer) returns a buffer of
				   MAX_MAP_LEAFS/8 = 8192 bytes; hash that extent
				   only, both builds alike */
				hashrow = row > 8192 ? 8192 : row;
				for (int c = 0; c < nc; c++)
				{
					const uint8_t *r;
					int k;

#ifdef PRE_AVS
					r = Mod_DecompressVis(visimg + bitofs[c], row);
#else
					r = Mod_DecompressVis(visimg + bitofs[c],
						visimg + vlen, row);
#endif
					fnv = 0xcbf29ce484222325ULL;
					for (k = 0; k < hashrow; k++)
					{
						fnv = (fnv ^ r[k]) * 0x100000001b3ULL;
					}
					printf("PVSHASH %s c=%d b=%d h=%016llx\n",
						name, c, bitofs[c],
						(unsigned long long)fnv);
					digest = (digest ^ fnv) * 0x100000001b3ULL;
				}
				printf("PVSDIGEST %s nc=%d row=%d digest=%016llx\n",
					name, nc, row, (unsigned long long)digest);
			}

			free(bitofs);
			free(visimg);
		}
		free(map);
	}

	return 0;
}
