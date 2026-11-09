/*
 * Copyright (C) 1997-2001 Id Software, Inc.
 * Copyright (C) 2015 Daniel Gibson
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
 * File formats supported by stb_image, for now only tga, png, jpg
 * See also https://github.com/nothings/stb
 *
 * =======================================================================
 */

#include <stdlib.h>

#include "../common/header/ref_shared.h"
#include "../common/header/stb_budget.h"

/* AJ1 (round 27): the aggregate stb decode budget.  The per-file caps
   above LoadSTB bound ONE canvas (max 64 MB RGBA); round-26 AI3
   measured what N within-cap canvases cost together: 128 staged
   4096x4096 loads over base1's texture names reached 11.3 GB resident
   and 14.9 s to the first frame on a 64 GB host.  This TU owns the
   counter of canvas bytes currently claimed by successful stb loads;
   the effective budget (cvar clamped by a device query) lives in
   mtl_main.m and the slot binding/free sites in mtl_image.m - see
   stb_budget.h for the crossing points and invariants. */

/* charged: bytes currently claimed.  A successful LoadSTB adds its
   canvas to the claim; the claim is released either by the caller
   (load callback returned NULL or was not reached) or, after
   MTL_STBMarkImage binds it to an image slot, by the Metal free
   sites.  refusals/print counters are per registration level, reset
   by MTL_STBLevelBoundary (mtl_model.m calls it at each new map);
   print bound keeps a hostile 2000-texinfo map from flooding the
   console - measured before choosing the cap: N=128 refusals print
   one line each, and mkbsp's synthetic 2000-name map was the case
   that needed the suppression line. */
static long long stb_charged_bytes;
static int stb_level_refusals;
static long long stb_level_refused_bytes;
static int stb_level_printed;
#define STB_BUDGET_REFUSAL_PRINT_MAX 8

/* stb.c's side of the bridge; called by the Metal TU (stb_budget.h). */
void
MTL_STBReleaseBytes(long long bytes)
{
	if (bytes <= 0)
	{
		return;
	}

	stb_charged_bytes -= bytes;
	if (stb_charged_bytes < 0)
	{
		/* Accounting bug, not hostile input: something released a
		   claim that was never made (or made twice).  State it and
		   re-zero so the budget keeps working. */
		Com_Printf("LoadSTB: budget accounting error: released %lld MB, "
				"charged was %lld MB; re-zeroed\n",
				bytes / (1024 * 1024),
				(stb_charged_bytes + bytes) / (1024 * 1024));
		stb_charged_bytes = 0;
	}
}

long long
MTL_STBChargedBytes(void)
{
	return stb_charged_bytes;
}

/* Called by mtl_model.m at RE_BeginRegistration: one per-level summary
   of what the budget refused, and reset of the per-level print
   allowance. */
void
MTL_STBLevelBoundary(void)
{
	if (stb_level_refusals > 0)
	{
		Com_Printf("LoadSTB: %d image decode(s) refused by the stb "
				"budget this level (%lld MB canvas); %lld MB of "
				"%lld MB charged; raise r_stb_budget, ceiling "
				"%lld MB\n",
				stb_level_refusals,
				stb_level_refused_bytes / (1024 * 1024),
				stb_charged_bytes / (1024 * 1024),
				MTL_STBEffectiveBudgetBytes() / (1024 * 1024),
				MTL_STBBudgetCeilingBytes() / (1024 * 1024));
	}

	stb_level_refusals = 0;
	stb_level_refused_bytes = 0;
	stb_level_printed = 0;
}

/* Admit-or-refuse for one canvas.  Claimed up front (header known:
   before stb allocates; header unknown: after decode, see LoadSTB).
   Returns true and adds canvas_bytes to the claim when the budget
   fits it; otherwise counts a refusal and prints at most
   STB_BUDGET_REFUSAL_PRINT_MAX lines for the current level. */
static qboolean
STBBudgetReserve(long long canvas_bytes, const char *filename)
{
	long long budget = MTL_STBEffectiveBudgetBytes();

	if (canvas_bytes > 0 && stb_charged_bytes + canvas_bytes <= budget)
	{
		stb_charged_bytes += canvas_bytes;
		return true;
	}

	stb_level_refusals++;
	stb_level_refused_bytes += (canvas_bytes > 0 ? canvas_bytes : 0);
	if (stb_level_printed < STB_BUDGET_REFUSAL_PRINT_MAX)
	{
		/* AK3/AK4 (round 28): literal "LoadSTB:" (this file's
		   user-visible prefix; STBBudgetReserve is internal) and
		   the cvar + ceiling named where a pack author needs
		   them. */
		Com_Printf("LoadSTB: refusing to decode %s: %lld MB canvas "
				"does not fit the stb budget (%lld MB of %lld MB "
				"charged; raise r_stb_budget, ceiling %lld MB)\n",
				filename,
				canvas_bytes / (1024 * 1024),
				stb_charged_bytes / (1024 * 1024),
				budget / (1024 * 1024),
				MTL_STBBudgetCeilingBytes() / (1024 * 1024));
		stb_level_printed++;
		if (stb_level_printed == STB_BUDGET_REFUSAL_PRINT_MAX)
		{
			Com_Printf("LoadSTB: further budget refusals "
					"suppressed until the next level; raise "
					"r_stb_budget (ceiling %lld MB)\n",
					MTL_STBBudgetCeilingBytes() / (1024 * 1024));
		}
	}
	return false;
}

// don't need HDR stuff
#define STBI_NO_LINEAR
#define STBI_NO_HDR
// make sure STB_image uses standard malloc(), as we'll use standard free() to deallocate
#define STBI_MALLOC(sz)    malloc(sz)
#define STBI_REALLOC(p,sz) realloc(p,sz)
#define STBI_FREE(p)       free(p)
// Switch of the thread local stuff. Breaks mingw under Windows.
#define STBI_NO_THREAD_LOCALS
// include implementation part of stb_image into this file
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

// include resize implementation
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize.h"

/*
 * Add extension to file name
 */
void
FixFileExt(const char *origname, const char *ext, char *filename, size_t size)
{
	Q_strlcpy(filename, origname, size);

	/* Add the extension */
	if (strcmp(COM_FileExtension(filename), ext))
	{
		Q_strlcat(filename, ".", size);
		Q_strlcat(filename, ext, size);
	}
}

/*
 * origname: the filename to be opened, might be without extension
 * type: extension of the type we wanna open ("jpg", "png" or "tga")
 * pic: pointer RGBA pixel data will be assigned to
 * claimed: AJ1, out: the budget bytes reserved for this canvas on
 *   the caller's behalf when this returns true; exactly
 *   width*height*4.  The caller must pass the result to
 *   MTL_STBMarkImage (load callback returned an image) or to
 *   MTL_STBReleaseBytes (it did not).
 */
static qboolean
LoadSTB(const char *origname, const char* type, byte **pic, int *width, int *height,
	long long *claimed)
{
	char filename[256];

	FixFileExt(origname, type, filename, sizeof(filename));

	*pic = NULL;
	*claimed = 0;

	byte* rawdata = NULL;
	int rawsize = ri.FS_LoadFile(filename, (void **)&rawdata);
	if (rawdata == NULL)
	{
		return false;
	}

	/* AH1: bound the decode BEFORE stb allocates its canvas.  A
	   34-byte file (the fuzz_stb timeout artifact, sha1 35106c89..)
	   claims a 27164 x 26480 8bpp RLE TGA = 719302720 pixels.  What
	   that costs was measured on the release host with this file
	   staged as base1's e1u1/metal2_1 loose texture (loose beats
	   paks, r_retexturing 1): peak RSS 922 MB against a 238 MB
	   baseline, and the first r_speeds frame slipped from 1.05 s to
	   3.09 s; the console got one line, "LoadSTB couldn't load data
	   from ...: outofmem!" - stb allocated the 719 MB 8-bit canvas,
	   ground the RLE fill from a 34-byte payload, then failed the
	   2877210880-byte RGBA postprocess on its own size guard and the
	   surface fell back to the shipped .wal (AI4 correction: an
	   earlier form of this comment said "fell back to notexture" -
	   that was never shown; with a temporary GOTIMAGE probe on the
	   same staged file, the loader's .wal fallback IS what loads,
	   and notexture is not involved).  So the host pays a ~684 MB transient
	   allocation and ~2 s per such texture; in the fuzz_stb harness
	   (twelve loads per iteration, ASan/UBSan in the way) the same
	   input never finished inside a 30 s session timeout.  The same
	   shape is what rounds 22/23 carried as "TGA bomb, report-only"
	   and what mkseedcorpus.py quarantined by sha1 (374d2471..) -
	   round 26 re-checked that entry; the two correction
	   paragraphs at the end of this block say what came of it.
	   The caps: 16384 per side, exactly MTL_MAX_TEXTURE_DIM in
	   mtl_image.m - anything past that is already rejected to
	   notexture by Z2 AFTER the full decode, so decoding it is pure
	   waste; and 16777216 pixels (= 4096^2, 64 MB RGBA canvas).  The
	   product bound is tighter than Z2's post-decode product bound
	   (16384^2) on purpose: the side cap alone still lets a 34-byte
	   claim of 16384 x 16384 burn a 1 GB canvas for minutes.  Head-
	   room data: scan_img.py's census over the same 10 paks and the
	   loose trees - 2459 image files, max side 1024, max pixel
	   count 524288, no .png/.jpg at all - so 4096^2 is 32x the
	   largest shipped claim.  The worst canvas a small file can now
	   force is 64 MB, and every file that decoded and loaded before
	   still decodes: shipped claims sit under the cap by 32x.  A
	   sibling shape is already caught one layer down - a PNG with
	   the same claim fails stb's own allocation guard
	   ((1<<30)/x/n < y, stb_image.h:5158, "too large") - asserted
	   that way in the hostile suite so the line stays honest either
	   way.  stbi_info_from_memory() parses only the header; if it
	   fails, fall through to the normal load so its failure reason
	   stays the console evidence for non-header files.

	   The same shape is what rounds 22/23 carried as "TGA bomb,
	   report-only" and what mkseedcorpus.py quarantined by sha1
	   (374d2471.., a 63-byte unit).  Two visible corrections from
	   round 26 re-checking that entry: (1) its header parses as
	   20920 x 65279 (an earlier form of this comment said "34532 x
	   20920" - that is the yOrigin field and the width, not the
	   claimed canvas); (2) "that file was NOT found in any corpus
	   source" was wrong - it is on disk at tools/fuzz/crashers/,
	   file name = its own sha1, 63 bytes.  What the scan really
	   showed is narrower and still true: no such image exists in
	   the 10 app paks or any loose image under the app datadir
	   (max shipped side 1024), so those bytes were never live game
	   content.  The quarantine entry is retired below and the cap
	   rejects the shape either way; measured natively (clang -O2,
	   no sanitizers, round 26 AI3) that unit spends ~5.7 s inside
	   stb on a ~1.37 GB 8-bit canvas before stb's own guard fails
	   the RGBA postprocess ("outofmem").

	   AI4: the caps get names so the refusal line can state them -
	   a pack author who sees "claiming 8192x4096" should not have
	   to read this source to learn the limit.  The check and the
	   message below both use these two constants; the numbers
	   appear nowhere else.  The side cap is the same value as
	   MTL_MAX_TEXTURE_DIM (src/mtl/header/mtl.h, used by
	   mtl_image.m's post-decode reject), repeated here because
	   mtl.h is the Metal TU's header and does not include into a
	   plain C file.  Aggregate cost note from the same round-26
	   AI3 measurement: the cap bounds each texture, not the sum -
	   128 within-cap 4096x4096 claims staged over base1's texture
	   names cost 14.9 s to the first frame and 11.3 GB resident on
	   the 64 GB host (1024x512 controls: 1.03 s, 527 MB); a per-
	   session decoded-pixel budget is the standing recommendation,
	   not implemented.  Visible correction (AJ1, round 27): that
	   last clause is now stale - the aggregate budget IS
	   implemented; see the counter above LoadSTB, the admit checks
	   below, and r_stb_budget in mtl_main.m. */
#define LOADSTB_MAX_TEXTURE_DIM 16384
#define LOADSTB_MAX_TEXTURE_PX  16777216LL
	long long claim = 0;
	{
		int aw, ah, ac;

		if (stbi_info_from_memory(rawdata, rawsize, &aw, &ah, &ac))
		{
			long long px = (long long)aw * ah;

			if (aw > LOADSTB_MAX_TEXTURE_DIM ||
				ah > LOADSTB_MAX_TEXTURE_DIM ||
				px > LOADSTB_MAX_TEXTURE_PX)
			{
				Com_Printf("%s: refusing to decode %s claiming "
						"%dx%d (%lld pixels; limit %d "
						"per side, %lld pixels)\n",
						__func__, filename, aw, ah, px,
						LOADSTB_MAX_TEXTURE_DIM,
						LOADSTB_MAX_TEXTURE_PX);
				ri.FS_FreeFile(rawdata);
				return false;
			}

			/* AJ1: header parsed - the canvas size is known, so
			   reserve it BEFORE stb allocates: this is the order
			   that actually protects against the aggregate cost.
			   stbi returns exactly the header dims for the tga/
			   png/jpg formats this reaches, so the claim below is
			   the canvas; if a format ever disagreed the claim
			   still bounds the charge (release uses the claim,
			   never the real size). */
			claim = px * 4;
			if (!STBBudgetReserve(claim, filename))
			{
				ri.FS_FreeFile(rawdata);
				return false;
			}
		}
	}

	int w, h, bytesPerPixel;
	byte* data = NULL;
	data = stbi_load_from_memory(rawdata, rawsize, &w, &h, &bytesPerPixel, STBI_rgb_alpha);
	if (data == NULL)
	{
		if (claim)
		{
			MTL_STBReleaseBytes(claim);
		}
		Com_Printf("%s couldn't load data from %s: %s!\n", __func__, filename, stbi_failure_reason());
		ri.FS_FreeFile(rawdata);
		return false;
	}

	ri.FS_FreeFile(rawdata);

	if (claim == 0)
	{
		/* AJ1: stbi_info failed to parse the header but the decode
		   succeeded, so the real canvas size is first knowable
		   HERE - after stb has already allocated it.  Weaker
		   protection (the transient allocation happened) but still
		   correct accounting: the sum of surviving canvases stays
		   bounded, and an over-budget canvas never reaches an
		   image slot. */
		claim = (long long)w * h * 4;
		if (!STBBudgetReserve(claim, filename))
		{
			free(data);
			return false;
		}
	}

	Com_DPrintf("%s() loaded: %s\n", __func__, filename);

	*pic = data;
	*width = w;
	*height = h;
	*claimed = claim;
	return true;
}

qboolean
ResizeSTB(const byte *input_pixels, int input_width, int input_height,
			  byte *output_pixels, int output_width, int output_height)
{
	if (stbir_resize_uint8(input_pixels, input_width, input_height, 0,
			       output_pixels, output_width, output_height, 0, 4))
		return true;
	return false;
}

// We have 16 color palette, 256 / 16 should be enough
#define COLOR_DISTANCE 16

void
SmoothColorImage(unsigned *dst, size_t size, size_t rstep)
{
	unsigned *full_size;
	unsigned last_color;
	unsigned *last_diff;

	// maximum step for apply
	if (rstep < 2)
	{
		return;
	}

	// step one pixel back as with check one pixel more
	full_size = dst + size - rstep - 1;
	last_diff = dst;
	last_color = *dst;

	// skip current point
	dst ++;

	while (dst < full_size)
	{
		if (last_color != *dst)
		{
			int step = dst - last_diff;
			if (step > 1)
			{
				int a_beg, b_beg, c_beg, d_beg;
				int a_end, b_end, c_end, d_end;
				int a_step, b_step, c_step, d_step;
				int k;

				// minimize effect size to rstep
				if (step > rstep)
				{
					// change place for start effect
					last_diff += (step - rstep);
					step = rstep;
				}

				// compare next pixels
				for(k = 1; k <= step; k ++)
				{
					if (dst[k] != dst[0])
					{
						break;
					}
				}

				// step back as pixel different after previous step
				k --;

				// mirror steps
				if (k < step)
				{
					// Com_Printf("%s %d -> %d\n", __func__, k, step);
					// change place for start effect
					last_diff += (step - k);
					step = k;
				}

				// update step to correct value
				step += k;
				dst += k;

				// get colors
				a_beg = (last_color >> 0 ) & 0xff;
				b_beg = (last_color >> 8 ) & 0xff;
				c_beg = (last_color >> 16) & 0xff;
				d_beg = (last_color >> 24) & 0xff;

				a_end = (*dst >> 0 ) & 0xff;
				b_end = (*dst >> 8 ) & 0xff;
				c_end = (*dst >> 16) & 0xff;
				d_end = (*dst >> 24) & 0xff;

				a_step = a_end - a_beg;
				b_step = b_end - b_beg;
				c_step = c_end - c_beg;
				d_step = d_end - d_beg;

				if ((abs(a_step) <= COLOR_DISTANCE) &&
				    (abs(b_step) <= COLOR_DISTANCE) &&
				    (abs(c_step) <= COLOR_DISTANCE) &&
				    (abs(d_step) <= COLOR_DISTANCE) &&
				    step > 0)
				{
					// generate color change steps
					a_step = (a_step << 16) / step;
					b_step = (b_step << 16) / step;
					c_step = (c_step << 16) / step;
					d_step = (d_step << 16) / step;

					// apply color changes
					for (k=0; k < step; k++)
					{
						*last_diff = (((a_beg + ((a_step * k) >> 16)) << 0) & 0x000000ff) |
									 (((b_beg + ((b_step * k) >> 16)) << 8) & 0x0000ff00) |
									 (((c_beg + ((c_step * k) >> 16)) << 16) & 0x00ff0000) |
									 (((d_beg + ((d_step * k) >> 16)) << 24) & 0xff000000);
						last_diff++;
					}
				}
			}
			last_color = *dst;
			last_diff = dst;
		}
		dst ++;
	}
}

/* https://en.wikipedia.org/wiki/Pixel-art_scaling_algorithms */

void
scale2x(const byte *src, byte *dst, int width, int height)
{
	/*
		EPX/Scale2×/AdvMAME2×

		x A x
		C P B -> 1 2
		x D x    3 4

		1=P; 2=P; 3=P; 4=P;
		IF C==A AND C!=D AND A!=B => 1=A
		IF A==B AND A!=C AND B!=D => 2=B
		IF D==C AND D!=B AND C!=A => 3=C
		IF B==D AND B!=A AND D!=C => 4=D
	*/
	{
		const byte *in_buff = src;
		byte *out_buff = dst;
		byte *out_buff_full = dst + ((width * height) << 2);
		while (out_buff < out_buff_full)
		{
			int x;
			for (x = 0; x < width; x ++)
			{
				// copy one source byte to two destinatuion bytes
				*out_buff = *in_buff;
				out_buff ++;
				*out_buff = *in_buff;
				out_buff ++;

				// next source pixel
				in_buff ++;
			}
			// copy last line one more time
			memcpy(out_buff, out_buff - (width << 1), width << 1);
			out_buff += width << 1;
		}
	}

	{
		int y, h, w;
		h = height - 1;
		w = width - 1;
		for (y = 0; y < height; y ++)
		{
			int x;
			for (x = 0; x < width; x ++)
			{
				byte a, b, c, d, p;

				p = src[(width * (y    )) + (x    )];
				a = (y > 0) ? src[(width * (y - 1)) + (x    )] : p;
				b = (x < w) ? src[(width * (y    )) + (x + 1)] : p;
				c = (x > 0) ? src[(width * (y    )) + (x - 1)] : p;
				d = (y < h) ? src[(width * (y + 1)) + (x    )] : p;

				if ((c == a) && (c != d) && (a != b))
				{
					dst[(2 * width * ((y * 2)    )) + ((x * 2)    )] = a;
				}

				if ((a == b) && (a != c) && (b != d))
				{
					dst[(2 * width * ((y * 2)    )) + ((x * 2) + 1)] = b;
				}

				if ((d == c) && (d != b) && (c != a))
				{
					dst[(2 * width * ((y * 2) + 1)) + ((x * 2)    )] = c;
				}

				if ((b == d) && (b != a) && (d != c))
				{
					dst[(2 * width * ((y * 2) + 1)) + ((x * 2) + 1)] = d;
				}
			}
		}
	}
}

void
scale3x(const byte *src, byte *dst, int width, int height)
{
	/*
		Scale3×/AdvMAME3× and ScaleFX

		A B C    1 2 3
		D E F -> 4 5 6
		G H I    7 8 9


		1=E; 2=E; 3=E; 4=E; 5=E; 6=E; 7=E; 8=E; 9=E;
		IF D==B AND D!=H AND B!=F => 1=D
		IF (D==B AND D!=H AND B!=F AND E!=C) OR (B==F AND B!=D AND F!=H AND E!=A) => 2=B
		IF B==F AND B!=D AND F!=H => 3=F
		IF (H==D AND H!=F AND D!=B AND E!=A) OR (D==B AND D!=H AND B!=F AND E!=G) => 4=D
		5=E
		IF (B==F AND B!=D AND F!=H AND E!=I) OR (F==H AND F!=B AND H!=D AND E!=C) => 6=F
		IF H==D AND H!=F AND D!=B => 7=D
		IF (F==H AND F!=B AND H!=D AND E!=G) OR (H==D AND H!=F AND D!=B AND E!=I) => 8=H
		IF F==H AND F!=B AND H!=D => 9=F
	*/
	{
		const byte *in_buff = src;
		byte *out_buff = dst;
		byte *out_buff_full = dst + ((width * height) * 9);
		while (out_buff < out_buff_full)
		{
			int x;
			for (x = 0; x < width; x ++)
			{
				// copy one source byte to two destinatuion bytes
				*out_buff = *in_buff;
				out_buff ++;
				*out_buff = *in_buff;
				out_buff ++;
				*out_buff = *in_buff;
				out_buff ++;

				// next source pixel
				in_buff ++;
			}
			// copy last line one more time
			memcpy(out_buff, out_buff - (width * 3), width * 3);
			out_buff += width * 3;
			// copy last line one more time
			memcpy(out_buff, out_buff - (width * 3), width * 3);
			out_buff += width * 3;
		}
	}

	{
		int y, z, w;
		z = height - 1;
		w = width - 1;
		for (y = 0; y < height; y ++)
		{
			int x;
			for (x = 0; x < width; x ++)
			{
				byte a, b, c, d, e, f, g, h, i;

				e = src[(width * y) + x];

				a = ((y > 0) && (x > 0)) ? src[(width * (y - 1)) + (x - 1)] : e;
				b = ((y > 0) && (x    )) ? src[(width * (y - 1)) + (x    )] : e;
				c = ((y > 0) && (x < w)) ? src[(width * (y - 1)) + (x + 1)] : e;

				d = (           (x > 0)) ? src[(width * (y    )) + (x - 1)] : e;
				f = (           (x < w)) ? src[(width * (y    )) + (x + 1)] : e;

				g = ((y < z) && (x > 0)) ? src[(width * (y + 1)) + (x - 1)] : e;
				h = ((y < z) && (x    )) ? src[(width * (y + 1)) + (x    )] : e;
				i = ((y < z) && (x < w)) ? src[(width * (y + 1)) + (x + 1)] : e;

				if ((d == b) && (d != h) && (b != f))
				{
					dst[(3 * width * ((y * 3)    )) + ((x * 3)    )] = d;
				}

				if (((d == b) && (d != h) && (b != f) && (e != c)) ||
					((b == f) && (b != d) && (f != h) && (e != a)))
				{
					dst[(3 * width * ((y * 3)    )) + ((x * 3) + 1)] = b;
				}

				if ((b == f) && (b != d) && (f != h))
				{
					dst[(3 * width * ((y * 3)    )) + ((x * 3) + 2)] = f;
				}

				if (((h == d) && (h != f) && (d != b) && (e != a)) ||
					((d == b) && (d != h) && (b != f) && (e != g)))
				{
					dst[(3 * width * ((y * 3) + 1)) + ((x * 3)    )] = d;
				}

				if (((b == f) && (b != d) && (f != h) && (e != i)) ||
					((f == h) && (f != b) && (h != d) && (e != c)))
				{
					dst[(3 * width * ((y * 3) + 1)) + ((x * 3) + 2)] = f;
				}

				if ((h == d) && (h != f) && (d != b))
				{
					dst[(3 * width * ((y * 3) + 2)) + ((x * 3)    )] = d;
				}

				if (((f == h) && (f != b) && (h != d) && (e != g)) ||
					((h == d) && (h != f) && (d != b) && (e != i)))
				{
					dst[(3 * width * ((y * 3) + 2)) + ((x * 3) + 1)] = h;
				}

				if ((f == h) && (f != b) && (h != d))
				{
					dst[(3 * width * ((y * 3) + 2)) + ((x * 3) + 2)] = f;
				}
			}
		}
	}
}

static struct image_s *
LoadHiColorImage(const char *name, const char* namewe, const char *ext,
	imagetype_t type, loadimage_t load_image)
{
	int realwidth = 0, realheight = 0;
	int width = 0, height = 0;
	struct image_s	*image = NULL;
	byte *pic = NULL;
	long long claim = 0;

	/* Get size of the original texture */
	if (strcmp(ext, "pcx") == 0)
	{
		GetPCXInfo(name, &realwidth, &realheight);
	}
	else if (strcmp(ext, "wal") == 0)
	{
		GetWalInfo(name, &realwidth, &realheight);
	}
	else if (strcmp(ext, "m8") == 0)
	{
		GetM8Info(name, &realwidth, &realheight);
	}
	else if (strcmp(ext, "m32") == 0)
	{
		GetM32Info(name, &realwidth, &realheight);
	}

	/* try to load a tga, png or jpg (in that order/priority) */
	if (  LoadSTB(namewe, "tga", &pic, &width, &height, &claim)
	   || LoadSTB(namewe, "png", &pic, &width, &height, &claim)
	   || LoadSTB(namewe, "jpg", &pic, &width, &height, &claim) )
	{
		if (width >= realwidth && height >= realheight)
		{
			if (realheight == 0 || realwidth == 0)
			{
				realheight = height;
				realwidth = width;
			}

			image = load_image(name, pic,
				width, realwidth,
				height, realheight,
				width * height,
				type, 32);
		}

		/* AJ1: the successful LoadSTB reserved budget for its
		   canvas.  Hand it to the slot the load callback produced,
		   or give it back when it produced none (size check failed,
		   or load_image declined: bad dims, upload rollback, OOM). */
		if (image != NULL)
		{
			MTL_STBMarkImage(image, claim);
		}
		else
		{
			MTL_STBReleaseBytes(claim);
		}
	}

	if (pic)
	{
		free(pic);
	}

	return image;
}

struct image_s *
R_LoadImage(const char *name, const char* namewe, const char *ext, imagetype_t type,
	qboolean r_retexturing, loadimage_t load_image)
{
	struct image_s	*image = NULL;

	// with retexturing and not skin
	if (r_retexturing)
	{
		image = LoadHiColorImage(name, namewe, ext, type, load_image);
	}

	if (!image)
	{
		if (!strcmp(ext, "pcx"))
		{
			byte *pic = NULL;
			byte	*palette = NULL;
			int width = 0, height = 0, bitsPerPixel = 8;

			LoadPCX (namewe, &pic, &palette, &width, &height, &bitsPerPixel);
			if (!pic)
			{
				if (palette)
				{
					free(palette);
				}

				return NULL;
			}

			image = load_image(name, pic,
				width, width,
				height, height,
				width * height, type, bitsPerPixel);

			if (palette)
			{
				free(palette);
			}
			free(pic);
		}
		else if (!strcmp(ext, "wal"))
		{
			image = LoadWal(namewe, type, load_image);
		}
		else if (!strcmp(ext, "m8"))
		{
			image = LoadM8(namewe, type, load_image);
		}
		else if (!strcmp(ext, "m32"))
		{
			image = LoadM32(namewe, type, load_image);
		}
		else if (!strcmp(ext, "tga") ||
		         !strcmp(ext, "png") ||
		         !strcmp(ext, "jpg"))
		{
			byte *pic = NULL;
			int width = 0, height = 0;
			long long claim = 0;

			if (LoadSTB (namewe, ext, &pic, &width, &height, &claim) && pic)
			{
				image = load_image(name, pic,
					width, width,
					height, height,
					width * height,
					type, 32);

				free(pic);

				/* AJ1: same commit-or-release rule as
				   LoadHiColorImage (see there). */
				if (image != NULL)
				{
					MTL_STBMarkImage(image, claim);
				}
				else
				{
					MTL_STBReleaseBytes(claim);
				}
			}
		}
	}

	return image;
}

struct image_s*
GetSkyImage(const char *skyname, const char* surfname, qboolean palettedtexture,
	findimage_t find_image)
{
	struct image_s	*image = NULL;
	char	pathname[MAX_QPATH];

	/* Quake 2 */
	if (palettedtexture)
	{
		Com_sprintf(pathname, sizeof(pathname), "env/%s%s.pcx",
				skyname, surfname);
		image = find_image(pathname, it_sky);
	}

	if (!image)
	{
		Com_sprintf(pathname, sizeof(pathname), "env/%s%s.tga",
				skyname, surfname);
		image = find_image(pathname, it_sky);
	}

	/* Heretic 2 */
	if (!image)
	{
		Com_sprintf(pathname, sizeof(pathname), "pics/Skies/%s%s.m32",
			skyname, surfname);
		image = find_image(pathname, it_sky);
	}

	if (!image)
	{
		Com_sprintf(pathname, sizeof(pathname), "pics/Skies/%s%s.m8",
			skyname, surfname);
		image = find_image(pathname, it_sky);
	}

	return image;
}

struct image_s *
GetTexImage(const char *name, findimage_t find_image)
{
	struct image_s	*image = NULL;
	char	pathname[MAX_QPATH];

	/* Quake 2 */
	Com_sprintf(pathname, sizeof(pathname), "textures/%s.wal", name);
	image = find_image(pathname, it_wall);

	/* Quake2 Re-Release Nintendo 64 */
	if (!image)
	{
		Com_sprintf(pathname, sizeof(pathname), "textures/%s.tga", name);
		image = find_image(pathname, it_wall);
	}

	/* Heretic 2 */
	if (!image)
	{
		Com_sprintf(pathname, sizeof(pathname), "textures/%s.m32", name);
		image = find_image(pathname, it_wall);
	}

	if (!image)
	{
		Com_sprintf(pathname, sizeof(pathname), "textures/%s.m8", name);
		image = find_image(pathname, it_wall);
	}

	return image;
}

struct image_s *
R_FindPic(const char *name, findimage_t find_image)
{
	struct image_s	*image = NULL;

	if ((name[0] != '/') && (name[0] != '\\'))
	{
		char	pathname[MAX_QPATH];

		/* Quake 2 */
		Com_sprintf(pathname, sizeof(pathname), "pics/%s.pcx", name);
		image = find_image(pathname, it_pic);

		/* Quake 2 Re-Release */
		if (!image)
		{
			Com_sprintf(pathname, sizeof(pathname), "pics/%s.png", name);
			image = find_image(pathname, it_pic);
		}

		/* Heretic 2 */
		if (!image)
		{
			Com_sprintf(pathname, sizeof(pathname), "pics/misc/%s.m32", name);
			image = find_image(pathname, it_pic);
		}

		if (!image)
		{
			Com_sprintf(pathname, sizeof(pathname), "pics/misc/%s.m8", name);
			image = find_image(pathname, it_pic);
		}
	}
	else
	{
		image = find_image(name + 1, it_pic);
	}

	return image;
}
