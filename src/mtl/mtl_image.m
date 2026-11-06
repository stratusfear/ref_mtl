/*
 * Copyright (C) 1997-2001 Id Software, Inc.
 * Copyright (C) 2018-2019 Krzysztof Kondrak
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
 */

#include "header/mtl.h"

image_t		mtltextures[MAX_MTLTEXTURES];
int		nummtltextures = 0;
static int		img_loaded = 0;
static int		image_max = 0;

static byte			 intensitytable[256];
static unsigned char overbrightable[256];

static cvar_t	*intensity;

unsigned	d_8to24table[256];

image_t		*r_notexture;
image_t		*r_particletexture;
image_t		*r_squaretexture;

/*
==================
RE_InitParticleTexture
==================
*/
static byte	dottexture[8][8] =
{
	{0,0,0,0,0,0,0,0},
	{0,0,1,1,0,0,0,0},
	{0,1,1,1,1,0,0,0},
	{0,1,1,1,1,0,0,0},
	{0,0,1,1,0,0,0,0},
	{0,0,0,0,0,0,0,0},
	{0,0,0,0,0,0,0,0},
	{0,0,0,0,0,0,0,0},
};

void RE_InitParticleTexture (void)
{
	int		x,y,i;
	byte	data[8][8][4];

	//
	// particle texture
	//
	for (x=0 ; x<8 ; x++)
	{
		for (y=0 ; y<8 ; y++)
		{
			data[y][x][0] = 255;
			data[y][x][1] = 255;
			data[y][x][2] = 255;
			data[y][x][3] = dottexture[x][y]*255;
		}
	}
	r_particletexture = MTL_LoadPic("***particle***", (byte *)data,
		8, 8, 8, 8, 8 * 8, it_sprite, 32);

	//
	// particle texture
	//
	for (x=0 ; x<8 ; x++)
	{
		for (y=0 ; y<8 ; y++)
		{
			for (i=0 ; i<4 ; i++)
			{
				data[y][x][i] = ((y < 4) && (x < 4)) ? 255 : 0;
			}
		}
	}
	r_squaretexture = MTL_LoadPic("***square***", (byte *)data,
		8, 8, 8, 8, 8 * 8, it_sprite, 32);

	//
	// also use this for bad textures, but without alpha
	//
	for (x=0 ; x<8 ; x++)
	{
		for (y=0 ; y<8 ; y++)
		{
			data[y][x][0] = dottexture[x&3][y&3]*255;
			data[y][x][1] = 0;
			data[y][x][2] = 0;
			data[y][x][3] = 255;
		}
	}
	r_notexture = MTL_LoadPic("***r_notexture***", (byte *)data,
		8, 8, 8, 8, 8 * 8, it_wall, 32);
}

/*
===============
MTL_ImageList_f
===============
*/
void	MTL_ImageList_f (void)
{
	int		i, used, texels;
	image_t	*image;
	qboolean	freeup;

	Com_Printf("------------------\n");
	texels = 0;
	used = 0;

	for (i = 0, image = mtltextures; i < nummtltextures; i++, image++)
	{
		const char *in_use = "";

		if (!image->name[0])
			continue;

		if (image->registration_sequence == registration_sequence)
		{
			in_use = "*";
			used++;
		}

		texels += image->upload_width*image->upload_height;
		switch (image->type)
		{
		case it_skin:
			Com_Printf("M");
			break;
		case it_sprite:
			Com_Printf("S");
			break;
		case it_wall:
			Com_Printf("W");
			break;
		case it_pic:
			Com_Printf("P");
			break;
		default:
			Com_Printf(" ");
			break;
		}

		Com_Printf(" %4i %4i RGB: %s (%dx%d) %s\n",
			image->upload_width, image->upload_height, image->name,
			image->width, image->height, in_use);
	}
	Com_Printf("Total texel count (not counting mipmaps): %i in %d images\n", texels, img_loaded);
	freeup = MTL_ImageHasFreeSpace();
	Com_Printf("Used %d of %d / %d images%s.\n",
		used, image_max, MAX_MTLTEXTURES, freeup ? ", has free space" : "");
}

/*
====================================================================

IMAGE FLOOD FILLING

====================================================================
*/


/*
=================
Mod_FloodFillSkin

Fill background pixels so mipmapping doesn't have haloes
=================
*/

typedef struct
{
	short x, y;
} floodfill_t;

/* must be a power of 2 */
#define FLOODFILL_FIFO_SIZE 0x1000
#define FLOODFILL_FIFO_MASK (FLOODFILL_FIFO_SIZE - 1)

#define FLOODFILL_STEP(off, dx, dy)	\
	{ \
		if (pos[off] == fillcolor) \
		{ \
			pos[off] = 255;	\
			fifo[inpt].x = x + (dx), fifo[inpt].y = y + (dy); \
			inpt = (inpt + 1) & FLOODFILL_FIFO_MASK; \
		} \
		else if (pos[off] != 255) \
		{ \
			fdc = pos[off];	\
		} \
	}

/*
 * Fill background pixels so mipmapping doesn't have haloes
 */
static void
FloodFillSkin(byte *skin, int skinwidth, int skinheight)
{
	byte fillcolor = *skin; /* assume this is the pixel to fill */
	floodfill_t fifo[FLOODFILL_FIFO_SIZE];
	int inpt = 0, outpt = 0;
	int filledcolor = 0;
	int i;

	/* attempt to find opaque black */
	for (i = 0; i < 256; ++i)
	{
		if (LittleLong(d_8to24table[i]) == (255 << 0)) /* alpha 1.0 */
		{
			filledcolor = i;
			break;
		}
	}

	/* can't fill to filled color or to transparent color (used as visited marker) */
	if ((fillcolor == filledcolor) || (fillcolor == 255))
	{
		return;
	}

	fifo[inpt].x = 0, fifo[inpt].y = 0;
	inpt = (inpt + 1) & FLOODFILL_FIFO_MASK;

	while (outpt != inpt)
	{
		int x = fifo[outpt].x, y = fifo[outpt].y;
		int fdc = filledcolor;
		byte *pos = &skin[x + skinwidth * y];

		outpt = (outpt + 1) & FLOODFILL_FIFO_MASK;

		if (x > 0)
		{
			FLOODFILL_STEP(-1, -1, 0);
		}

		if (x < skinwidth - 1)
		{
			FLOODFILL_STEP(1, 1, 0);
		}

		if (y > 0)
		{
			FLOODFILL_STEP(-skinwidth, 0, -1);
		}

		if (y < skinheight - 1)
		{
			FLOODFILL_STEP(skinwidth, 0, 1);
		}

		skin[x + skinwidth * y] = fdc;
	}
}


/*
================
MTL_LightScaleTexture

Scale up the pixel values in a texture to increase the
lighting range
================
*/
static void
MTL_LightScaleTexture(byte *in, int inwidth, int inheight)
{
	int		i, c;
	byte	*p;

	p = (byte *)in;

	c = inwidth * inheight;
	for (i = 0; i < c; i++, p+=4)
	{
		p[0] = overbrightable[intensitytable[p[0]]];
		p[1] = overbrightable[intensitytable[p[1]]];
		p[2] = overbrightable[intensitytable[p[2]]];
	}
}

/*
===============
MTL_Upload32Native

Returns number of mip levels and scales native resolution
if mtl_picmip is set. Does not use power of 2 scaling.
===============
*/
static uint32_t
MTL_Upload32Native(byte *data, int width, int height, imagetype_t type,
	byte **texBuffer, int *upload_width, int *upload_height)
{
	int	scaled_width = width, scaled_height = height;
	int	miplevel = 1;

	*texBuffer = NULL;

	if (type != it_pic)
	{
		// let people sample down the world textures for speed
		scaled_width >>= (int)mtl_picmip->value;
		scaled_height >>= (int)mtl_picmip->value;
	}

	if (scaled_width < 1)
		scaled_width = 1;
	if (scaled_height < 1)
		scaled_height = 1;

	if (scaled_width == width && scaled_height == height)
	{
		// We can just send the data back and avoid an extra allocation/copy
		*texBuffer = data;
	}
	else
	{
		*texBuffer = malloc(scaled_width * scaled_height * 4);
		if (!*texBuffer)
			Com_Error(ERR_DROP, "%s: too big", __func__);

		ResizeSTB(data, width, height,
				  *texBuffer, scaled_width, scaled_height);
	}

	*upload_width = scaled_width;
	*upload_height = scaled_height;

	// world textures
	if (type != it_pic && type != it_sky)
	{
		MTL_LightScaleTexture(*texBuffer, scaled_width, scaled_height);
	}

	while (scaled_width > 1 || scaled_height > 1)
	{
		scaled_width >>= 1;
		scaled_height >>= 1;
		if (scaled_width < 1)
			scaled_width = 1;
		if (scaled_height < 1)
			scaled_height = 1;
		miplevel++;
	}

	return miplevel;
}


/*
===============
MTL_Upload8

Returns number of mip levels
===============
*/
static uint32_t
MTL_Upload8(const byte *data, int width, int height, imagetype_t type,
	byte **texBuffer, int *upload_width, int *upload_height)
{
	unsigned	*trans;
	int			i, s;
	int 		miplevel;

	s = width * height;

	trans = malloc(s * sizeof(*trans));
	if (!trans)
		Com_Error(ERR_DROP, "%s: too large", __func__);

	for (i = 0; i < s; i++)
	{
		int	p;

		p = data[i];
		trans[i] = d_8to24table[p];
	}

	if (type != it_sky && type != it_wall)
	{
		for (i = 0; i < s; i++)
		{
			int p;

			p = data[i];

			if (p == 255)
			{	// transparent, so scan around for another color
				// to avoid alpha fringes
				// FIXME: do a full flood fill so mips work...
				if (i > width && data[i - width] != 255)
				{
					p = data[i - width];
				}
				else if (i < s - width && data[i + width] != 255)
				{
					p = data[i + width];
				}
				else if (i > 0 && data[i - 1] != 255)
				{
					p = data[i - 1];
				}
				else if (i < s - 1 && data[i + 1] != 255)
				{
					p = data[i + 1];
				}
				else
				{
					p = 0;
				}

				/* copy rgb components */
				((byte *)&trans[i])[0] = ((byte *)&d_8to24table[p])[0];
				((byte *)&trans[i])[1] = ((byte *)&d_8to24table[p])[1];
				((byte *)&trans[i])[2] = ((byte *)&d_8to24table[p])[2];
			}
		}
	}

	// optimize 8bit images only when we forced such logic
	if (r_scale8bittextures->value)
	{
		SmoothColorImage(trans, s, s >> 7);
	}

	miplevel = MTL_Upload32Native((byte *)trans, width, height, type, texBuffer,
		upload_width, upload_height);

	// Only free if *texBuffer isn't the image data we sent
	if (!texBuffer || *texBuffer != (byte *)trans)
	{
		free(trans);
	}

	return miplevel;
}

/*
================
MTL_MipBoxFilter

A 2x2 box filter from a sw x sh RGBA image into dst. The destination is
(dw = max(1, sw/2), dh = max(1, sh/2)) pixels - the same floor rule Metal
uses for mip level sizes; edge pixels clamp by reusing the last source
row/column.
================
*/
static void
MTL_MipBoxFilter(const byte *src, int sw, int sh, byte *dst)
{
	int dw = sw >> 1;
	int dh = sh >> 1;
	int x, y, c;

	if (dw < 1)
		dw = 1;
	if (dh < 1)
		dh = 1;

	for (y = 0; y < dh; y++)
	{
		for (x = 0; x < dw; x++)
		{
			const byte *p00 = src + ((y << 1) * sw + (x << 1)) * 4;
			const byte *p01 = (x << 1) + 1 < sw ? p00 + 4 : p00;
			const byte *p10 = (y << 1) + 1 < sh ? p00 + sw * 4 : p00;
			const byte *p11 = ((x << 1) + 1 < sw && (y << 1) + 1 < sh) ?
				p00 + (sw + 1) * 4 : (p01 + (p10 - p00));
			byte *d = dst + (y * dw + x) * 4;

			for (c = 0; c < 4; c++)
			{
				d[c] = (byte)((p00[c] + p01[c] + p10[c] + p11[c]) >> 2);
			}
		}
	}
}

/*
================
MTL_MipNearFilter

M2: mtl_mip_nearfilter variant. ref_vk parity: vk_image.c generates
mips with VK_FILTER_NEAREST blits (vk_mip_nearfilter > 0). M8B2: the
round-8 note that the blit samples source texel (2x, 2y) was wrong.
A nearest blit at 2:1 evaluates at source coordinate 2x + 1, exactly
on the boundary between texels 2x and 2x + 1, and the blit resolves
the tie to 2x + 1. Paired jail1 captures under the same conditions
(mtl_mip_nearfilter / vk_mip_nearfilter = 1, spawn view): with the
old (2x, 2y) rule mtl differed from vk on 0.8% of pixels (mean
absdelta 1.7), while the vk-vs-vk reboot floor at the same setting
is 0.1%; sampling (2x + 1, 2y + 1) brings the mtl-vs-vk pair down
to 0.1-0.2%, i.e. vk's own floor. The nearfilter=0 (box filter) pair
was already at the floor, confirming the test isolates mip selection.
Point sample, no averaging.
================
*/
static void
MTL_MipNearFilter(const byte *src, int sw, int sh, byte *dst)
{
	int dw = sw >> 1;
	int dh = sh >> 1;
	int x, y;

	if (dw < 1)
		dw = 1;
	if (dh < 1)
		dh = 1;

	for (y = 0; y < dh; y++)
	{
		for (x = 0; x < dw; x++)
		{
			int sx = (x << 1) + 1;
			int sy = (y << 1) + 1;
			const byte *p;
			byte *d;

			if (sx >= sw)
				sx = sw - 1;
			if (sy >= sh)
				sy = sh - 1;
			p = src + (sy * sw + sx) * 4;
			d = dst + (y * dw + x) * 4;
			d[0] = p[0];
			d[1] = p[1];
			d[2] = p[2];
			d[3] = p[3];
		}
	}
}

/*
================
MTL_UploadTexture

W4: create the GPU texture for a loaded image. RGBA8Unorm shared storage,
one texture per image (images are never freed during a session). Level 0
is uploaded from texBuffer; the remaining mip levels are generated on the
CPU with a 2x2 box filter into two ping-pong scratch buffers - texBuffer
may be the original image data, so it is never written.
================
*/
static void
MTL_UploadTexture(image_t *image, byte *texBuffer, int width, int height,
	uint32_t mipcount)
{
	mtlstate_t *st = &mtl_state;
	MTLTextureDescriptor *td;
	id<MTLTexture> texture;
	byte *scratch0, *scratch1;
	const byte *src;
	byte *dst;
	int sw, sh;
	uint32_t level;

	if (mipcount < 1)
		mipcount = 1;

	td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
	        MTLPixelFormatRGBA8Unorm
	        width:(NSUInteger)width
	        height:(NSUInteger)height
	        mipmapped:mipcount > 1];
	td.mipmapLevelCount = mipcount;
	td.storageMode = MTLStorageModeShared;
	texture = [st->device newTextureWithDescriptor:td];
	if (texture == nil)
	{
		/* M6: this used to be a Com_DPrintf under a level the default
		   console hides, and the caller kept the image as valid with
		   mtl_texture nil - world/alias draws then silently skip the
		   surface (invisible geometry). Log loudly and substitute
		   r_notexture's texture (retained; the skip-mip path below
		   never runs for it), so the surface shows the notexture
		   checker instead. If even notexture has no texture (its own
		   creation failed, or this *is* notexture) there is nothing
		   sane to substitute and draws skip it as before. */
		Com_Printf("ref_mtl: failed to create GPU texture for %s, "
		           "using notexture instead\n", image->name);
		if (r_notexture != NULL && r_notexture != image &&
		    r_notexture->mtl_texture != nil)
		{
			image->mtl_texture = [r_notexture->mtl_texture retain];
		}
		return;
	}

	[texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
	        mipmapLevel:0 slice:0 withBytes:texBuffer
	        bytesPerRow:width * 4 bytesPerImage:width * height * 4];

	if (mipcount > 1)
	{
		scratch0 = malloc((size_t)width * height * 4);
		scratch1 = malloc((size_t)width * height * 4);
		if (!scratch0 || !scratch1)
			Com_Error(ERR_DROP, "%s: too big", __func__);

		sw = width;
		sh = height;
		for (level = 1; level < mipcount; level++)
		{
			/* Must match Metal's mip level sizes: max(1, dim >> level). */
			int dw = sw >> 1;
			int dh = sh >> 1;

			if (dw < 1)
				dw = 1;
			if (dh < 1)
				dh = 1;

			src = (level == 1) ? texBuffer : ((level & 1) ? (const byte *)scratch1 : (const byte *)scratch0);
			dst = (level & 1) ? scratch0 : scratch1;

			/* M2: mtl_mip_nearfilter picks the downsampling filter for
			   the generated levels, like vk_mip_nearfilter picking the
			   blit filter in generateMipmaps (vk_image.c:172). Read at
			   upload time only; existing images keep their mips until
			   reload (vk parity: no runtime apply there either). */
			if (mtl_mip_nearfilter->value > 0)
				MTL_MipNearFilter(src, sw, sh, dst);
			else
				MTL_MipBoxFilter(src, sw, sh, dst);

			[texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)dw, (NSUInteger)dh)
			        mipmapLevel:level slice:0 withBytes:dst
			        bytesPerRow:dw * 4 bytesPerImage:dw * dh * 4];

			sw = dw;
			sh = dh;
		}

		free(scratch0);
		free(scratch1);
	}

	image->mtl_texture = texture;
}


/*
================
MTL_LoadPic

This is also used as an entry point for the generated r_notexture
================
*/
image_t *
MTL_LoadPic(const char *name, byte *pic, int width, int realwidth,
	   int height, int realheight, size_t data_size, imagetype_t type,
	   int bits)
{
	image_t		*image;
	byte		*texBuffer = NULL;
	int		upload_width, upload_height;
	uint32_t	mipcount = 1;
	const char	*nolerplist = r_nolerp_list->string;
	const char	*lerplist = r_lerp_list->string;

	/* W8: same per-texture filtering decision as ref_vk's Vk_LoadPic.
	   Textures on r_nolerp_list (by default the conchars/ch* font pics)
	   get the nearest UI sampler at draw time instead of the linear one,
	   which is what keeps HUD and console text hard-edged at non-integer
	   display scales. */
	qboolean	nolerp = false;

	if (r_2D_unfiltered->value && type == it_pic)
	{
		// if r_2D_unfiltered is true(ish), nolerp should usually be true,
		// *unless* the texture is on the r_lerp_list
		nolerp = (lerplist == NULL) || Utils_FilenameFiltered(name, lerplist, ' ');
	}
	else if (nolerplist != NULL)
	{
		nolerp = Utils_FilenameFiltered(name, nolerplist, ' ');
	}

	{
		int		i;

		/* M5: scan every named slot for the name first. The old
		   combined loop stopped at the first unnamed slot, so once
		   MTL_FreeUnusedImages had punched holes, an image living in
		   a later slot was not recognized and a duplicate copy got
		   uploaded into the hole (reachable through the paths that
		   skip the MTL_FindImage pre-scan: generated images, or a
		   R_LoadImage extension hit different from the stored name). */
		for (i = 0; i < nummtltextures; i++)
		{
			if (mtltextures[i].name[0] && !strcmp(mtltextures[i].name, name))
			{
				/* we already have such image */
				mtltextures[i].registration_sequence = registration_sequence;
				return &mtltextures[i];
			}
		}

		// find a free image_t
		for (i = 0; i < nummtltextures; i++)
		{
			// W3.0: no GPU textures yet, so a free slot is an unnamed one
			if (!mtltextures[i].name[0])
			{
				break;
			}
		}

		if (i == nummtltextures)
		{
			if (nummtltextures == MAX_MTLTEXTURES)
				Com_Error(ERR_DROP, "%s: MAX_MTLTEXTURES", __func__);
			nummtltextures++;
		}
		image = &mtltextures[i];
	}

	if (strlen(name) >= sizeof(image->name))
		Com_Error(ERR_DROP, "%s: \"%s\" is too long", __func__, name);
	strcpy(image->name, name);
	image->registration_sequence = registration_sequence;
	image->mtl_texture = nil;
	image->type = type;
	image->nolerp = nolerp;
	if (realwidth && realheight)
	{
		image->width = realwidth;
		image->height = realheight;
	}
	else
	{
		image->width = width;
		image->height = height;
	}

	// update count of loaded images
	img_loaded ++;
	if (r_validation->value > 0)
	{
		Com_Printf("%s: Load %s[%d]\n", __func__, image->name, img_loaded);
	}

	if (type == it_skin && bits == 8)
		FloodFillSkin(pic, width, height);

	upload_width = realwidth;
	upload_height = realheight;

	if (bits == 8)
	{
		// resize 8bit images only when we forced such logic
		if (r_scale8bittextures->value)
		{
			byte *image_converted;
			int scale = 2;

			// scale 3 times if lerp image
			if (!nolerp && (vid.height >= 240 * 3))
				scale = 3;

			image_converted = malloc(width * height * scale * scale);
			if (!image_converted)
			{
				/* M6: the slot is already named and img_loaded already
				   bumped here; returning NULL without rolling back left
				   a named slot with mtl_texture nil (a permanent hole
				   that also skewed the r_validation load counter and
				   confused MTL_ImageHasFreeSpace). Same rollback as
				   MTL_FreeUnusedImages: wipe the slot, drop the count. */
				memset(image, 0, sizeof(*image));
				img_loaded--;
				Com_DPrintf("ref_mtl: out of memory scaling %s\n", name);
				return NULL;
			}

			if (scale == 3) {
				scale3x(pic, image_converted, width, height);
			} else {
				scale2x(pic, image_converted, width, height);
			}

			mipcount = MTL_Upload8(image_converted, width * scale, height * scale,
						image->type, &texBuffer,
						&upload_width, &upload_height);
			free(image_converted);
		}
		else
		{
			mipcount = MTL_Upload8(pic, width, height, image->type, &texBuffer, &upload_width, &upload_height);
		}
	}
	else
		mipcount = MTL_Upload32Native(pic, width, height, image->type, &texBuffer, &upload_width, &upload_height);

	image->upload_width = upload_width;		// after power of 2 and scales
	image->upload_height = upload_height;

	assert(texBuffer != NULL);

	/* W4: upload the texture to the GPU and generate the mip chain. */
	MTL_UploadTexture(image, texBuffer, upload_width, upload_height, mipcount);

	if (texBuffer && texBuffer != pic)
	{
		free(texBuffer);
	}
	return image;
}

/*
===============
MTL_FindImage

Finds or loads the given image or NULL
===============
*/
image_t	*
MTL_FindImage(const char *name, imagetype_t type)
{
	image_t	*image;
	int	i, len;
	char *ptr;
	char namewe[256];
	const char* ext;

	if (!name)
	{
		return NULL;
	}

	ext = COM_FileExtension(name);
	if(!ext[0])
	{
		/* file has no extension */
		return NULL;
	}

	len = strlen(name);
	if (len < 5)
	{
		return NULL;
	}

	/* Remove the extension */
	memset(namewe, 0, sizeof(namewe));
	memcpy(namewe, name, len - (strlen(ext) + 1));

	/* fix backslashes */
	while ((ptr = strchr(name, '\\')))
	{
		*ptr = '/';
	}

	/* look for it */
	for (i=0, image=mtltextures ; i<nummtltextures ; i++,image++)
	{
		if (!strcmp(name, image->name))
		{
			image->registration_sequence = registration_sequence;
			return image;
		}
	}

	/*
	 * load the pic from disk
	 */
	@autoreleasepool {
		/* Z1: the decode / upload path (MTL_LoadPic -> MTL_UploadTexture)
		   autoreleases its MTLTextureDescriptor and error-string
		   temporaries. This is the single choke point for every image in
		   the game (world textures, model skins via the findimage
		   callback, UI pics), and registration calls it between frames
		   where no frame pool exists. The image's own texture object is
		   created with newTextureWithDescriptor: and stored in the
		   mtltextures table, so it is not drained here. */
		image = (image_t *)R_LoadImage(name, namewe, ext, type,
			r_retexturing->value, (loadimage_t)MTL_LoadPic);
	}

	if (!image && r_validation->value > 0)
	{
		Com_Printf("%s: can't load %s\n", __func__, name);
	}

	return image;
}

/*
===============
RE_RegisterSkin
===============
*/
struct image_s *
RE_RegisterSkin(const char *name)
{
	return MTL_FindImage (name, it_skin);
}

qboolean
MTL_ImageHasFreeSpace(void)
{
	int		i, used;
	image_t	*image;

	used = 0;

	for (i = 0, image = mtltextures; i < nummtltextures; i++, image++)
	{
		if (!image->name[0])
			continue;
		if (image->registration_sequence == registration_sequence)
		{
			used ++;
		}
	}

	if (image_max < used)
	{
		image_max = used;
	}

	/* should same size of free slots as currently used */
	return (img_loaded + used) < MAX_MTLTEXTURES;
}

/*
================
MTL_FreeUnusedImages

Any image that was not touched on this registration sequence
will be freed.
================
*/
void MTL_FreeUnusedImages (void)
{
	int		i;
	image_t	*image;

	if (MTL_ImageHasFreeSpace())
	{
		/* should be enough space for load next images */
		return;
	}

	/* never free r_notexture or particle texture */
	r_notexture->registration_sequence = registration_sequence;
	r_particletexture->registration_sequence = registration_sequence;
	r_squaretexture->registration_sequence = registration_sequence;

	for (i = 0, image = mtltextures; i < nummtltextures; i++, image++)
	{
		if (image->registration_sequence == registration_sequence)
		{
			continue;		// used this sequence
		}
		if (!image->registration_sequence)
		{
			continue;		// free image_t slot
		}
		if (image->type == it_pic)
		{
			continue;		// don't free pics
		}

		if (r_validation->value > 0)
		{
			Com_Printf("%s: Unload %s[%d]\n", __func__, image->name, img_loaded);
		}

		/* free it */
		/* G1: mtl_texture holds the +1 from newTextureWithDescriptor;
		   dropping it without a release leaked the GPU texture (Shared
		   storage: system RAM + device allocation) on every eviction. */
		[image->mtl_texture release];
		image->mtl_texture = nil;
		memset(image, 0, sizeof(*image));

		img_loaded --;
		if (img_loaded < 0)
		{
			ri.Sys_Error (ERR_DROP, "%s: Broken unload", __func__);
		}
	}
}

/*
===============
MTL_InitImages
===============
*/
void	MTL_InitImages (void)
{
	int	i;
	float	overbright;
	byte	*colormap;

	nummtltextures = 0;
	img_loaded = 0;
	image_max = 0;
	registration_sequence = 1;

	// init intensity conversions
	intensity = ri.Cvar_Get("mtl_intensity", "2", 0);

	if (intensity->value <= 1)
		ri.Cvar_Set("mtl_intensity", "1");

	mtl_state.inverse_intensity = 1 / intensity->value;

	for (i = 0; i<256; i++)
	{
		int	j;

		j = i * intensity->value;
		if (j > 255)
			j = 255;
		intensitytable[i] = j;
	}

	GetPCXPalette (&colormap, d_8to24table);
	free(colormap);

	overbright = mtl_overbrightbits->value;

	if(overbright < 0.5)
		overbright = 0.5;

	if(overbright > 4.0)
		overbright = 4.0;

	for (i=0 ; i<256 ; i++) {
		int inf;

		inf = i * overbright;

		if (inf < 0)
			inf = 0;
		if (inf > 255)
			inf = 255;

		overbrightable[i] = inf;
	}
}

/*
===============
MTL_ShutdownImages
===============
*/
void	MTL_ShutdownImages (void)
{
	int		i;
	image_t	*image;

	for (i = 0, image = mtltextures; i<nummtltextures; i++, image++)
	{
		if (!image->registration_sequence)
			continue;		// free image_t slot

		if (r_validation->value > 0)
		{
			Com_Printf("%s: Unload %s[%d]\n", __func__, image->name, img_loaded);
		}

		/* G1: release before dropping the slot, see MTL_FreeUnusedImages */
		[image->mtl_texture release];
		image->mtl_texture = nil;
		memset(image, 0, sizeof(*image));

		img_loaded --;
		if (img_loaded < 0)
		{
			ri.Sys_Error (ERR_DROP, "%s: Broken unload", __func__);
		}
	}

	/* G1: was nil-only (leaked every lightmap texture) and is now
	   called from RE_Shutdown; MTL_FreeLightmaps() releases + nils. */
	MTL_FreeLightmaps();
}

