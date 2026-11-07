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
 * The models file format
 *
 * =======================================================================
 */

#include "../common/header/ref_shared.h"
#include <limits.h> /* AB1: INT_MAX for the model block bounds */

/*
=================
Mod_LoadSTvertList

load base s and t vertices (not used in gl version)
=================
*/
static void
Mod_LoadSTvertList (dmdl_t *pheader, dstvert_t *pinst)
{
	dstvert_t *poutst;
	int i;

	poutst = (dstvert_t *) ((byte *)pheader + pheader->ofs_st);

	for (i=0 ; i<pheader->num_st ; i++)
	{
		poutst[i].s = LittleShort (pinst[i].s);
		poutst[i].t = LittleShort (pinst[i].t);
	}
}

/*
=================
Mod_LoadCmdList

Load the glcmds
=================
*/
static void
Mod_LoadCmdList (const char *mod_name, dmdl_t *pheader, int *pincmd)
{
	int *poutcmd;
	int i;

	poutcmd = (int *)((char*)pheader + pheader->ofs_glcmds);
	for (i = 0; i < pheader->num_glcmds; i++)
	{
		poutcmd[i] = LittleLong (pincmd[i]);
	}

	if (poutcmd[pheader->num_glcmds-1] != 0)
	{
		Com_Printf("%s: Entity %s has possible last element issues with %d verts.\n",
			__func__, mod_name, poutcmd[pheader->num_glcmds-1]);
	}
}

/*
=================
Mod_LoadFrames

Load the frames
=================
*/
static void
Mod_LoadFrames (dmdl_t *pheader, byte *src, vec3_t translate)
{
	int i;

	for (i=0 ; i<pheader->num_frames ; i++)
	{
		daliasframe_t		*pinframe, *poutframe;
		int j;

		pinframe = (daliasframe_t *) (src + i * pheader->framesize);
		poutframe = (daliasframe_t *) ((byte *)pheader
			+ pheader->ofs_frames + i * pheader->framesize);

		memcpy (poutframe->name, pinframe->name, sizeof(poutframe->name));
		for (j=0 ; j<3 ; j++)
		{
			poutframe->scale[j] = LittleFloat (pinframe->scale[j]);
			poutframe->translate[j] = LittleFloat (pinframe->translate[j]);
			poutframe->translate[j] += translate[j];
		}
		// verts are all 8 bit, so no swapping needed
		memcpy (poutframe->verts, pinframe->verts,
			pheader->num_xyz*sizeof(dtrivertx_t));
	}
}

/*
=================
Mod_LoadDTriangleList

Load triangle lists
=================
*/
static void
Mod_LoadDTriangleList (dmdl_t *pheader, dtriangle_t *pintri)
{
	dtriangle_t *pouttri;
	int i;

	pouttri = (dtriangle_t *) ((byte *)pheader + pheader->ofs_tris);

	for (i=0 ; i<pheader->num_tris ; i++)
	{
		int j;

		for (j=0 ; j<3 ; j++)
		{
			pouttri[i].index_xyz[j] = LittleShort (pintri[i].index_xyz[j]);
			pouttri[i].index_st[j] = LittleShort (pintri[i].index_st[j]);
		}
	}
}

/*
=================
Mod_LoadDTriangleList

Load DKM triangle lists
=================
*/
static void
Mod_LoadDkmTriangleList (dmdl_t *pheader, dkmtriangle_t *pintri)
{
	dtriangle_t *pouttri;
	int i;

	pouttri = (dtriangle_t *) ((char *)pheader + pheader->ofs_tris);

	for (i=0 ; i<pheader->num_tris ; i++)
	{
		int j;

		for (j=0 ; j<3 ; j++)
		{
			pouttri[i].index_xyz[j] = LittleShort (pintri[i].index_xyz[j]);
			pouttri[i].index_st[j] = LittleShort (pintri[i].index_st[j]);
		}
	}
}

/*
=================
Mod_LoadDKMCmdList

Load the DKM glcmds
=================
*/
/* AF1: two trust holes here, one per direction.
   - Input: the walk below consumes 1 + 2 + 3*|count| dwords per
     command (command dword, two skipped dwords, three dwords per
     counted vertex) plus the terminating zero, while the caller's
     Z6 section check only guarantees pheader->num_glcmds dwords of
     the file lie inside the file.  A large count read straight off
     the end of the file buffer: the reviewer's
     rev_dkm_glcmds_read.bin, ASan heap-buffer-overflow READ of size
     4 at the LittleLong loads below, models.c:197 at tip 08bac21.
   - Output: the dwords were written into the model block's glcmds
     section before the pendcmd check could see them, so a count
     whose output did not fit wrote past the end of the model block,
     which is also the end of the hunk mapping (the round-22
     calibration SEGV writing at models.c:198 in this function), and
     a poutcmd past pendcmd made the trailing memset's negative
     length a huge size_t.  A count of INT_MIN additionally negated
     with signed overflow.
   The converter now checks a whole command's input dwords against
   the section and its output dwords against the model's glcmds
   section before writing any of it, and returns false so the
   caller gives the hunk back.  A list with no terminating zero
   stops at the section end and the rest is zero filled, as the
   trailing-zero convention intended.  Well-formed lists produce
   byte-identical output to the old walk. */
static qboolean
Mod_LoadDKMCmdList (const char *mod_name, dmdl_t *pheader, int *pincmd)
{
	const int	*inend;
	int			*poutcmd, *pendcmd;
	long long	n;
	int			i;

	/* the caller guarantees, through Z6's s_glcmds check, that
	   exactly pheader->num_glcmds little-endian dwords live at
	   pincmd; that is the read bound for everything below */
	inend = pincmd + pheader->num_glcmds;

	poutcmd = (int *)((char*)pheader + pheader->ofs_glcmds);
	pendcmd = poutcmd + pheader->num_glcmds;

	while (pincmd < inend)
	{
		/* read command count */
		i = LittleLong(*pincmd++);
		if (i == INT_MIN)
		{
			Com_Printf("%s: model %s has glcmd count %d\n",
				__func__, mod_name, i);
			return false;
		}
		if (poutcmd >= pendcmd)
		{
			Com_Printf("%s: Entity %s has possible broken glcmd.\n",
				__func__, mod_name);
			return false;
		}
		*poutcmd++ = i;
		if (i == 0)
		{
			break;
		}

		n = (i < 0) ? -(long long)i : (long long)i;
		if ((inend - pincmd) < (2 + 3 * n) ||
			(pendcmd - poutcmd) < (3 * n))
		{
			Com_Printf("%s: Entity %s has possible broken glcmd.\n",
				__func__, mod_name);
			return false;
		}

		/* skip unused surf_id and skin index */
		pincmd += 2;

		while (n)
		{
			poutcmd[0] = LittleLong (pincmd[1]);
			poutcmd[1] = LittleLong (pincmd[2]);
			poutcmd[2] = LittleLong (pincmd[0]);
			poutcmd += 3;
			pincmd += 3;
			n --;
		}
	}
	memset (poutcmd, 0, (pendcmd - poutcmd) * sizeof(int));

	return true;
}

/*
=================
Mod_DkmLoadFrames

Load the Dkm v2 frames
=================
*/
static void
Mod_LoadDkmFrames (dmdl_t *pheader, const byte *src, size_t infamesize, vec3_t translate)
{
	int i;

	for (i=0 ; i<pheader->num_frames ; i++)
	{
		daliasframe_t	*pinframe, *poutframe;
		dtrivertx_t	*outverts;
		byte	*inverts;
		int j;

		pinframe = (daliasframe_t *) (src + i * infamesize);
		poutframe = (daliasframe_t *) ((byte *)pheader
			+ pheader->ofs_frames + i * pheader->framesize);

		memcpy (poutframe->name, pinframe->name, sizeof(poutframe->name));
		for (j=0 ; j<3 ; j++)
		{
			poutframe->scale[j] = LittleFloat (pinframe->scale[j]);
			poutframe->translate[j] = LittleFloat (pinframe->translate[j]);
			poutframe->translate[j] += translate[j];
		}

		poutframe->scale[0] *= 8;
		poutframe->scale[1] *= 4;
		poutframe->scale[2] *= 8;

		inverts = (byte *)&pinframe->verts;
		outverts = poutframe->verts;
		/* dkm vert version 2 has unalligned by int size struct */
		for(j=0; j < pheader->num_xyz; j++)
		{
			int xyz;

			xyz = LittleLong (*((int *)inverts));
			outverts[j].v[0] = ((xyz & 0xFFE00000) >> (21 + 3)) & 0xFF;
			outverts[j].v[1] = ((xyz & 0x1FF800) >> (11 + 2)) & 0xFF;
			outverts[j].v[2] = ((xyz & 0x7FF) >> 3) & 0xFF;
			inverts += sizeof(int);
			outverts[j].lightnormalindex = *inverts;
			inverts ++;
		}
	}
}

/*
=================
Mod_LoadMDL
=================
*/
/* AB1: Mod_CheckAliasHeader is defined below; the MDL loader runs the
   header it generates through that shared check. */
static qboolean
Mod_CheckAliasHeader (const char *mod_name, const dmdl_t *hdr);

static void *
Mod_LoadMDL (const char *mod_name, const void *buffer, int modfilelen,
	vec3_t mins, vec3_t maxs, struct image_s **skins, findimage_t find_image,
	modtype_t *type)
{
	const mdl_header_t		*pinmodel;
	int		version;
	dmdl_t		*pheader;
	void	*extradata;

	/* local copy of all values */
	int skinwidth, skinheight, framesize;
	int num_skins, num_xyz, num_st, num_tris, num_glcmds, num_frames;
	int ofs_skins, ofs_st, ofs_tris, ofs_frames, ofs_glcmds, ofs_end;
	/* AB1: the same quantities before they are narrowed: every one of
	   them is fed by products of file supplied counts, so the bound
	   checks run in 64 bit and only checked values become int. */
	long long inputextent, framesize64, num_glcmds64;
	long long ofs_skins64, ofs_st64, ofs_tris64, ofs_glcmds64,
		ofs_frames64, ofs_end64;

	pinmodel = (mdl_header_t *)buffer;

	/* AE6: AB1 bound every value the walk below reads, but the
	   version and count loads here were still the first thing done
	   to the buffer; a 4..(sizeof(mdl_header_t)-1) byte "IDPO" file
	   reads past it before inputextent ever runs. */
	if (modfilelen < (int)sizeof(mdl_header_t))
	{
		Com_Printf("%s: model %s is %d bytes, less than its header",
				__func__, mod_name, modfilelen);
		return NULL;
	}

	version = LittleLong (pinmodel->version);
	if (version != MDL_VERSION)
	{
		Com_Printf("%s: %s has wrong version number (%i should be %i)",
				__func__, mod_name, version, MDL_VERSION);
		return NULL;
	}

	/* count and dimension fields, all file supplied */
	num_skins = LittleLong (pinmodel->num_skins);
	skinwidth = LittleLong (pinmodel->skinwidth);
	skinheight = LittleLong (pinmodel->skinheight);
	num_xyz = LittleLong (pinmodel->num_xyz);
	num_st = num_xyz;
	num_tris = LittleLong (pinmodel->num_tris);
	num_frames = LittleLong (pinmodel->num_frames);

	/* AB1: these counts drive the input walk and the generated model
	   block, so bound them before any of them is used in a product or
	   as a divisor.  The MD2 limits are the natural ones: the loader
	   emits a dmdl_t with the same layout the MD2 loader validates, and
	   the texcoord scaling below divides by the skin dimensions. */
	if ((skinwidth < 1) || (skinwidth > MAX_LBM_HEIGHT))
	{
		Com_Printf("%s: model %s has skin width %d\n",
				__func__, mod_name, skinwidth);
		return NULL;
	}

	if ((skinheight < 1) || (skinheight > MAX_LBM_HEIGHT))
	{
		Com_Printf("%s: model %s has skin height %d\n",
				__func__, mod_name, skinheight);
		return NULL;
	}

	if ((num_skins < 0) || (num_skins > MAX_MD2SKINS))
	{
		Com_Printf("%s: model %s has %d skins",
				__func__, mod_name, num_skins);
		return NULL;
	}

	if (num_xyz <= 0)
	{
		Com_Printf("%s: model %s has no vertices",
				__func__, mod_name);
		return NULL;
	}

	if (num_xyz > MAX_VERTS)
	{
		Com_Printf("%s: model %s has too many vertices",
				__func__, mod_name);
		return NULL;
	}

	if (num_tris <= 0)
	{
		Com_Printf("%s: model %s has no triangles",
				__func__, mod_name);
		return NULL;
	}

	/* AB1: num_tris was unbounded above; MAX_TRIANGLES also caps the
	   renderer's command list. */
	if (num_tris > MAX_TRIANGLES)
	{
		Com_Printf("%s: model %s has too many triangles",
				__func__, mod_name);
		return NULL;
	}

	if (num_frames <= 0)
	{
		Com_Printf("%s: model %s has no frames",
				__func__, mod_name);
		return NULL;
	}

	/* AB1: num_frames was unbounded above */
	if (num_frames > MAX_FRAMES)
	{
		Com_Printf("%s: model %s has too many frames",
				__func__, mod_name);
		return NULL;
	}

	/* AB1: the old code bounded only the generated model block (the
	   ofs_end check below), never the input: the walk over the skins
	   (a 4 byte type plus skinwidth*skinheight pixels each), the
	   num_st texcoords, the num_tris triangles and the frames (a 4
	   byte type, two bounding box records, a 16 byte name and num_xyz
	   vertices each) could leave the buffer.  Sum the whole input
	   extent in 64 bit and reject against the file length first. */
	inputextent = (long long)sizeof(mdl_header_t)
		+ (long long)num_skins * (sizeof(int) +
			(long long)skinwidth * skinheight)
		+ (long long)num_st * sizeof(mdl_texcoord_t)
		+ (long long)num_tris * sizeof(mdl_triangle_t)
		+ (long long)num_frames * (sizeof(int) +
			2 * sizeof(dtrivertx_t) + 16 +
			(long long)num_xyz * sizeof(dtrivertx_t));
	if (inputextent > (long long)modfilelen)
	{
		Com_Printf("%s: model %s is truncated: needs %lld bytes, "
				"file has %d\n",
				__func__, mod_name, inputextent, modfilelen);
		return NULL;
	}

	/* generate all offsets and sizes in 64 bit (AB1: the old int
	   arithmetic wrapped for hostile counts, and num_glcmds was
	   truncated from a size_t expression) */
	num_glcmds64 = (long long)num_tris * 10 + 1;
	/* three ints per vertex (s, t, index), a triangle count and a
	   final zero */
	framesize64 = (long long)sizeof(daliasframe_t) +
		(long long)sizeof(dtrivertx_t) * (num_xyz - 1);

	ofs_skins64 = sizeof(dmdl_t); // just skip header and go
	ofs_st64 = ofs_skins64 + (long long)num_skins * MAX_SKINNAME;
	ofs_tris64 = ofs_st64 + (long long)num_st * sizeof(dstvert_t);
	ofs_glcmds64 = ofs_tris64 + (long long)num_tris * sizeof(dtriangle_t);
	ofs_frames64 = ofs_glcmds64 + num_glcmds64 * sizeof(int);
	/* one less as single vertx in frame by default */
	ofs_end64 = ofs_frames64 + framesize64 * num_frames;

	if (ofs_end64 > INT_MAX)
	{
		Com_Printf("%s: model %s is too big.",
				__func__, mod_name);
		return NULL;
	}

	/* AB1: the check the Z6 helper applies to the MD2, flex and DKM
	   headers, run here on the values the loader is about to store;
	   it re-checks the section extents and the frame stride against
	   the finished layout. */
	{
		dmdl_t chkheader;

		chkheader.ident = IDALIASHEADER;
		chkheader.version = ALIAS_VERSION;
		chkheader.skinwidth = (int)skinwidth;
		chkheader.skinheight = (int)skinheight;
		chkheader.framesize = (int)framesize64;
		chkheader.num_skins = num_skins;
		chkheader.num_xyz = num_xyz;
		chkheader.num_st = num_st;
		chkheader.num_tris = num_tris;
		chkheader.num_glcmds = (int)num_glcmds64;
		chkheader.num_frames = num_frames;
		chkheader.ofs_skins = (int)ofs_skins64;
		chkheader.ofs_st = (int)ofs_st64;
		chkheader.ofs_tris = (int)ofs_tris64;
		chkheader.ofs_frames = (int)ofs_frames64;
		chkheader.ofs_glcmds = (int)ofs_glcmds64;
		chkheader.ofs_end = (int)ofs_end64;

		if (!Mod_CheckAliasHeader(mod_name, &chkheader))
		{
			return NULL;
		}
	}

	/* the model block may not exceed the file either, so the hunk
	   allocation stays bounded by input the caller has already shown
	   to exist (kept from the old code, now 64 bit) */
	if ((long long)modfilelen < ofs_end64)
	{
		Com_Printf("%s: model %s is too big.",
				__func__, mod_name);
		return NULL;
	}

	/* narrow: every value is now within range */
	framesize = (int)framesize64;
	num_glcmds = (int)num_glcmds64;
	ofs_skins = (int)ofs_skins64;
	ofs_st = (int)ofs_st64;
	ofs_tris = (int)ofs_tris64;
	ofs_glcmds = (int)ofs_glcmds64;
	ofs_frames = (int)ofs_frames64;
	ofs_end = (int)ofs_end64;

	extradata = Hunk_Begin(ofs_end);
	pheader = Hunk_Alloc(ofs_end);

	/* copy back all values */
	pheader->ident = IDALIASHEADER;
	pheader->version = ALIAS_VERSION;
	pheader->skinwidth = skinwidth;
	pheader->skinheight = skinheight;
	pheader->framesize = framesize;

	pheader->num_skins = num_skins;
	pheader->num_xyz = num_xyz;
	pheader->num_st = num_st;
	pheader->num_tris = num_tris;
	pheader->num_glcmds = num_glcmds;
	pheader->num_frames = num_frames;

	pheader->ofs_skins = ofs_skins;
	pheader->ofs_st = ofs_st;
	pheader->ofs_tris = ofs_tris;
	pheader->ofs_frames = ofs_frames;
	pheader->ofs_glcmds = ofs_glcmds;
	pheader->ofs_end = ofs_end;

	{
		int i;
		const byte *curr_pos;

		mdl_triangle_t *triangles;
		mdl_texcoord_t *texcoords;
		dtriangle_t *pouttri; /* AB1: also used by the glcmds below */

		curr_pos = (byte*)buffer + sizeof (mdl_header_t);

		// register all skins
		for (i = 0; i < num_skins; ++i)
		{
			char *out_pos;
			int skin_type;

			out_pos = (char*)pheader + sizeof(dmdl_t);
			snprintf(out_pos + MAX_SKINNAME * i, MAX_SKINNAME, "%s#%d.tga", mod_name, i);

			/* skip type / int */
			/* 0 = simple, !0 = group */
			/* this program can't read models composed of group frames! */
			skin_type = LittleLong (((int *)curr_pos)[0]);
			curr_pos += sizeof(int);
			if (skin_type)
			{
				Com_Printf("%s: model %s has unsupported skin type %d",
						__func__, mod_name, skin_type);
				goto fail; /* AC1 */
			}

			/* skip 8bit image */
			curr_pos += skinwidth * skinheight;
		}

		/* texcoordinates */
		{
			dstvert_t *poutst = (dstvert_t *) ((byte *)pheader + ofs_st);

			texcoords = (mdl_texcoord_t *)curr_pos;
			curr_pos += sizeof (mdl_texcoord_t) * num_st;

			for(i = 0; i < num_st; i++)
			{
				/* Compute texture coordinates */
				poutst[i].s = LittleLong (texcoords[i].s);
				poutst[i].t = LittleLong (texcoords[i].t);

				if (texcoords[i].onseam)
				{
					poutst[i].s += skinwidth * 0.5f; /* Backface */
				}

				/* Scale s and t to range from 0.0 to 1.0 */
				poutst[i].s = (poutst[i].s + 0.5) / skinwidth;
				poutst[i].t = (poutst[i].t + 0.5) / skinheight;
			}
		}

		/* triangles */
		{
			pouttri = (dtriangle_t *) ((byte *)pheader + ofs_tris);

			triangles = (mdl_triangle_t *) curr_pos;
			curr_pos += sizeof (mdl_triangle_t) * num_tris;

			for (i=0 ; i<num_tris ; i++)
			{
				int j;

				for (j=0 ; j<3 ; j++)
				{
					int vertex = LittleLong (triangles[i].vertex[j]);

					/* AB1: these indices are stored (through shorts)
					   for the renderer and replayed as offsets into the
					   vertex and st arrays; a value outside them must
					   not be stored. */
					if ((vertex < 0) || (vertex >= num_xyz))
					{
						Com_Printf("%s: model %s has triangle "
								"vertex index %d",
								__func__, mod_name, vertex);
						goto fail; /* AC1 */
					}

					pouttri[i].index_xyz[j] = vertex;
					pouttri[i].index_st[j] = vertex;
				}
			}
		}

		{
			int *glcmds = (int *) ((byte *)pheader + ofs_glcmds);

			/* commands */
			int j, *curr_com = glcmds;

			/* Draw each triangle */
			for (i = 0; i < num_tris; ++i)
			{
				*curr_com = 3;
				curr_com++;

				/* Draw each vertex */
				for (j = 0; j < 3; ++j)
				{
					float s,t;
					int index;

					/* AB1: use the index the triangle loop above
					   already range-checked; reading the raw file
					   value again here would bypass that check */
					index = pouttri[i].index_xyz[j];

					/* Compute texture coordinates */
					s = LittleLong (texcoords[index].s);
					t = LittleLong (texcoords[index].t);

					if (!triangles[i].facesfront &&
						texcoords[index].onseam)
					{
						s += skinwidth * 0.5f; /* Backface */
					}

					/* Scale s and t to range from 0.0 to 1.0 */
					s = (s + 0.5) / skinwidth;
					t = (t + 0.5) / skinheight;

					memcpy(curr_com, &s, sizeof(s));
					curr_com++;
					memcpy(curr_com, &t, sizeof(t));
					curr_com++;
					memcpy(curr_com, &index, sizeof(index));
					curr_com++;
				}
			}

			*curr_com = 0;
			curr_com++;
		}

		/* register all frames */
		for (i = 0; i < num_frames; ++i)
		{
			daliasframe_t *frame;
			int frame_type;

			frame = (daliasframe_t *) ((byte *)pheader + ofs_frames + i * framesize);
			frame->scale[0] = LittleFloat (pinmodel->scale[0]);
			frame->scale[1] = LittleFloat (pinmodel->scale[1]);
			frame->scale[2] = LittleFloat (pinmodel->scale[2]);

			frame->translate[0] = LittleFloat (pinmodel->translate[0]);
			frame->translate[1] = LittleFloat (pinmodel->translate[1]);
			frame->translate[2] = LittleFloat (pinmodel->translate[2]);

			/* Read frame data */
			/* skip type / int */
			/* 0 = simple, !0 = group */
			/* this program can't read models composed of group frames! */
			frame_type = LittleLong (((int *)curr_pos)[0]);
			curr_pos += sizeof (frame_type);

			if (frame_type)
			{
				Com_Printf("%s: model %s has unsupported frame type %d",
						__func__, mod_name, frame_type);
				goto fail; /* AC1 */
			}
			/* skip bboxmin, bouding box min */
			curr_pos += sizeof(dtrivertx_t);
			/* skip bboxmax, bouding box max */
			curr_pos += sizeof(dtrivertx_t);

			memcpy(&frame->name, curr_pos, sizeof (char) * 16);
			curr_pos += sizeof (char) * 16;

			memcpy(&frame->verts[0], curr_pos,
				sizeof (dtrivertx_t) * num_xyz);
			curr_pos += sizeof (dtrivertx_t) * num_xyz;
		}
	}

	*type = mod_alias;

	mins[0] = -32;
	mins[1] = -32;
	mins[2] = -32;
	maxs[0] = 32;
	maxs[1] = 32;
	maxs[2] = 32;
	return extradata;

	/* AC1: the three exits above that jump here all run after
	   Hunk_Begin(); the half-built hunk mapping has to go back or
	   every rejected load orphans one: Mod_ForName stores the NULL,
	   and on the retry its Z4 sentinel path frees the slot through
	   Mod_Free's !extradata branch, which never sees the pointer.
	   The mapping header records the full reservation (Z4), so
	   Hunk_Free() is correct at any point of the load. */
fail:
	Hunk_Free(extradata);
	return NULL;
}

/*
=================
Mod_CheckAliasHeader

Z6: sanity check for a dmdl_t-shaped model header, used by the MD2,
flex and DKM loaders.  The counts and offsets below drive the
memcpy() sizes and the loop bounds of the section loaders, and each
section is read from the file buffer and written into the model block
at the same offset, so every section has to fit inside the model
(ofs_end, itself bounded by the file length).  The sizes are products
of file-supplied counts, so they are computed in 64 bit: a hostile
count must not be able to wrap a section end back into the model.
Returns false and prints the reason when the header cannot be loaded.
=================
*/
static qboolean
Mod_CheckAliasHeader (const char *mod_name, const dmdl_t *hdr)
{
	if (hdr->ofs_end < (int)sizeof(dmdl_t))
	{
		Com_Printf("%s: model %s ends at %d, before its own header\n",
				__func__, mod_name, hdr->ofs_end);
		return false;
	}

	if (hdr->skinheight > MAX_LBM_HEIGHT)
	{
		Com_Printf("%s: model %s has a skin taller than %d\n",
				__func__, mod_name, MAX_LBM_HEIGHT);
		return false;
	}

	if (hdr->num_skins < 0)
	{
		Com_Printf("%s: model %s has %d skins\n",
				__func__, mod_name, hdr->num_skins);
		return false;
	}

	if (hdr->num_xyz <= 0)
	{
		Com_Printf("%s: model %s has no vertices\n",
				__func__, mod_name);
		return false;
	}

	if (hdr->num_xyz > MAX_VERTS)
	{
		Com_Printf("%s: model %s has too many vertices\n",
				__func__, mod_name);
		return false;
	}

	/* each frame is read as one framesize stride and its num_xyz
	   vertices are copied out of it, so the stride has to carry them */
	if (hdr->framesize <
		(int)(sizeof(daliasframe_t) +
			(hdr->num_xyz - 1) * sizeof(dtrivertx_t)))
	{
		Com_Printf("%s: model %s has framesize %d for %d vertices\n",
				__func__, mod_name, hdr->framesize, hdr->num_xyz);
		return false;
	}

	if (hdr->num_st <= 0)
	{
		Com_Printf("%s: model %s has no st vertices\n",
				__func__, mod_name);
		return false;
	}

	if (hdr->num_tris <= 0)
	{
		Com_Printf("%s: model %s has no triangles\n",
				__func__, mod_name);
		return false;
	}

	if (hdr->num_frames <= 0)
	{
		Com_Printf("%s: model %s has no frames\n",
				__func__, mod_name);
		return false;
	}

	/* the command list is terminated by a zero entry, and the loader
	   checks the last one: an empty list would read in front of it */
	if (hdr->num_glcmds < 1)
	{
		Com_Printf("%s: model %s has %d glcmds\n",
				__func__, mod_name, hdr->num_glcmds);
		return false;
	}

	if ((hdr->ofs_skins < 0) ||
		((long long)hdr->ofs_skins +
			(long long)hdr->num_skins * MAX_SKINNAME >
			(long long)hdr->ofs_end))
	{
		Com_Printf("%s: model %s has %d skins at %d, model ends at %d\n",
				__func__, mod_name, hdr->num_skins, hdr->ofs_skins,
				hdr->ofs_end);
		return false;
	}

	if ((hdr->ofs_st < 0) ||
		((long long)hdr->ofs_st +
			(long long)hdr->num_st * (long long)sizeof(dstvert_t) >
			(long long)hdr->ofs_end))
	{
		Com_Printf("%s: model %s has %d st vertices at %d, model ends at %d\n",
				__func__, mod_name, hdr->num_st, hdr->ofs_st,
				hdr->ofs_end);
		return false;
	}

	if ((hdr->ofs_tris < 0) ||
		((long long)hdr->ofs_tris +
			(long long)hdr->num_tris * (long long)sizeof(dtriangle_t) >
			(long long)hdr->ofs_end))
	{
		Com_Printf("%s: model %s has %d triangles at %d, model ends at %d\n",
				__func__, mod_name, hdr->num_tris, hdr->ofs_tris,
				hdr->ofs_end);
		return false;
	}

	if ((hdr->ofs_frames < 0) ||
		((long long)hdr->ofs_frames +
			(long long)hdr->num_frames * (long long)hdr->framesize >
			(long long)hdr->ofs_end))
	{
		Com_Printf("%s: model %s has %d frames of %d bytes at %d, model ends at %d\n",
				__func__, mod_name, hdr->num_frames, hdr->framesize,
				hdr->ofs_frames, hdr->ofs_end);
		return false;
	}

	if ((hdr->ofs_glcmds < 0) ||
		((long long)hdr->ofs_glcmds +
			(long long)hdr->num_glcmds * (long long)sizeof(int) >
			(long long)hdr->ofs_end))
	{
		Com_Printf("%s: model %s has %d glcmds at %d, model ends at %d\n",
				__func__, mod_name, hdr->num_glcmds, hdr->ofs_glcmds,
				hdr->ofs_end);
		return false;
	}

	return true;
}

/*
=================
Mod_LoadMD2
=================
*/
static void *
Mod_LoadMD2 (const char *mod_name, const void *buffer, int modfilelen,
	vec3_t mins, vec3_t maxs, struct image_s **skins, findimage_t find_image,
	modtype_t *type)
{
	vec3_t		translate = {0, 0, 0};
	dmdl_t		*pinmodel, *pheader;
	dtriangle_t	*pintri;
	dstvert_t	*pinst;
	int		*pincmd;
	void	*extradata;
	int		version;
	int		ofs_end;
	int		i;

	pinmodel = (dmdl_t *)buffer;

	/* Z6: the header is read before any of its counts are trusted.
	   AE6: the check has to run before the first field read, not
	   after it - a 4..(sizeof(dmdl_t)-1) byte "IDP2" file used to
	   make the version load below dereference past the buffer the
	   host's FS handed over. */
	if (modfilelen < (int)sizeof(dmdl_t))
	{
		Com_Printf("%s: model %s is %d bytes, less than its header",
				__func__, mod_name, modfilelen);
		return NULL;
	}

	version = LittleLong (pinmodel->version);
	if (version != ALIAS_VERSION)
	{
		Com_Printf("%s: %s has wrong version number (%i should be %i)",
				__func__, mod_name, version, ALIAS_VERSION);
		return NULL;
	}

	ofs_end = LittleLong(pinmodel->ofs_end);
	if (ofs_end < 0 || ofs_end > modfilelen)
	{
		Com_Printf("%s: model %s file size(%d) too small, should be %d",
				__func__, mod_name, modfilelen, ofs_end);
		return NULL;
	}

	/* Z6: check the whole header - every count and offset that the
	   section loaders below copy or loop over - before the model is
	   reserved, so a broken file is rejected without leaving a hunk
	   behind. */
	{
		dmdl_t	pinhdr;
		int		j;

		for (j = 0; j < (int)(sizeof(pinhdr) / sizeof(int)); j++)
		{
			((int *)&pinhdr)[j] = LittleLong(((const int *)pinmodel)[j]);
		}

		/* skins past the model's skin limit are ignored below, so only
		   the ones that are copied have to fit in the model */
		if (pinhdr.num_skins > MAX_MD2SKINS)
		{
			pinhdr.num_skins = MAX_MD2SKINS;
		}

		if (!Mod_CheckAliasHeader(mod_name, &pinhdr))
		{
			return NULL;
		}
	}

	/* AC1: audit: this loader has no return-NULL exit between
	   Hunk_Begin() and its success return, so there is no
	   post-allocation path to free here. */
	extradata = Hunk_Begin(modfilelen);
	pheader = Hunk_Alloc(ofs_end);

	// byte swap the header fields and sanity check
	for (i=0 ; i<sizeof(dmdl_t)/sizeof(int) ; i++)
		((int *)pheader)[i] = LittleLong (((int *)buffer)[i]);

	/* a file with more skins than the model has room for keeps the
	   skins that fit (the section itself was checked against the end
	   of the model above) */
	if (pheader->num_skins > MAX_MD2SKINS)
	{
		Com_Printf("%s has too many skins (%i > %i), "
				"extra sprites will be ignored\n",
				mod_name, pheader->num_skins, MAX_MD2SKINS);
		pheader->num_skins = MAX_MD2SKINS;
	}

	//
	// load base s and t vertices (not used in gl version)
	//
	pinst = (dstvert_t *) ((byte *)pinmodel + pheader->ofs_st);
	Mod_LoadSTvertList (pheader, pinst);

	//
	// load triangle lists
	//
	pintri = (dtriangle_t *) ((byte *)pinmodel + pheader->ofs_tris);
	Mod_LoadDTriangleList (pheader, pintri);

	//
	// load the frames
	//
	Mod_LoadFrames (pheader, (byte *)pinmodel + pheader->ofs_frames, translate);

	//
	// load the glcmds
	//
	pincmd = (int *) ((byte *)pinmodel + pheader->ofs_glcmds);
	Mod_LoadCmdList (mod_name, pheader, pincmd);

	// register all skins
	memcpy ((char *)pheader + pheader->ofs_skins, (char *)pinmodel + pheader->ofs_skins,
		pheader->num_skins*MAX_SKINNAME);

	// Load in our skins.
	for (i=0; i < pheader->num_skins; i++)
	{
		skins[i] = find_image((char *)pheader + pheader->ofs_skins + i*MAX_SKINNAME,
			it_skin);
	}

	*type = mod_alias;

	mins[0] = -32;
	mins[1] = -32;
	mins[2] = -32;
	maxs[0] = 32;
	maxs[1] = 32;
	maxs[2] = 32;

	return extradata;
}


/*
=============
Mod_LoadFlexModel
=============
*/
static void *
Mod_LoadFlexModel(const char *mod_name, const void *buffer, int modfilelen,
	vec3_t mins, vec3_t maxs, struct image_s **skins, findimage_t find_image,
	modtype_t *type)
{
	char *src = (char *)buffer;
	int version, size, i;
	int fmfilelen = modfilelen;
	void *extradata = NULL;
	dmdl_t *pheader = NULL;

	while (modfilelen > 0)
	{
		char blockname[32];

		/* Z6: a block header is 32 name bytes plus a version and a
		   size word; the file has to hold a whole header before any
		   of it is read */
		if (modfilelen < (int)(sizeof(blockname) + (2 * sizeof(int))))
		{
			Com_Printf("%s: %s is truncated, %d bytes left where a block header needs %d\n",
				__func__, mod_name, modfilelen,
				(int)(sizeof(blockname) + (2 * sizeof(int))));
			return NULL;
		}

		memcpy(blockname, src, sizeof(blockname));

		src += sizeof(blockname);
		version = *(int*)src;
		src += sizeof(version);
		size = *(int*)src;
		src += sizeof(size);
		modfilelen = modfilelen - sizeof(blockname) - sizeof(version) - sizeof(size);

		/* Z6: the block handlers below read size bytes from src and src
		   then advances by size, so the body has to lie inside the file */
		if ((size < 0) || (size > modfilelen))
		{
			Com_Printf("%s: %s block %s claims %d bytes, only %d left\n",
				__func__, mod_name, blockname, size, modfilelen);
			return NULL;
		}

		if (Q_strncasecmp(blockname, "header", sizeof(blockname)) == 0)
		{
			dmdl_t dmdlheader;
			fmheader_t *header = (fmheader_t *)src;
			long long o_skins, o_st, o_tris, o_frames, o_glcmds, o_end;
			int num_mesh_nodes;

			if (sizeof(fmheader_t) > size)
			{
				Com_Printf("%s: Too short header", __func__);
				return NULL;
			}

			if (version != 2)
			{
				Com_Printf("%s: Invalid %s version %d",
					__func__, blockname, version);
				return NULL;
			}

			/* copy back all values */
			dmdlheader.ident = IDALIASHEADER;
			dmdlheader.version = ALIAS_VERSION;
			dmdlheader.skinwidth = LittleLong (header->skinwidth);
			dmdlheader.skinheight = LittleLong (header->skinheight);
			dmdlheader.framesize = LittleLong (header->framesize);

			dmdlheader.num_skins = LittleLong (header->num_skins);
			dmdlheader.num_xyz = LittleLong (header->num_xyz);
			dmdlheader.num_st = LittleLong (header->num_st);
			dmdlheader.num_tris = LittleLong (header->num_tris);
			dmdlheader.num_glcmds = LittleLong (header->num_glcmds);
			dmdlheader.num_frames = LittleLong (header->num_frames);

			// just skip header and meshes
			/* Z6: the layout below sizes the model block, and every
			   part of it is a block of this file, so the offsets are
			   built in 64 bit, have to grow monotonically (a negative
			   count would shrink one) and the whole model has to fit
			   inside the file that carries its blocks. */
			num_mesh_nodes = LittleLong (header->num_mesh_nodes);
			if (num_mesh_nodes < 0)
			{
				Com_Printf("%s: model %s has %d mesh nodes",
						__func__, mod_name, num_mesh_nodes);
				return NULL;
			}

			o_skins = (long long)sizeof(dmdl_t) +
				(2LL * (long long)sizeof(short) * num_mesh_nodes);
			o_st = o_skins +
				((long long)dmdlheader.num_skins * MAX_SKINNAME);
			o_tris = o_st +
				((long long)dmdlheader.num_st * (long long)sizeof(dstvert_t));
			o_frames = o_tris +
				((long long)dmdlheader.num_tris * (long long)sizeof(dtriangle_t));
			o_glcmds = o_frames +
				((long long)dmdlheader.num_frames * (long long)dmdlheader.framesize);
			o_end = o_glcmds +
				((long long)dmdlheader.num_glcmds * (long long)sizeof(int));

			if ((o_skins > o_st) || (o_st > o_tris) || (o_tris > o_frames) ||
				(o_frames > o_glcmds) || (o_glcmds > o_end) ||
				(o_end > (long long)fmfilelen))
			{
				Com_Printf("%s: model %s has sections that don't fit in its %d bytes",
						__func__, mod_name, fmfilelen);
				return NULL;
			}

			dmdlheader.ofs_skins = (int)o_skins;
			dmdlheader.ofs_st = (int)o_st;
			dmdlheader.ofs_tris = (int)o_tris;
			dmdlheader.ofs_frames = (int)o_frames;
			dmdlheader.ofs_glcmds = (int)o_glcmds;
			dmdlheader.ofs_end = (int)o_end;

			if (!Mod_CheckAliasHeader(mod_name, &dmdlheader))
			{
				return NULL;
			}

			extradata = Hunk_Begin(dmdlheader.ofs_end);
			pheader = Hunk_Alloc(dmdlheader.ofs_end);

			memcpy(pheader, &dmdlheader, sizeof(dmdl_t));
		}
		else {
			if (!pheader)
			{
				Com_Printf("%s: %s has broken header.",
					__func__, mod_name);
				goto fail; /* AC1 */
			}
			else if (Q_strncasecmp(blockname, "skin", sizeof(blockname)) == 0)
			{
				if (version != 1)
				{
					Com_Printf("%s: Invalid %s version %d",
						__func__, blockname, version);
					goto fail; /* AC1 */
				}
				if (size != (pheader->num_skins * MAX_SKINNAME))
				{
					Com_Printf("%s: Invalid %s size",
						__func__, blockname);
					goto fail; /* AC1 */
				}
				memcpy((char*) pheader + pheader->ofs_skins, src, size);
			}
			else if (Q_strncasecmp(blockname, "st coord", sizeof(blockname)) == 0)
			{
				if (version != 1)
				{
					Com_Printf("%s: Invalid %s version %d",
						__func__, blockname, version);
					goto fail; /* AC1 */
				}
				if (size != (pheader->num_st * sizeof(dstvert_t)))
				{
					Com_Printf("%s: Invalid %s size",
						__func__, blockname);
					goto fail; /* AC1 */
				}

				Mod_LoadSTvertList (pheader, (dstvert_t *)src);
			}
			else if (Q_strncasecmp(blockname, "tris", sizeof(blockname)) == 0)
			{
				if (version != 1)
				{
					Com_Printf("%s: Invalid %s version %d",
						__func__, blockname, version);
					goto fail; /* AC1 */
				}
				if (size != (pheader->num_tris * sizeof(dtriangle_t)))
				{
					Com_Printf("%s: Invalid %s size",
						__func__, blockname);
					goto fail; /* AC1 */
				}

				Mod_LoadDTriangleList (pheader, (dtriangle_t *) src);
			}
			else if (Q_strncasecmp(blockname, "frames", sizeof(blockname)) == 0)
			{
				vec3_t translate = {0, 0, 0};

				if (version != 1)
				{
					Com_Printf("%s: Invalid %s version %d",
						__func__, blockname, version);
					goto fail; /* AC1 */
				}
				if (size != (pheader->num_frames * pheader->framesize))
				{
					Com_Printf("%s: Invalid %s size",
						__func__, blockname);
					goto fail; /* AC1 */
				}

				Mod_LoadFrames (pheader, (byte *)src, translate);
			}
			else if (Q_strncasecmp(blockname, "glcmds", sizeof(blockname)) == 0)
			{
				if (version != 1)
				{
					Com_Printf("%s: Invalid %s version %d",
						__func__, blockname, version);
					goto fail; /* AC1 */
				}
				if (size != (pheader->num_glcmds * sizeof(int)))
				{
					Com_Printf("%s: Invalid %s size",
						__func__, blockname);
					goto fail; /* AC1 */
				}

				Mod_LoadCmdList (mod_name, pheader, (int *)src);
			}
			else if (Q_strncasecmp(blockname, "mesh nodes", sizeof(blockname)) == 0)
			{
				int num_mesh_nodes;

				num_mesh_nodes = (pheader->ofs_skins - sizeof(dmdl_t)) / sizeof(short) / 2;

				if (version != 3)
				{
					Com_Printf("%s: Invalid %s version %d",
						__func__, blockname, version);
					goto fail; /* AC1 */
				}
				/* 516 mesh node size */
				if ((long long)size != ((long long)num_mesh_nodes * 516))
				{
					Com_Printf("%s: Invalid %s size",
						__func__, blockname);
					goto fail; /* AC1 */
				}

				if (num_mesh_nodes > 0)
				{
					short *mesh_nodes;
					char *in_mesh = src;
					int i;

					mesh_nodes = (short *)((char*)pheader + sizeof(dmdl_t));
					for (i = 0; i < num_mesh_nodes; i++)
					{
						/* 256 bytes of tri data */
						/* 256 bytes of vert data */
						/* 2 bytes of start */
						/* 2 bytes of number commands */
						in_mesh += 512;
						mesh_nodes[i * 2] = LittleShort(*(short *)in_mesh);
						in_mesh += 2;
						mesh_nodes[i * 2 + 1] = LittleShort(*(short *)in_mesh);
						in_mesh += 2;
					}
				}
			}
			else if (Q_strncasecmp(blockname, "normals", sizeof(blockname)) == 0 ||
					 Q_strncasecmp(blockname, "short frames", sizeof(blockname)) == 0 ||
					 Q_strncasecmp(blockname, "comp data", sizeof(blockname)) == 0 ||
					 Q_strncasecmp(blockname, "skeleton", sizeof(blockname)) == 0 ||
					 Q_strncasecmp(blockname, "references", sizeof(blockname)) == 0)
			{
				/* skipped block */
			}
			else
			{
				Com_Printf("%s: %s Unknown block %s\n",
					__func__, mod_name, blockname);
				goto fail; /* AC1 */
			}
		}
		modfilelen -= size;
		src += size;
	}

	if (pheader->num_skins > MAX_MD2SKINS)
	{
		Com_Printf("%s has too many skins (%i > %i), "
				"extra skins will be ignored\n",
				mod_name, pheader->num_skins, MAX_MD2SKINS);
		pheader->num_skins = MAX_MD2SKINS;
	}

	// Load in our skins.
	for (i=0; i < pheader->num_skins; i++)
	{
		skins[i] = find_image((char *)pheader + pheader->ofs_skins + i*MAX_SKINNAME,
			it_skin);
	}

	*type = mod_alias;

	mins[0] = -32;
	mins[1] = -32;
	mins[2] = -32;
	maxs[0] = 32;
	maxs[1] = 32;
	maxs[2] = 32;
	return extradata;

	/* AC1: every rejection in the block loop above runs after
	   Hunk_Begin(); the half-built model hunk has to go back or
	   each rejected .fm orphans its mapping (the Z4 retry path
	   takes Mod_Free's !extradata branch, which never sees the
	   pointer).  The header records the full reservation (Z4), so
	   Hunk_Free() is correct at any point of the load. */
fail:
	Hunk_Free(extradata);
	return NULL;
}

static void *
Mod_LoadDKMModel(const char *mod_name, const void *buffer, int modfilelen,
	vec3_t mins, vec3_t maxs, struct image_s **skins, findimage_t find_image,
	modtype_t *type)
{
	dmdl_t dmdlheader, *pheader = NULL;
	dkm_header_t header = {0};
	void *extradata = NULL;
	int i;

	/* Z6: the header below is read before any of its counts are
	   trusted, so the file has to carry it */
	if (sizeof(dkm_header_t) > modfilelen)
	{
		Com_Printf("%s: model %s file size(%d) too small",
				__func__, mod_name, modfilelen);
		return NULL;
	}

	// byte swap the header fields and sanity check
	for (i=0 ; i<sizeof(dkm_header_t)/sizeof(int) ; i++)
		((int *)&header)[i] = LittleLong (((int *)buffer)[i]);

	if (header.ident != DKMHEADER)
	{
		Com_Printf("%s: %s has wrong ident (%i should be %i)",
				__func__, mod_name, header.ident, DKMHEADER);
		return NULL;
	}

	if (header.version != DKM1_VERSION && header.version != DKM2_VERSION)
	{
		Com_Printf("%s: %s has wrong version number (%i should be %i)",
				__func__, mod_name, header.version, DKM2_VERSION);
		return NULL;
	}

	if (header.ofs_end < 0 || header.ofs_end > modfilelen)
	{
		Com_Printf("%s: model %s file size(%d) too small, should be %d",
				__func__, mod_name, modfilelen, header.ofs_end);
		return NULL;
	}

	/* copy back all values */
	dmdlheader.ident = IDALIASHEADER;
	dmdlheader.version = ALIAS_VERSION;
	dmdlheader.skinwidth = 256;
	dmdlheader.skinheight = 256;
	if (header.version != DKM2_VERSION)
	{
		/* has same frame structure */
		dmdlheader.framesize = header.framesize;
	}
	else
	{
		dmdlheader.framesize = sizeof(daliasframe_t) - sizeof(dtrivertx_t);
		dmdlheader.framesize += header.num_xyz * sizeof(dtrivertx_t);
	}

	dmdlheader.num_skins = header.num_skins;
	dmdlheader.num_xyz = header.num_xyz;
	dmdlheader.num_st = header.num_st;
	dmdlheader.num_tris = header.num_tris;
	dmdlheader.num_glcmds = header.num_glcmds;
	dmdlheader.num_frames = header.num_frames;

	/* Z6: as in Mod_LoadMD2, the layout below sizes the model block
	   and every part of it is copied from the same place in the file,
	   so the offsets are built in 64 bit, have to grow monotonically
	   (a negative count would shrink one) and every source section
	   has to lie inside the file.  Note that the skin names are copied
	   below before the skin count is clamped, so the unclamped count
	   is what has to fit in both the file and the model here. */
	{
		long long o_skins, o_st, o_tris, o_frames, o_glcmds, o_end;
		long long s_skins, s_st, s_tris, s_frames, s_glcmds;

		o_skins = (long long)sizeof(dmdl_t);
		o_st = o_skins +
			((long long)dmdlheader.num_skins * MAX_SKINNAME);
		o_tris = o_st +
			((long long)dmdlheader.num_st * (long long)sizeof(dstvert_t));
		o_frames = o_tris +
			((long long)dmdlheader.num_tris * (long long)sizeof(dtriangle_t));
		o_glcmds = o_frames +
			((long long)dmdlheader.num_frames * (long long)dmdlheader.framesize);
		o_end = o_glcmds +
			((long long)dmdlheader.num_glcmds * (long long)sizeof(int));

		if ((o_skins > o_st) || (o_st > o_tris) || (o_tris > o_frames) ||
			(o_frames > o_glcmds) || (o_glcmds > o_end) ||
			(o_end > 0x7fffffffLL))
		{
			Com_Printf("%s: model %s has sections that don't fit a model block",
					__func__, mod_name);
			return NULL;
		}

		dmdlheader.ofs_skins = (int)o_skins;
		dmdlheader.ofs_st = (int)o_st;
		dmdlheader.ofs_tris = (int)o_tris;
		dmdlheader.ofs_frames = (int)o_frames;
		dmdlheader.ofs_glcmds = (int)o_glcmds;
		dmdlheader.ofs_end = (int)o_end;

		if (!Mod_CheckAliasHeader(mod_name, &dmdlheader))
		{
			return NULL;
		}

		/* AF1: a v2 frame is read as the 40 byte name/scale/translate
		   head plus five bytes per vertex (a packed dword and a light
		   byte), while the frames section is sized by the file's own
		   framesize.  CheckAliasHeader only ever proves the model's
		   (recomputed) stride carries four bytes per vertex, so a v2
		   file may claim a framesize shorter than its frames really
		   are, and the last frame's vertex reads run past the frames
		   section - up to num_xyz bytes past the section end, which
		   is past the file end when the section ends the file.  The
		   v2 stride itself has to carry the v2 vertices. */
		if ((header.version == DKM2_VERSION) &&
			((long long)header.framesize <
				((long long)sizeof(daliasframe_t) -
					(long long)sizeof(dtrivertx_t)) +
				(5LL * (long long)header.num_xyz)))
		{
			Com_Printf("%s: model %s has v2 framesize %d for %d vertices",
					__func__, mod_name, header.framesize, header.num_xyz);
			return NULL;
		}

		s_skins = (long long)header.ofs_skins +
			((long long)header.num_skins * MAX_SKINNAME);
		s_st = (long long)header.ofs_st +
			((long long)header.num_st * (long long)sizeof(dstvert_t));
		s_tris = (long long)header.ofs_tris +
			((long long)header.num_tris * (long long)sizeof(dkmtriangle_t));
		s_frames = (long long)header.ofs_frames +
			((long long)header.num_frames * (long long)header.framesize);
		s_glcmds = (long long)header.ofs_glcmds +
			((long long)header.num_glcmds * (long long)sizeof(int));

		if ((header.ofs_skins < 0) || (s_skins > modfilelen) ||
			(header.ofs_st < 0) || (s_st > modfilelen) ||
			(header.ofs_tris < 0) || (s_tris > modfilelen) ||
			(header.ofs_frames < 0) || (s_frames > modfilelen) ||
			(header.ofs_glcmds < 0) || (s_glcmds > modfilelen))
		{
			Com_Printf("%s: model %s has sections outside its %d bytes",
					__func__, mod_name, modfilelen);
			return NULL;
		}
	}

	/* AC1: audit: this loader has no return-NULL exit between
	   Hunk_Begin() and its success return, except the AF1 glcmd
	   failure below, which is the one post-allocation exit and
	   hands the mapping back with Hunk_Free like the MDL/flex
	   fail: paths do. */
	extradata = Hunk_Begin(dmdlheader.ofs_end);
	pheader = Hunk_Alloc(dmdlheader.ofs_end);
	memcpy(pheader, &dmdlheader, sizeof(dmdl_t));

	memcpy ((byte*)pheader + pheader->ofs_skins, (byte *)buffer + header.ofs_skins,
		pheader->num_skins * MAX_SKINNAME);
	Mod_LoadSTvertList (pheader,
		(dstvert_t *)((byte *)buffer + header.ofs_st));
	if (!Mod_LoadDKMCmdList (mod_name, pheader,
		(int *)((byte *)buffer + header.ofs_glcmds)))
	{
		Hunk_Free(extradata);
		return NULL;
	}
	if (header.version == DKM1_VERSION)
	{
		Mod_LoadFrames (pheader, (byte *)buffer + header.ofs_frames,
			header.translate);
	}
	else
	{
		Mod_LoadDkmFrames (pheader, (byte *)buffer + header.ofs_frames,
			header.framesize, header.translate);
	}

	Mod_LoadDkmTriangleList (pheader,
		(dkmtriangle_t *)((byte *)buffer + header.ofs_tris));

	if (pheader->num_skins > MAX_MD2SKINS)
	{
		Com_Printf("%s has too many skins (%i > %i), "
				"extra skins will be ignored\n",
				mod_name, pheader->num_skins, MAX_MD2SKINS);
		pheader->num_skins = MAX_MD2SKINS;
	}

	// Load in our skins.
	for (i=0; i < pheader->num_skins; i++)
	{
		skins[i] = find_image((char *)pheader + pheader->ofs_skins + i*MAX_SKINNAME,
			it_skin);
	}

	*type = mod_alias;

	mins[0] = -32;
	mins[1] = -32;
	mins[2] = -32;
	maxs[0] = 32;
	maxs[1] = 32;
	maxs[2] = 32;

	return extradata;
}

/*
=================
Mod_LoadAliasModel
=================
*/
void *
Mod_LoadAliasModel (const char *mod_name, const void *buffer, int modfilelen,
	vec3_t mins, vec3_t maxs, struct image_s **skins, findimage_t find_image,
	modtype_t *type)
{
	/* AE6: the ident read pulls four bytes out of the buffer, and
	   the host's load_model_file() admits any file with size > 0;
	   shorter than the ident there is nothing to dispatch on. */
	if (modfilelen < (int)sizeof(int))
	{
		Com_Printf("%s: model %s is %d bytes, less than its ident",
				__func__, mod_name, modfilelen);
		return NULL;
	}

	switch (LittleLong(*(unsigned *)buffer))
	{
		case DKMHEADER:
			return Mod_LoadDKMModel(mod_name, buffer, modfilelen, mins, maxs, skins,
				find_image, type);

		case RAVENFMHEADER:
			return Mod_LoadFlexModel(mod_name, buffer, modfilelen, mins, maxs, skins,
				find_image, type);

		case IDALIASHEADER:
			return Mod_LoadMD2(mod_name, buffer, modfilelen, mins, maxs, skins,
				find_image, type);

		case IDMDLHEADER:
			return Mod_LoadMDL(mod_name, buffer, modfilelen, mins, maxs, skins,
				find_image, type);
	}

	return NULL;
}


/*
==============================================================================

SPRITE MODELS

==============================================================================
*/

/*
=================
Mod_LoadSP2

support for .sp2 sprites
=================
*/
void *
Mod_LoadSP2 (const char *mod_name, const void *buffer, int modfilelen,
	struct image_s **skins, findimage_t find_image, modtype_t *type)
{
	dsprite_t *sprin, *sprout;
	void	*extradata;
	int version, numframes;
	int i;

	sprin = (dsprite_t *)buffer;

	/* Z6: the header is read before it is trusted, so the file has to
	   be able to carry it plus one frame */
	if (modfilelen < (int)sizeof(dsprite_t))
	{
		Com_Printf("%s is %d bytes, less than its header\n",
				mod_name, modfilelen);
		return NULL;
	}

	version = LittleLong(sprin->version);
	numframes = LittleLong(sprin->numframes);

	if (version != SPRITE_VERSION)
	{
		Com_Printf("%s has wrong version number (%i should be %i)",
				mod_name, version, SPRITE_VERSION);
		return NULL;
	}

	/* frames past the model's frame limit are ignored below, so only
	   the ones that are read have to be in the file */
	if (numframes > MAX_MD2SKINS)
	{
		Com_Printf("%s has too many frames (%i > %i), "
				"extra frames will be ignored\n",
				mod_name, numframes, MAX_MD2SKINS);
		numframes = MAX_MD2SKINS;
	}

	/* Z6: the frame array is indexed numframes times in both the file
	   and the model copy, and every frame is registered as a skin, so
	   the file has to hold all of them and the count has to be usable */
	if ((numframes <= 0) ||
		((long long)(sizeof(dsprite_t) - sizeof(dsprframe_t)) +
			((long long)numframes * (long long)sizeof(dsprframe_t)) >
			(long long)modfilelen))
	{
		Com_Printf("%s claims %d frames of %d bytes, file is %d bytes\n",
				mod_name, numframes, (int)sizeof(dsprframe_t), modfilelen);
		return NULL;
	}

	/* AC1: audit: this loader has no return-NULL exit between
	   Hunk_Begin() and its success return, so there is no
	   post-allocation path to free here. */
	extradata = Hunk_Begin(modfilelen);
	sprout = Hunk_Alloc(modfilelen);

	sprout->ident = LittleLong(sprin->ident);
	sprout->version = version;
	sprout->numframes = numframes;

	/* byte swap everything */
	for (i = 0; i < sprout->numframes; i++)
	{
		sprout->frames[i].width = LittleLong(sprin->frames[i].width);
		sprout->frames[i].height = LittleLong(sprin->frames[i].height);
		sprout->frames[i].origin_x = LittleLong(sprin->frames[i].origin_x);
		sprout->frames[i].origin_y = LittleLong(sprin->frames[i].origin_y);
		memcpy(sprout->frames[i].name, sprin->frames[i].name, MAX_SKINNAME);

		skins[i] = find_image((char *)sprout->frames[i].name, it_sprite);
		if (!skins[i])
		{
			/* heretic2 sprites have no "sprites/" prefix */
			snprintf(sprout->frames[i].name, MAX_SKINNAME,
				"sprites/%s", sprin->frames[i].name);
			skins[i] = find_image(sprout->frames[i].name, it_sprite);
		}
	}

	*type = mod_sprite;

	return extradata;
}

/*
=================
Mod_LoadFile
=================
*/
int
Mod_LoadFile(char *name, void **buffer)
{
	const char* ext;

	*buffer = NULL;

	if (!name)
	{
		return -1;
	}

	ext = COM_FileExtension(name);
	if(!ext[0])
	{
		/* file has no extension */
		return -1;
	}

	if (!strcmp(ext, "fm") ||
		!strcmp(ext, "dkm") ||
		!strcmp(ext, "md2") ||
		!strcmp(ext, "mdl"))
	{
		char namewe[256], newname[256];
		int filesize, len;

		len = strlen(name);
		if (len < 5)
		{
			return -1;
		}

		/* Remove the extension */
		size_t tlen = len - (strlen(ext) + 1);
		memset(namewe, 0, 256);
		memcpy(namewe, name, tlen);

		/* Check Heretic2 model */
		Q_strlcpy(newname, namewe, sizeof(newname));
		Q_strlcat(newname, ".fm", sizeof(newname));
		filesize = ri.FS_LoadFile (newname, buffer);
		if (filesize > 0)
		{
			return filesize;
		}

		/* Check Quake 2 model */
		Q_strlcpy(newname + tlen, ".md2", sizeof(newname));
		filesize = ri.FS_LoadFile (newname, buffer);
		if (filesize > 0)
		{
			return filesize;
		}

		/* Check Daikatana model */
		Q_strlcpy(newname + tlen, ".dkm", sizeof(newname));
		filesize = ri.FS_LoadFile (newname, buffer);
		if (filesize > 0)
		{
			return filesize;
		}

		/* Check Quake model */
		Q_strlcpy(newname + tlen, ".mdl", sizeof(newname));
		filesize = ri.FS_LoadFile (newname, buffer);
		if (filesize > 0)
		{
			return filesize;
		}
	}
	return ri.FS_LoadFile (name, buffer);
}

/*
=================
Mod_ReLoad

Reload images in SP2/MD2 (mark registration_sequence)
=================
*/
int
Mod_ReLoadSkins(struct image_s **skins, findimage_t find_image, void *extradata,
	modtype_t type)
{
	if (type == mod_sprite)
	{
		dsprite_t	*sprout;
		int	i;

		sprout = (dsprite_t *)extradata;
		for (i=0; i < sprout->numframes; i++)
		{
			skins[i] = find_image(sprout->frames[i].name, it_sprite);
		}
		return sprout->numframes;
	}
	else if (type == mod_alias)
	{
		dmdl_t *pheader;
		int	i;

		pheader = (dmdl_t *)extradata;
		for (i=0; i < pheader->num_skins; i++)
		{
			skins[i] = find_image ((char *)pheader + pheader->ofs_skins + i*MAX_SKINNAME, it_skin);
		}
		return  pheader->num_frames;
	}
	/* Unknow format, no images associated with it */
	return 0;
}

/*
=================
Mod_SetParent
=================
*/
static void
Mod_SetParent(mnode_t *node, mnode_t *parent)
{
	node->parent = parent;
	if (node->contents != CONTENTS_NODE)
	{
		return;
	}

	Mod_SetParent (node->children[0], node);
	Mod_SetParent (node->children[1], node);
}

/*
=================
Mod_NumberLeafs
=================
*/
static void
Mod_NumberLeafs(mleaf_t *leafs, mnode_t *node, int *r_leaftovis, int *r_vistoleaf,
	int *numvisleafs)
{
	if (node->contents != CONTENTS_NODE)
	{
		mleaf_t *leaf;
		int leafnum;

		leaf = (mleaf_t *)node;
		leafnum = leaf - leafs;
		if (leaf->contents & CONTENTS_SOLID)
		{
			return;
		}

		r_leaftovis[leafnum] = *numvisleafs;
		r_vistoleaf[*numvisleafs] = leafnum;
		(*numvisleafs) ++;
		return;
	}

	Mod_NumberLeafs(leafs, node->children[0], r_leaftovis, r_vistoleaf,
		numvisleafs);
	Mod_NumberLeafs(leafs, node->children[1], r_leaftovis, r_vistoleaf,
		numvisleafs);
}

/*
=================
Mod_LoadNodes
=================
*/
void
Mod_LoadNodes(const char *name, cplane_t *planes, int numplanes, mleaf_t *leafs,
	int numleafs, mnode_t **nodes, int *numnodes, const byte *mod_base,
	const lump_t *l)
{
	int	r_leaftovis[MAX_MAP_LEAFS], r_vistoleaf[MAX_MAP_LEAFS];
	int	i, count, numvisleafs;
	dnode_t	*in;
	mnode_t	*out;

	in = (void *)(mod_base + l->fileofs);

	if (l->filelen % sizeof(*in))
	{
		ri.Sys_Error(ERR_DROP, "%s: funny lump size in %s",
				__func__, name);
	}

	count = l->filelen / sizeof(*in);
	out = Hunk_Alloc(count * sizeof(*out));

	*nodes = out;
	*numnodes = count;

	for (i = 0; i < count; i++, in++, out++)
	{
		int j, planenum;

		for (j = 0; j < 3; j++)
		{
			out->minmaxs[j] = LittleShort(in->mins[j]);
			out->minmaxs[3 + j] = LittleShort(in->maxs[j]);
		}

		planenum = LittleLong(in->planenum);
		if (planenum  < 0 || planenum >= numplanes)
		{
			ri.Sys_Error(ERR_DROP, "%s: Incorrect %d < %d planenum.",
					__func__, planenum, numplanes);
		}
		out->plane = planes + planenum;

		out->firstsurface = LittleShort(in->firstface);
		out->numsurfaces = LittleShort(in->numfaces);
		out->contents = CONTENTS_NODE; /* differentiate from leafs */

		for (j = 0; j < 2; j++)
		{
			int leafnum;

			leafnum = LittleLong(in->children[j]);

			if (leafnum >= 0)
			{
				if (leafnum  < 0 || leafnum >= *numnodes)
				{
					ri.Sys_Error(ERR_DROP, "%s: Incorrect %d nodenum as leaf.",
							__func__, leafnum);
				}

				out->children[j] = *nodes + leafnum;
			}
			else
			{
				leafnum = -1 - leafnum;
				if (leafnum  < 0 || leafnum >= numleafs)
				{
					ri.Sys_Error(ERR_DROP, "%s: Incorrect %d leafnum.",
							__func__, leafnum);
				}

				out->children[j] = (mnode_t *)(leafs + leafnum);
			}
		}
	}

	Mod_SetParent(*nodes, NULL); /* sets nodes and leafs */

	numvisleafs = 0;
	Mod_NumberLeafs (leafs, *nodes, r_leaftovis, r_vistoleaf, &numvisleafs);
}

/*
=================
Mod_LoadVisibility
=================
*/
void
Mod_LoadVisibility (dvis_t **vis, const byte *mod_base, const lump_t *l)
{
	dvis_t	*out;
	int	i;

	if (!l->filelen)
	{
		*vis = NULL;
		return;
	}

	out = Hunk_Alloc(l->filelen);
	*vis = out;
	memcpy(out, mod_base + l->fileofs, l->filelen);

	out->numclusters = LittleLong(out->numclusters);

	/* Z5c: the cluster table must fit the lump before the swap loop
	   touches it; past the end of the hunk allocation the loop reads
	   and writes outside the visibility image. */
	if ((out->numclusters < 0) ||
		(4 + (long long)out->numclusters * 8 > l->filelen))
	{
		ri.Sys_Error(ERR_DROP, "%s: %i byte visibility lump cannot hold "
				"%i clusters", __func__, l->filelen, out->numclusters);
	}

	for (i = 0; i < out->numclusters; i++)
	{
		out->bitofs[i][0] = LittleLong(out->bitofs[i][0]);
		out->bitofs[i][1] = LittleLong(out->bitofs[i][1]);

		/* Z5c: the bit offsets are byte offsets into this same lump;
		   Mod_ClusterPvs adds them to the lump base, so they must stay
		   inside it. */
		if ((out->bitofs[i][0] < 0) || (out->bitofs[i][0] > l->filelen) ||
			(out->bitofs[i][1] < 0) || (out->bitofs[i][1] > l->filelen))
		{
			ri.Sys_Error(ERR_DROP, "%s: cluster %i PVS bit offset %i is "
					"not inside the %i byte visibility lump",
					__func__, i,
					(out->bitofs[i][0] < 0 || out->bitofs[i][0] > l->filelen)
						? out->bitofs[i][0] : out->bitofs[i][1],
					l->filelen);
		}
	}
}

/*
=================
Mod_LoadVertexes

extra for skybox
=================
*/
void
Mod_LoadVertexes(const char *name, mvertex_t **vertexes, int *numvertexes,
	const byte *mod_base, const lump_t *l, int extra)
{
	dvertex_t	*in;
	mvertex_t	*out;
	int	i, count;

	in = (void *)(mod_base + l->fileofs);

	if (l->filelen % sizeof(*in))
	{
		ri.Sys_Error(ERR_DROP, "%s: funny lump size in %s",
				__func__, name);
	}

	count = l->filelen / sizeof(*in);
	out = Hunk_Alloc((count + extra)*sizeof(*out));

	/*
	 * FIXME: Recheck with soft render
	 * Fix for the problem where the games dumped core
	 * when changing levels.
	 */
	memset(out, 0, (count + extra) * sizeof(*out));

	*vertexes = out;
	*numvertexes = count;

	for (i = 0; i < count; i++, in++, out++)
	{
		out->position[0] = LittleFloat(in->point[0]);
		out->position[1] = LittleFloat(in->point[1]);
		out->position[2] = LittleFloat(in->point[2]);
	}
}

/*
=================
Mod_LoadLighting
=================
*/
void
Mod_LoadLighting(byte **lightdata, const byte *mod_base, const lump_t *l)
{
	int	size;

	if (!l->filelen)
	{
		*lightdata = NULL;
		return;
	}

	size = l->filelen;
	*lightdata = Hunk_Alloc(size);
	memcpy(*lightdata, mod_base + l->fileofs, size);
}

/*
=================
Mod_LoadTexinfo

extra for skybox in soft render
=================
*/
void
Mod_LoadTexinfo(const char *name, mtexinfo_t **texinfo, int *numtexinfo,
	const byte *mod_base, const lump_t *l, findimage_t find_image,
	struct image_s *notexture, int extra)
{
	texinfo_t *in;
	mtexinfo_t *out, *step;
	int 	i, count;

	in = (void *)(mod_base + l->fileofs);

	if (l->filelen % sizeof(*in))
	{
		ri.Sys_Error(ERR_DROP, "%s: funny lump size in %s",
				__func__, name);
	}

	count = l->filelen / sizeof(*in);
	out = Hunk_Alloc((count + extra)*sizeof(*out));

	*texinfo = out;
	*numtexinfo = count;

	for ( i=0 ; i<count ; i++, in++, out++)
	{
		struct image_s *image;
		int j, next;

		for (j = 0; j < 4; j++)
		{
			out->vecs[0][j] = LittleFloat(in->vecs[0][j]);
			out->vecs[1][j] = LittleFloat(in->vecs[1][j]);
		}

		out->flags = LittleLong (in->flags);

		next = LittleLong (in->nexttexinfo);

		/* Z5e: next indexes this texinfo array; at or past the end it
		   turns into an out-of-array pointer the walk below follows
		   (b_texnext).  Only 0/-1 mean "end of chain"; other negatives
		   are garbage. */
		if ((next >= count) || (next < -1))
		{
			ri.Sys_Error(ERR_DROP, "%s: %s texinfo %i animates to frame %i "
					"outside the %i loaded frames",
					__func__, name, i, next, count);
		}

		if (next > 0)
		{
			out->next = *texinfo + next;
		}
		else
		{
			/*
			 * Fix for the problem where the game
			 * domed core when loading a new level.
			 */
			out->next = NULL;
		}

		image = GetTexImage(in->texture, find_image);
		if (!image)
		{
			Com_Printf("%s: Couldn't load %s\n",
				__func__, in->texture);
			image = notexture;
		}

		out->image = image;
	}

	// count animation frames
	for (i=0 ; i<count ; i++)
	{
		int steps = 0;

		out = (*texinfo) + i;
		out->numframes = 1;
		for (step = out->next ; step && step != out ; step=step->next)
		{
			out->numframes++;

			/* Z5e: with next bounded to the array above, a chain that
			   neither ends (next <= 0) nor returns to its start loops
			   through other entries forever (b_texcycle).  A closed
			   chain visits at most count entries, so more steps than
			   that is an unterminated loop: reject instead of spinning. */
			if (++steps > count)
			{
				ri.Sys_Error(ERR_DROP, "%s: %s texinfo %i animation chain "
						"does not close within %i frames",
						__func__, name, i, count);
			}
		}
	}
}

/*
=================
Mod_LoadEdges

extra is used for skybox, which adds 6 surfaces
=================
*/
void
Mod_LoadEdges(const char *name, medge_t **edges, int *numedges,
	const byte *mod_base, const lump_t *l, int extra)
{
	dedge_t *in;
	medge_t *out;
	int 	i, count;

	in = (void *)(mod_base + l->fileofs);
	if (l->filelen % sizeof(*in))
	{
		ri.Sys_Error(ERR_DROP, "%s: funny lump size in %s",
				__func__, name);
	}

	count = l->filelen / sizeof(*in);
	out = Hunk_Alloc((count + extra) * sizeof(*out));

	*edges = out;
	*numedges = count;

	for ( i=0 ; i<count ; i++, in++, out++)
	{
		out->v[0] = (unsigned short)LittleShort(in->v[0]);
		out->v[1] = (unsigned short)LittleShort(in->v[1]);
	}
}

/*
=================
Mod_LoadPlanes

extra is used for skybox, which adds 6 surfaces
=================
*/
void
Mod_LoadPlanes(const char *name, cplane_t **planes, int *numplanes,
	const byte *mod_base, const lump_t *l, int extra)
{
	int i;
	cplane_t	*out;
	dplane_t 	*in;
	int			count;

	in = (void *)(mod_base + l->fileofs);

	if (l->filelen % sizeof(*in))
	{
		ri.Sys_Error(ERR_DROP, "%s: funny lump size in %s",
				__func__, name);
	}

	count = l->filelen / sizeof(*in);
	// FIXME: why double of count
	out = Hunk_Alloc((count * 2 + extra) * sizeof(*out));

	*planes = out;
	*numplanes = count;

	for ( i=0 ; i<count ; i++, in++, out++)
	{
		int bits, j;

		bits = 0;
		for (j=0 ; j<3 ; j++)
		{
			out->normal[j] = LittleFloat (in->normal[j]);
			if (out->normal[j] < 0)
				bits |= 1<<j;
		}

		out->dist = LittleFloat (in->dist);
		out->type = LittleLong (in->type);
		out->signbits = bits;
	}
}

/*
=================
Mod_LoadSurfedges
=================
*/
void
Mod_LoadSurfedges(const char *name, int **surfedges, int *numsurfedges,
	const byte *mod_base, const lump_t *l, int extra)
{
	int		i, count;
	int		*in, *out;

	in = (void *)(mod_base + l->fileofs);

	if (l->filelen % sizeof(*in))
	{
		ri.Sys_Error(ERR_DROP, "%s: funny lump size in %s",
				__func__, name);
	}

	count = l->filelen / sizeof(*in);
	out = Hunk_Alloc((count + extra)*sizeof(*out));	// extra for skybox

	*surfedges = out;
	*numsurfedges = count;

	for ( i=0 ; i<count ; i++)
		out[i] = LittleLong (in[i]);
}

/*
=================
Mod_LoadSurfedges

calculate the size that Hunk_Alloc(), called by Mod_Load*() from Mod_LoadBrushModel(),
will use (=> includes its padding), so we'll know how big the hunk needs to be
extra is used for skybox, which adds 6 surfaces
=================
*/
int
Mod_CalcLumpHunkSize(const lump_t *l, int inSize, int outSize, int extra)
{
	if (l->filelen % inSize)
	{
		// Mod_Load*() will error out on this because of "funny size"
		// don't error out here because in Mod_Load*() it can print the functionname
		// (=> tells us what kind of lump) before shutting down the game
		return 0;
	}

	int count = l->filelen / inSize + extra;
	int size = count * outSize;

	// round to cacheline, like Hunk_Alloc() does
	size = (size + 31) & ~31;
	return size;
}

/*
===============
Mod_PointInLeaf
===============
*/
mleaf_t *
Mod_PointInLeaf(const vec3_t p, mnode_t *node)
{
	if (!node)
	{
		ri.Sys_Error(ERR_DROP, "%s: bad node.", __func__);
		return NULL;
	}

	while (1)
	{
		float d;
		cplane_t *plane;

		if (node->contents != CONTENTS_NODE)
		{
			return (mleaf_t *)node;
		}

		plane = node->plane;
		d = DotProduct(p, plane->normal) - plane->dist;

		if (d > 0)
		{
			node = node->children[0];
		}
		else
		{
			node = node->children[1];
		}
	}

	return NULL; /* never reached */
}
