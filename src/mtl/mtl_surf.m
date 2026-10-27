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
 * =======================================================================
 *
 * Surface generation and drawing
 *
 * =======================================================================
 */

#include <assert.h>

#include "header/mtl.h"

static vec3_t modelorg; /* relative to viewpoint */
msurface_t *r_alpha_surfaces;

#define LIGHTMAP_BYTES 4

#define	BLOCK_WIDTH		128
#define	BLOCK_HEIGHT	128

int		c_visible_lightmaps;
int		c_visible_textures;

typedef struct
{
	int	current_lightmap_texture;

	msurface_t	*lightmap_surfaces[MAX_LIGHTMAPS];

	int			allocated[BLOCK_WIDTH];

	// the lightmap texture data needs to be kept in
	// main memory so texsubimage can update properly
	byte		lightmap_buffer[4*BLOCK_WIDTH*BLOCK_HEIGHT];
} mtllightmapstate_t;

static mtllightmapstate_t mtl_lms;


static void		LM_InitBlock( void );
static void		LM_UploadBlock( qboolean dynamic );
static qboolean	LM_AllocBlock (int w, int h, int *x, int *y);

/*
 * Uploads a w x h lightmap region to texture position (x, y).
 *
 * Two source layouts are supported, matching gl1's two upload paths:
 *   - compact buffer (src_stride != BLOCK_WIDTH*LIGHTMAP_BYTES): src is the
 *     w x h region itself, packed with src_stride bytes per row, starting at
 *     column 0. This is the dynamic-draw path (R_BuildLightMap into a small
 *     temp buffer), equivalent to gl1's glTexSubImage2D(..., light_s,
 *     light_t, smax, tmax, ..., temp).
 *   - full-width buffer (src_stride == BLOCK_WIDTH*LIGHTMAP_BYTES): src is a
 *     BLOCK_WIDTH-wide atlas and the region sits at column x of each row.
 *     This is the load-time path (whole-buffer upload, x = y = 0).
 *
 * The destination offset (x, y) is applied only to MTLRegionMake2D, never to
 * the source pointer for the compact layout.
 */
static byte lmap_stage[BLOCK_WIDTH * BLOCK_HEIGHT * LIGHTMAP_BYTES];

static void
MTL_UploadLightmapRegion(id<MTLTexture> texture, const byte *src, int src_stride,
	int x, int y, int w, int h)
{
	byte	*out;
	size_t	bytesPerRow = (size_t)w * LIGHTMAP_BYTES;
	int		row;

	if (src_stride == BLOCK_WIDTH * LIGHTMAP_BYTES)
	{
		// Full-width atlas: region starts at column x of each row.
		// Fast path when the whole buffer is uploaded (x == 0).
		if (x == 0)
		{
			out = (byte *)src;
		}
		else
		{
			out = lmap_stage;
			for (row = 0; row < h; row++)
			{
				memcpy(out + (size_t)row * bytesPerRow,
				       src + (size_t)(y + row) * src_stride + (size_t)x * LIGHTMAP_BYTES,
				       bytesPerRow);
			}
		}
	}
	else
	{
		// Compact buffer: src is the region, starting at column 0.
		out = lmap_stage;
		for (row = 0; row < h; row++)
		{
			memcpy(out + (size_t)row * bytesPerRow,
			       src + (size_t)row * src_stride, bytesPerRow);
		}
	}

	[texture replaceRegion:MTLRegionMake2D(x, y, w, h)
	        mipmapLevel:0 slice:0 withBytes:out
	        bytesPerRow:bytesPerRow
	        bytesPerImage:w * h * LIGHTMAP_BYTES];
}

/*
=============================================================

	BRUSH MODELS

=============================================================
*/

/*
===============
MTL_DrawPoly

Fan-expand one polygon and draw it with the plain pipeline.
===============
*/
static void MTL_DrawPoly (mtlpoly_t *p, image_t *texture, float *color)
{
	MTL_DrawPolyChain (p, texture->mtl_texture, NULL, color, 1.f, 0.f, false, 0.f, false);
}

//============
//PGM
/*
===============
MTL_DrawFlowingPoly -- version of MTL_DrawPoly that handles scrolling texture
===============
*/
static void
MTL_DrawFlowingPoly(msurface_t *fa, image_t *texture, const float *color)
{
	float scroll;

	scroll = -64 * ((r_newrefdef.time / 40.0) - (int)(r_newrefdef.time / 40.0));
	if (scroll == 0.0)
		scroll = -64.0;

	MTL_DrawPolyChain (fa->polys, texture->mtl_texture, NULL, color, 1.f, scroll, false, 0.f, false);
}

static void
R_DrawTriangleOutlines(void)
{
	mtlstate_t *st = &mtl_state;
	size_t slot;
	dlightvert_t *dst;
	MTLGPUAddress ubo_addr;
	int i, j;

	static const float color[3] = { 1.f, 1.f, 1.f };

	if (!mtl_showtris->value)
	{
		return;
	}

	if (st->encoder == nil || st->pipeline_showtris == nil)
	{
		return;
	}

	slot = st->frame_slot;
	ubo_addr = MTL_EmitViewProjUbo(slot);
	if (ubo_addr == 0)
	{
		return;	/* ring exhausted, skip the outlines */
	}

	[st->encoder setDepthStencilState:st->depth_state_none];
	[st->encoder setRenderPipelineState:st->pipeline_showtris];

	for (i = 0; i < MAX_LIGHTMAPS; i++)
	{
		msurface_t *surf;

		for (surf = mtl_lms.lightmap_surfaces[i]; surf != 0; surf = surf->lightmapchain)
		{
			mtlpoly_t *p;

			for (p = surf->polys; p; p = p->chain)
			{
				/* Fan-expand each triangle into a closed 4-vertex line
				   strip (v0, v(j-1), v(j), v0) - the mtl convention, no
				   index buffers. Metal has no unconnected line-list
				   topology, so each triangle is its own draw (matching
				   the vk showtris path). */
				for (j = 2; j < p->numverts; j++)
				{
					size_t vstart;

					vstart = st->showtris_vertex_offset[slot];
					if (vstart + 4 * sizeof(dlightvert_t) > SHOWTRIS_VERTEX_RING_BYTES)
					{
						goto done;	/* ring exhausted, stop outlining */
					}

					dst = (dlightvert_t *)st->showtris_vertex_buffer[slot].contents + vstart / sizeof(dlightvert_t);
					memcpy(dst->vertex, p->verts[0], sizeof(float) * 3);
					memcpy(dst->color, color, sizeof(float) * 3);
					dst++;
					memcpy(dst->vertex, p->verts[j - 1], sizeof(float) * 3);
					memcpy(dst->color, color, sizeof(float) * 3);
					dst++;
					memcpy(dst->vertex, p->verts[j], sizeof(float) * 3);
					memcpy(dst->color, color, sizeof(float) * 3);
					dst++;
					memcpy(dst->vertex, p->verts[0], sizeof(float) * 3);
					memcpy(dst->color, color, sizeof(float) * 3);
					dst++;
					st->showtris_vertex_offset[slot] += 4 * sizeof(dlightvert_t);

					[st->dlight_vert_table setAddress:st->showtris_vertex_buffer[slot].gpuAddress + vstart atIndex:0];
					[st->dlight_vert_table setAddress:ubo_addr atIndex:1];
					[st->encoder setArgumentTable:st->dlight_vert_table atStages:MTLRenderStageVertex];
					[st->encoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:4];
				}
			}
		}
	}

done:
	/* restore the world-pass encoder state for later draws */
	[st->encoder setDepthStencilState:st->depth_state];
}

static void
R_RenderBrushPoly(msurface_t *fa, const float *modelMatrix, float alpha,
	const entity_t *currententity)
{
	int			maps;
	image_t		*image;
	qboolean is_dynamic = false;
	float		color[4] = { 1.f, 1.f, 1.f, alpha };
	c_brush_polys++;

	image = R_TextureAnimation(currententity, fa->texinfo);

	if (fa->flags & SURF_DRAWTURB)
	{
		color[0] = color[1] = color[2] = mtl_state.inverse_intensity;
		color[3] = 1.f;
		// warp texture, no lightmaps
		EmitWaterPolys(fa, image, modelMatrix, color, alpha == 1.f);
		return;
	}

	//======
	//PGM
	if (fa->texinfo->flags & SURF_FLOWING)
		MTL_DrawFlowingPoly(fa, image, color);
	else
		MTL_DrawPoly(fa->polys, image, color);
	//PGM
	//======

	/*
	** check for lightmap modification
	*/
	for (maps = 0; maps < MAXLIGHTMAPS && fa->styles[maps] != 255; maps++)
	{
		if (r_newrefdef.lightstyles[fa->styles[maps]].white != fa->cached_light[maps])
			goto dynamic;
	}

	// dynamic this frame or dynamic previously
	if (fa->dlightframe == r_framecount)
	{
	dynamic:
		if (mtl_dynamic->value)
		{
			if (!(fa->texinfo->flags & (SURF_SKY | SURF_TRANS33 | SURF_TRANS66 | SURF_WARP)))
			{
				is_dynamic = true;
			}
		}
	}

	if (is_dynamic)
	{
		if ((fa->styles[maps] >= 32 || fa->styles[maps] == 0) && (fa->dlightframe != r_framecount))
		{
			unsigned	temp[34 * 34];
			int			smax, tmax;

			smax = (fa->extents[0] >> fa->lmshift) + 1;
			tmax = (fa->extents[1] >> fa->lmshift) + 1;

			R_BuildLightMap(fa, (void *)temp, smax * 4);
			R_SetCacheState(fa);

			MTL_UploadLightmapRegion(mtl_state.lightmap_textures[fa->lightmaptexturenum],
				(const byte *)temp, smax * LIGHTMAP_BYTES,
				fa->light_s, fa->light_t, smax, tmax);

			fa->lightmapchain = mtl_lms.lightmap_surfaces[fa->lightmaptexturenum];
			mtl_lms.lightmap_surfaces[fa->lightmaptexturenum] = fa;
		}
		else
		{
			fa->lightmapchain = mtl_lms.lightmap_surfaces[0];
			mtl_lms.lightmap_surfaces[0] = fa;
		}
	}
	else
	{
		fa->lightmapchain = mtl_lms.lightmap_surfaces[fa->lightmaptexturenum];
		mtl_lms.lightmap_surfaces[fa->lightmaptexturenum] = fa;
	}
}


/*
================
R_DrawAlphaSurfaces

Draw water surfaces and windows.
The BSP tree is waled front to back, so unwinding the chain
of alpha_surfaces will draw back to front, giving proper ordering.
================
*/
void
R_DrawAlphaSurfaces(void)
{
	msurface_t	*s;
	float		intens;

	// the textures are prescaled up for a better lighting range,
	// so scale it back down
	intens = mtl_state.inverse_intensity;
	float color[4] = { intens, intens, intens, 1.f };

	for (s = r_alpha_surfaces; s; s = s->texturechain)
	{
		c_brush_polys++;
		if (s->texinfo->flags & SURF_TRANS33)
		{
			color[3] = 0.33f;
		}
		else if (s->texinfo->flags & SURF_TRANS66)
		{
			color[3] = 0.66f;
		}

		if (s->flags & SURF_DRAWTURB)
		{
			EmitWaterPolys(s, s->texinfo->image, NULL, color, false);
		}
		else if (s->texinfo->flags & SURF_FLOWING)			// PGM	9/16/98
		{
			MTL_DrawFlowingPoly(s, s->texinfo->image, color);	// PGM
		}
		else
		{
			MTL_DrawPoly(s->polys, s->texinfo->image, color);
		}
	}

	r_alpha_surfaces = NULL;
}

/*
================
DrawTextureChains

Draw world surfaces (mostly solid with alpha == 1.f)
================
*/
static void
DrawTextureChains(entity_t *currententity)
{
	int		i;
	msurface_t	*s;
	image_t		*image;

	c_visible_textures = 0;

	for (i = 0, image = mtltextures; i < nummtltextures; i++, image++)
	{
		if (!image->registration_sequence)
		{
			continue;
		}

		if (!image->texturechain)
		{
			continue;
		}

		c_visible_textures++;

		for (s = image->texturechain; s; s = s->texturechain)
		{
			if (!(s->flags & SURF_DRAWTURB))
			{
				R_RenderBrushPoly(s, NULL, 1.f, currententity);
			}
		}
	}

	for (i = 0, image = mtltextures; i < nummtltextures; i++, image++)
	{
		if (!image->registration_sequence)
		{
			continue;
		}

		s = image->texturechain;
		if (!s)
		{
			continue;
		}

		for (; s; s = s->texturechain)
		{
			if (s->flags & SURF_DRAWTURB)
			{
				R_RenderBrushPoly(s, NULL, 1.f, currententity);
			}
		}

		image->texturechain = NULL;
	}
}


static void
MTL_RenderLightmappedPoly(msurface_t *surf, const float *modelMatrix, float alpha,
	const entity_t *currententity)
{
	int		map;
	image_t *image = R_TextureAnimation(currententity, surf->texinfo);
	qboolean is_dynamic = false;
	unsigned lmtex = surf->lightmaptexturenum;
	float		model[16];
	float		color[4] = { 1.f, 1.f, 1.f, alpha };
	float		scroll = 0.f;

	if (modelMatrix)
	{
		memcpy(model, modelMatrix, sizeof(float) * 16);
	}
	else
	{
		Mat_Identity(model);
	}

	for (map = 0; map < MAXLIGHTMAPS && surf->styles[map] != 255; map++)
	{
		if (r_newrefdef.lightstyles[surf->styles[map]].white != surf->cached_light[map])
			goto dynamic;
	}

	/* dynamic this frame or dynamic previously */
	if (surf->dlightframe == r_framecount)
	{
	dynamic:
		if (mtl_dynamic->value)
		{
			if (!(surf->texinfo->flags & (SURF_SKY | SURF_TRANS33 | SURF_TRANS66 | SURF_WARP)))
			{
				is_dynamic = true;
			}
		}
	}

	if (is_dynamic)
	{
		unsigned	temp[128 * 128];
		int			smax, tmax;

		smax = (surf->extents[0] >> surf->lmshift) + 1;
		tmax = (surf->extents[1] >> surf->lmshift) + 1;

		R_BuildLightMap(surf, (void *)temp, smax * 4);

		if ((surf->styles[map] >= 32 || surf->styles[map] == 0) && (surf->dlightframe != r_framecount))
		{
			R_SetCacheState(surf);

			lmtex = surf->lightmaptexturenum;
			MTL_UploadLightmapRegion(mtl_state.lightmap_textures[surf->lightmaptexturenum],
				(const byte *)temp, smax * LIGHTMAP_BYTES,
				surf->light_s, surf->light_t, smax, tmax);
		}
		else
		{
			lmtex = surf->lightmaptexturenum + DYNLIGHTMAP_OFFSET;
			MTL_UploadLightmapRegion(mtl_state.lightmap_textures[lmtex],
				(const byte *)temp, smax * LIGHTMAP_BYTES,
				surf->light_s, surf->light_t, smax, tmax);
		}

		c_brush_polys++;
	}
	else
	{
		c_brush_polys++;
	}

	//==========
	//PGM: flowing lightmapped surfaces scroll the surface uv (not the
	//lmap uv), matching the gl3/vk shader.
	if (surf->texinfo->flags & SURF_FLOWING)
	{
		scroll = -64 * ((r_newrefdef.time / 40.0) - (int)(r_newrefdef.time / 40.0));
		if (scroll == 0.0)
			scroll = -64.0;
	}
	//PGM
	//==========

	MTL_DrawLightmappedChain(surf->polys, image->mtl_texture,
		mtl_state.lightmap_textures[lmtex], model, color, scroll);
}

static void
R_DrawInlineBModel(entity_t *currententity, const model_t *currentmodel, float *modelMatrix)
{
	int i;
	msurface_t *psurf;
	float		alpha = 1.f;

	// calculate dynamic lighting for bmodel
	if (!mtl_flashblend->value)
	{
		dlight_t	*lt;
		int	k;

		lt = r_newrefdef.dlights;
		for (k = 0; k<r_newrefdef.num_dlights; k++, lt++)
		{
			R_MarkLights(lt, 1 << k,
				currentmodel->nodes + currentmodel->firstnode,
				r_dlightframecount, R_MarkSurfaceLights);
		}
	}

	psurf = &currentmodel->surfaces[currentmodel->firstmodelsurface];

	if (currententity->flags & RF_TRANSLUCENT)
	{
		alpha = .25f;
	}

	/* draw texture */
	for (i = 0; i < currentmodel->nummodelsurfaces; i++, psurf++)
	{
		cplane_t *pplane;
		float dot;

		/* find which side of the node we are on */
		pplane = psurf->plane;

		dot = DotProduct(modelorg, pplane->normal) - pplane->dist;

		/* draw the polygon */
		if (((psurf->flags & SURF_PLANEBACK) && (dot < -BACKFACE_EPSILON)) ||
			(!(psurf->flags & SURF_PLANEBACK) && (dot > BACKFACE_EPSILON)))
		{
			if (psurf->texinfo->flags & (SURF_TRANS33 | SURF_TRANS66))
			{	// add to the translucent chain
				psurf->texturechain = r_alpha_surfaces;
				r_alpha_surfaces = psurf;
			}
			else if (!(psurf->flags & SURF_DRAWTURB) && !mtl_showtris->value)
			{
				MTL_RenderLightmappedPoly(psurf, modelMatrix, alpha, currententity);
			}
			else
			{
				R_RenderBrushPoly(psurf, modelMatrix, alpha, currententity);
			}
		}
	}
}

void
R_DrawBrushModel(entity_t *currententity, const model_t *currentmodel)
{
	vec3_t mins, maxs;
	qboolean rotated;
	float model[16];

	if (currentmodel->nummodelsurfaces == 0)
	{
		return;
	}

	if (currententity->angles[0] || currententity->angles[1] || currententity->angles[2])
	{
		int	i;

		rotated = true;

		for (i = 0; i < 3; i++)
		{
			mins[i] = currententity->origin[i] - currentmodel->radius;
			maxs[i] = currententity->origin[i] + currentmodel->radius;
		}
	}
	else
	{
		rotated = false;
		VectorAdd(currententity->origin, currentmodel->mins, mins);
		VectorAdd(currententity->origin, currentmodel->maxs, maxs);
	}

	if (r_cull->value && R_CullBox(mins, maxs, frustum))
	{
		return;
	}

	memset(mtl_lms.lightmap_surfaces, 0, sizeof(mtl_lms.lightmap_surfaces));

	VectorSubtract(r_newrefdef.vieworg, currententity->origin, modelorg);

	if (rotated)
	{
		vec3_t temp;
		vec3_t forward, right, up;

		VectorCopy(modelorg, temp);
		AngleVectors(currententity->angles, forward, right, up);
		modelorg[0] = DotProduct(temp, forward);
		modelorg[1] = -DotProduct(temp, right);
		modelorg[2] = DotProduct(temp, up);
	}

	currententity->angles[0] = -currententity->angles[0];	// stupid quake bug
	currententity->angles[2] = -currententity->angles[2];	// stupid quake bug

	Mat_Identity(model);
	R_RotateForEntity(currententity, model);
	currententity->angles[0] = -currententity->angles[0];	// stupid quake bug
	currententity->angles[2] = -currententity->angles[2];	// stupid quake bug

	R_DrawInlineBModel(currententity, currentmodel, model);
}

static void
R_RecursiveWorldNode (mnode_t *node, entity_t *currententity)
{
	int c, side, sidebit;
	cplane_t *plane;
	msurface_t *surf;
	mleaf_t *pleaf;
	float dot;
	image_t *image;

	if (node->contents == CONTENTS_SOLID)
	{
		return; /* solid */
	}

	if (node->visframe != r_visframecount)
	{
		return;
	}

	if (r_cull->value && R_CullBox(node->minmaxs, node->minmaxs + 3, frustum))
	{
		return;
	}

	/* if a leaf node, draw stuff */
	if (node->contents != CONTENTS_NODE)
	{
		msurface_t	**mark;

		pleaf = (mleaf_t *)node;

		/* check for door connected areas */
		if (!R_AreaVisible(r_newrefdef.areabits, pleaf))
			return;	// not visible

		mark = pleaf->firstmarksurface;
		c = pleaf->nummarksurfaces;

		if (c)
		{
			do
			{
				(*mark)->visframe = r_framecount;
				mark++;
			}
			while (--c);
		}

		return;
	}

	/* node is just a decision point, so go down the apropriate
	   sides find which side of the node we are on */
	plane = node->plane;

	switch (plane->type)
	{
		case PLANE_X:
			dot = modelorg[0] - plane->dist;
			break;
		case PLANE_Y:
			dot = modelorg[1] - plane->dist;
			break;
		case PLANE_Z:
			dot = modelorg[2] - plane->dist;
			break;
		default:
			dot = DotProduct(modelorg, plane->normal) - plane->dist;
			break;
	}

	if (dot >= 0)
	{
		side = 0;
		sidebit = 0;
	}
	else
	{
		side = 1;
		sidebit = SURF_PLANEBACK;
	}

	/* recurse down the children, front side first */
	R_RecursiveWorldNode(node->children[side], currententity);

	/* draw stuff */
	for (c = node->numsurfaces, surf = r_worldmodel->surfaces + node->firstsurface; c ; c--, surf++)
	{
		if (surf->visframe != r_framecount)
		{
			continue;
		}

		if ((surf->flags & SURF_PLANEBACK) != sidebit)
		{
			continue; /* wrong side */
		}

		if (surf->texinfo->flags & SURF_SKY)
		{
			/* just adds to visible sky bounds */
			R_AddSkySurface(surf);
		}
		else if (surf->texinfo->flags & (SURF_TRANS33|SURF_TRANS66))
		{	// add to the translucent chain
			surf->texturechain = r_alpha_surfaces;
			r_alpha_surfaces = surf;
		}
		else
		{
			if (!(surf->flags & SURF_DRAWTURB) && !mtl_showtris->value)
			{
				MTL_RenderLightmappedPoly(surf, NULL, 1.f, currententity);
			}
			else
			{
				// the polygon is visible, so add it to the texture
				// sorted chain
				// FIXME: this is a hack for animation
				image = R_TextureAnimation(currententity, surf->texinfo);
				surf->texturechain = image->texturechain;
				image->texturechain = surf;
			}
		}
	}

	/* recurse down the back side */
	R_RecursiveWorldNode(node->children[!side], currententity);
}

void
R_DrawWorld(void)
{
	entity_t ent;

	if (!r_drawworld->value)
	{
		return;
	}

	if (r_newrefdef.rdflags & RDF_NOWORLDMODEL)
	{
		return;
	}

	VectorCopy(r_newrefdef.vieworg, modelorg);

	/* auto cycle the world frame for texture animation */
	memset(&ent, 0, sizeof(ent));
	ent.frame = (int)(r_newrefdef.time * 2);

	memset(mtl_lms.lightmap_surfaces, 0, sizeof(mtl_lms.lightmap_surfaces));

	R_ClearSkyBox();
	R_RecursiveWorldNode(r_worldmodel->nodes, &ent);

	/*
	** theoretically nothing should happen in the next two functions
	** if multitexture is enabled - in practice, this code renders non-transparent liquids!
	*/
	DrawTextureChains(&ent);
	R_DrawSkyBox();
	R_DrawTriangleOutlines();
}

/*
 * Mark the leaves and nodes that are
 * in the PVS for the current cluster
 */
void
R_MarkLeaves(void)
{
	const byte *vis;
	YQ2_ALIGNAS_TYPE(int) byte fatvis[MAX_MAP_LEAFS / 8];
	mnode_t *node;
	int i;
	mleaf_t *leaf;

	if ((r_oldviewcluster == r_viewcluster) &&
		(r_oldviewcluster2 == r_viewcluster2) &&
		!r_novis->value &&
		(r_viewcluster != -1))
	{
		return;
	}

	/* development aid to let you run around
	   and see exactly where the pvs ends */
	if (r_lockpvs->value)
	{
		return;
	}

	r_visframecount++;
	r_oldviewcluster = r_viewcluster;
	r_oldviewcluster2 = r_viewcluster2;

	if (r_novis->value || (r_viewcluster == -1) || !r_worldmodel->vis)
	{
		/* mark everything */
		for (i = 0; i < r_worldmodel->numleafs; i++)
		{
			r_worldmodel->leafs[i].visframe = r_visframecount;
		}

		for (i = 0; i < r_worldmodel->numnodes; i++)
		{
			r_worldmodel->nodes[i].visframe = r_visframecount;
		}

		return;
	}

	vis = Mod_ClusterPVS(r_viewcluster, r_worldmodel);

	/* may have to combine two clusters because of solid water boundaries */
	if (r_viewcluster2 != r_viewcluster)
	{
		int c;

		memcpy(fatvis, vis, (r_worldmodel->numleafs + 7) / 8);
		vis = Mod_ClusterPVS(r_viewcluster2, r_worldmodel);
		c = (r_worldmodel->numleafs + 31) / 32;

		for (i = 0; i < c; i++)
		{
			((int *)fatvis)[i] |= ((int *)vis)[i];
		}

		vis = fatvis;
	}

	for (i=0,leaf=r_worldmodel->leafs ; i<r_worldmodel->numleafs ; i++, leaf++)
	{
		int	cluster;

		cluster = leaf->cluster;
		if (cluster == -1)
			continue;
		if (vis[cluster>>3] & (1<<(cluster&7)))
		{
			node = (mnode_t *)leaf;
			do
			{
				if (node->visframe == r_visframecount)
					break;
				node->visframe = r_visframecount;
				node = node->parent;
			} while (node);
		}
	}
}



/*
=============================================================================

  LIGHTMAP ALLOCATION

=============================================================================
*/

static void LM_InitBlock( void )
{
	memset( mtl_lms.allocated, 0, sizeof( mtl_lms.allocated ) );
}

/*
 * Creates the GPU lightmap texture at `index` from a 128x128 RGBA buffer
 * (R_BuildLightMap output format, 4 bytes per pixel). The texture joins
 * the residency set so the GPU can see it.
 */
static void
MTL_CreateLightmapTexture(unsigned index, const byte *data)
{
	mtlstate_t *st = &mtl_state;
	MTLTextureDescriptor *td;
	id<MTLTexture> texture;

	td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
	        MTLPixelFormatRGBA8Unorm
	        width:BLOCK_WIDTH
	        height:BLOCK_HEIGHT
	        mipmapped:NO];
	td.storageMode = MTLStorageModeShared;
	texture = [st->device newTextureWithDescriptor:td];
	if (texture == nil)
	{
		Com_DPrintf("ref_mtl: failed to create lightmap texture %u\n", index);
		return;
	}

	[texture replaceRegion:MTLRegionMake2D(0, 0, BLOCK_WIDTH, BLOCK_HEIGHT)
	        mipmapLevel:0 slice:0 withBytes:data
	        bytesPerRow:BLOCK_WIDTH * LIGHTMAP_BYTES
	        bytesPerImage:BLOCK_WIDTH * BLOCK_HEIGHT * LIGHTMAP_BYTES];

	[st->residency_set addAllocation:texture];
	[st->residency_set commit];
	st->lightmap_textures[index] = texture;
}

static void LM_UploadBlock( qboolean dynamic )
{
	unsigned texture;

	if (dynamic)
		texture = 0;
	else
		texture = mtl_lms.current_lightmap_texture;

	if (dynamic)
	{
		int i;
		int height = 0;

		for (i = 0; i < BLOCK_WIDTH; i++)
		{
			if (mtl_lms.allocated[i] > height)
				height = mtl_lms.allocated[i];
		}

		if (height > 0 && mtl_state.lightmap_textures[texture])
			MTL_UploadLightmapRegion(mtl_state.lightmap_textures[texture],
				mtl_lms.lightmap_buffer, BLOCK_WIDTH * LIGHTMAP_BYTES,
				0, 0, BLOCK_WIDTH, height);
	}
	else
	{
		if (mtl_state.lightmap_textures[texture])
			MTL_UploadLightmapRegion(mtl_state.lightmap_textures[texture],
				mtl_lms.lightmap_buffer, BLOCK_WIDTH * LIGHTMAP_BYTES,
				0, 0, BLOCK_WIDTH, BLOCK_HEIGHT);
		else
			MTL_CreateLightmapTexture(texture, mtl_lms.lightmap_buffer);

		if ( ++mtl_lms.current_lightmap_texture == MAX_LIGHTMAPS )
			ri.Sys_Error( ERR_DROP, "%s() - MAX_LIGHTMAPS exceeded\n", __func__);
	}
}

// returns a texture number and the position inside it
static qboolean LM_AllocBlock (int w, int h, int *x, int *y)
{
	int		i, best;

	best = BLOCK_HEIGHT;

	for (i=0 ; i<BLOCK_WIDTH-w ; i++)
	{
		int		j, best2;

		best2 = 0;

		for (j=0 ; j<w ; j++)
		{
			if (mtl_lms.allocated[i+j] >= best)
				break;
			if (mtl_lms.allocated[i+j] > best2)
				best2 = mtl_lms.allocated[i+j];
		}
		if (j == w)
		{	// this is a valid spot
			*x = i;
			*y = best = best2;
		}
	}

	if (best + h > BLOCK_HEIGHT)
		return false;

	for (i=0 ; i<w ; i++)
		mtl_lms.allocated[*x + i] = best + h;

	return true;
}

/*
================
MTL_BuildPolygonFromSurface
================
*/
void MTL_BuildPolygonFromSurface(msurface_t *fa, model_t *currentmodel)
{
	int			i, lnumverts;
	medge_t		*pedges, *r_pedge;
	float		*vec;
	mtlpoly_t	*poly;
	vec3_t		total;

	// reconstruct the polygon
	pedges = currentmodel->edges;
	lnumverts = fa->numedges;

	VectorClear (total);

	//
	// draw texture
	//
	poly = Hunk_Alloc (sizeof(mtlpoly_t) + (lnumverts-4) * VERTEXSIZE * sizeof(float));
	poly->next = fa->polys;
	poly->flags = fa->flags;
	fa->polys = poly;
	poly->numverts = lnumverts;

	for (i=0 ; i<lnumverts ; i++)
	{
		int		lindex;
		float	s, t;

		lindex = currentmodel->surfedges[fa->firstedge + i];

		if (lindex > 0)
		{
			r_pedge = &pedges[lindex];
			vec = currentmodel->vertexes[r_pedge->v[0]].position;
		}
		else
		{
			r_pedge = &pedges[-lindex];
			vec = currentmodel->vertexes[r_pedge->v[1]].position;
		}

		s = DotProduct(vec, fa->texinfo->vecs[0]) + fa->texinfo->vecs[0][3];
		s /= fa->texinfo->image->width;

		t = DotProduct(vec, fa->texinfo->vecs[1]) + fa->texinfo->vecs[1][3];
		t /= fa->texinfo->image->height;

		VectorAdd (total, vec, total);
		VectorCopy(vec, poly->verts[i]);
		poly->verts[i][3] = s;
		poly->verts[i][4] = t;

		//
		// lightmap texture coordinates
		//
		s = DotProduct(vec, fa->lmvecs[0]) + fa->lmvecs[0][3];
		s -= fa->texturemins[0];
		s += fa->light_s * (1 << fa->lmshift);
		s += (1 << fa->lmshift) * 0.5;
		s /= BLOCK_WIDTH * (1 << fa->lmshift);

		t = DotProduct(vec, fa->lmvecs[1]) + fa->lmvecs[1][3];
		t -= fa->texturemins[1];
		t += fa->light_t * (1 << fa->lmshift);
		t += (1 << fa->lmshift) * 0.5;
		t /= BLOCK_HEIGHT * (1 << fa->lmshift);

		poly->verts[i][5] = s;
		poly->verts[i][6] = t;
	}

	poly->numverts = lnumverts;

}

/*
========================
MTL_CreateSurfaceLightmap
========================
*/
void MTL_CreateSurfaceLightmap (msurface_t *surf)
{
	int		smax, tmax;
	byte	*base;

	if (surf->flags & (SURF_DRAWSKY|SURF_DRAWTURB))
		return;

	smax = (surf->extents[0] >> surf->lmshift) + 1;
	tmax = (surf->extents[1] >> surf->lmshift) + 1;

	if ( !LM_AllocBlock( smax, tmax, &surf->light_s, &surf->light_t ) )
	{
		LM_UploadBlock( false );
		LM_InitBlock();
		if ( !LM_AllocBlock( smax, tmax, &surf->light_s, &surf->light_t ) )
		{
			ri.Sys_Error( ERR_FATAL, "%s: Consecutive calls to LM_AllocBlock(%d,%d) failed\n", __func__, smax, tmax );
		}
	}

	surf->lightmaptexturenum = mtl_lms.current_lightmap_texture;

	base = mtl_lms.lightmap_buffer;
	base += (surf->light_t * BLOCK_WIDTH + surf->light_s) * LIGHTMAP_BYTES;

	R_SetCacheState( surf );
	R_BuildLightMap (surf, base, BLOCK_WIDTH*LIGHTMAP_BYTES);
}


/*
==================
MTL_BeginBuildingLightmaps

==================
*/
void MTL_BeginBuildingLightmaps (model_t *m)
{
	static lightstyle_t	lightstyles[MAX_LIGHTSTYLES];
	int				i;

	memset(mtl_lms.allocated, 0, sizeof(mtl_lms.allocated));

	r_framecount = 1;		// no dlightcache

	/*
	** setup the base lightstyles so the lightmaps won't have to be regenerated
	** the first time they're seen
	*/
	for (i = 0; i < MAX_LIGHTSTYLES; i++)
	{
		lightstyles[i].rgb[0] = 1;
		lightstyles[i].rgb[1] = 1;
		lightstyles[i].rgb[2] = 1;
		lightstyles[i].white = 3;
	}
	r_newrefdef.lightstyles = lightstyles;

	mtl_lms.current_lightmap_texture = 0;

	/*
	** initialize the dynamic lightmap textures
	*/
	if (mtl_state.lightmap_textures[DYNLIGHTMAP_OFFSET] == nil)
	{
		byte dummy[BLOCK_WIDTH * BLOCK_HEIGHT * LIGHTMAP_BYTES];

		memset(dummy, 0, sizeof(dummy));

		for (i = DYNLIGHTMAP_OFFSET; i < MAX_LIGHTMAPS * 2; i++)
			MTL_CreateLightmapTexture(i, dummy);
	}
}

/*
=======================
MTL_EndBuildingLightmaps
=======================
*/
void MTL_EndBuildingLightmaps (void)
{
	LM_UploadBlock( false );
}

/*
=============================================================================

  DRAWING

  World polys are fan-expanded into the current frame slot's vertex ring
  and drawn through the shared argument tables: buffer 0 of the vertex
  table is the stage_in vertex data, buffer 1 the per-draw world UBO;
  the fragment table carries the surface texture (plus the lightmap for
  the lmap path) and the same UBO at buffer 0. Tables are snapshotted at
  draw-encode time, so sequential draws sharing them are safe.

=============================================================================
*/

/*
 * World-space model matrix used when a caller has no transform of its own.
 * The brush-poly draw paths (MTL_DrawPoly / MTL_DrawFlowingPoly) pass NULL
 * for the model, so a NULL model means "world space" (identity) - the same
 * convention MTL_RenderLightmappedPoly applies via Mat_Identity().
 */
static const float s_identity_model[16] = {
	1.f, 0.f, 0.f, 0.f,
	0.f, 1.f, 0.f, 0.f,
	0.f, 0.f, 1.f, 0.f,
	0.f, 0.f, 0.f, 1.f
};

/*
 * Writes one world_ubo_t into the slot's UBO ring and returns its GPU
 * address (0 when the ring is exhausted). A NULL model means world space
 * (identity); a NULL color is not expected from any caller.
 */
static MTLGPUAddress
MTL_EmitWorldUbo(size_t slot, const float *model, const float *color)
{
	mtlstate_t *st = &mtl_state;
	world_ubo_t *ubo;
	MTLGPUAddress addr;

	if (st->world_ubo_offset[slot] + sizeof(world_ubo_t) > WORLD_UBO_RING_BYTES)
		return 0;

	addr = st->world_ubo[slot].gpuAddress + st->world_ubo_offset[slot];
	ubo = (world_ubo_t *)((byte *)st->world_ubo[slot].contents + st->world_ubo_offset[slot]);
	memcpy(ubo->viewproj, r_viewproj_matrix, sizeof(r_viewproj_matrix));
	memcpy(ubo->model, model ? model : s_identity_model, sizeof(float) * 16);
	memcpy(ubo->color, color, sizeof(float) * 4);
	ubo->gamma = 2.1f - vid_gamma->value;
	ubo->viewLightmaps = r_lightmap->value ? 1.f : 0.f;
	st->world_ubo_offset[slot] += sizeof(world_ubo_t);

	return addr;
}

/*
 * Fills one fan-expanded vertex record: position straight from the poly,
 * texture coords transformed by uvscale/scroll, plus the per-vertex sine
 * turbulence when warp is set. The sine is evaluated per vertex (matching
 * the vk polygon_warp vertex shader); the GPU interpolates it across the
 * triangle, so subdivision density controls the warp's smoothness.
 */
static void MTL_WritePolyVert (polyvert_t *dst, const float *src,
	float uvscale, float scroll, float time, qboolean warp)
{
	dst->vertex[0] = src[0];
	dst->vertex[1] = src[1];
	dst->vertex[2] = src[2];

	if (warp)
	{
		float s = src[3] * uvscale;
		float t = src[4] * uvscale;

		dst->texCoord[0] = s + scroll + sinf(2.0f * time + t * 3.28f) * 0.05f;
		dst->texCoord[1] = t + sinf(2.0f * time + s * 3.28f) * 0.05f;
	}
	else
	{
		dst->texCoord[0] = src[3] * uvscale + scroll;
		dst->texCoord[1] = src[4] * uvscale;
	}
}

void MTL_DrawPolyChain (mtlpoly_t *p, id<MTLTexture> texture, const float *model,
	const float *color, float uvscale, float scroll, qboolean sky,
	float time, qboolean warp)
{
	mtlstate_t *st = &mtl_state;
	size_t slot;
	polyvert_t *ring;
	MTLGPUAddress ubo_addr;

	if (st->encoder == nil || texture == nil || p == NULL)
		return;

	slot = st->frame_slot;
	ring = (polyvert_t *)st->world_vertex_buffer[slot].contents;

	for (; p; p = p->next)
	{
		int nv = p->numverts;
		int count;
		size_t vstart;
		polyvert_t *dst;
		int i, k;

		if (nv < 3)
			continue;

		count = (nv - 2) * 3;
		vstart = st->world_vertex_offset[slot];
		if (vstart + (size_t)count * sizeof(polyvert_t) > WORLD_VERTEX_RING_BYTES)
			break;	/* ring exhausted, skip the rest of the chain */

		dst = ring + vstart / sizeof(polyvert_t);
		for (k = 0; k < nv - 2; k++)
		{
			MTL_WritePolyVert (dst, p->verts[0], uvscale, scroll, time, warp);
			dst++;

			for (i = k + 1; i <= k + 2; i++)
			{
				MTL_WritePolyVert (dst, p->verts[i], uvscale, scroll, time, warp);
				dst++;
			}
		}
		st->world_vertex_offset[slot] += (size_t)count * sizeof(polyvert_t);

		ubo_addr = MTL_EmitWorldUbo(slot, model, color);
		if (ubo_addr == 0)
			break;

		[st->plain_vert_table setAddress:st->world_vertex_buffer[slot].gpuAddress + vstart atIndex:0];
		[st->plain_vert_table setAddress:ubo_addr atIndex:1];
		[st->plain_frag_table setTexture:texture.gpuResourceID atIndex:0];
		[st->plain_frag_table setAddress:ubo_addr atIndex:0];

		[st->encoder setRenderPipelineState:sky ? st->pipeline_sky : st->pipeline_plain];
		[st->encoder setArgumentTable:st->plain_vert_table atStages:MTLRenderStageVertex];
		[st->encoder setArgumentTable:st->plain_frag_table atStages:MTLRenderStageFragment];
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)count];
	}
}

void MTL_DrawSkyQuad (id<MTLTexture> texture, const float *verts,
	const float *model, const float *color)
{
	mtlstate_t *st = &mtl_state;
	size_t slot;
	polyvert_t *dst;
	size_t vstart;
	MTLGPUAddress ubo_addr;

	if (st->encoder == nil || texture == nil || verts == NULL)
		return;

	slot = st->frame_slot;
	vstart = st->world_vertex_offset[slot];
	if (vstart + 6 * sizeof(polyvert_t) > WORLD_VERTEX_RING_BYTES)
		return;

	dst = (polyvert_t *)st->world_vertex_buffer[slot].contents + vstart / sizeof(polyvert_t);
	for (int i = 0; i < 6; i++)
	{
		dst->vertex[0] = verts[i * 5 + 0];
		dst->vertex[1] = verts[i * 5 + 1];
		dst->vertex[2] = verts[i * 5 + 2];
		dst->texCoord[0] = verts[i * 5 + 3];
		dst->texCoord[1] = verts[i * 5 + 4];
		dst++;
	}
	st->world_vertex_offset[slot] += 6 * sizeof(polyvert_t);

	ubo_addr = MTL_EmitWorldUbo(slot, model, color);
	if (ubo_addr == 0)
		return;

	[st->plain_vert_table setAddress:st->world_vertex_buffer[slot].gpuAddress + vstart atIndex:0];
	[st->plain_vert_table setAddress:ubo_addr atIndex:1];
	[st->plain_frag_table setTexture:texture.gpuResourceID atIndex:0];
	[st->plain_frag_table setAddress:ubo_addr atIndex:0];

	[st->encoder setRenderPipelineState:st->pipeline_sky];
	[st->encoder setArgumentTable:st->plain_vert_table atStages:MTLRenderStageVertex];
	[st->encoder setArgumentTable:st->plain_frag_table atStages:MTLRenderStageFragment];
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

void MTL_DrawLightmappedChain (mtlpoly_t *p, id<MTLTexture> texture,
	id<MTLTexture> lmap, const float *model, const float *color, float scroll)
{
	mtlstate_t *st = &mtl_state;
	size_t slot;
	lmappolyvert_t *ring;
	MTLGPUAddress ubo_addr;

	if (st->encoder == nil || texture == nil || lmap == nil || p == NULL)
		return;

	slot = st->frame_slot;
	ring = (lmappolyvert_t *)st->world_lmap_vertex_buffer[slot].contents;

	for (; p; p = p->next)
	{
		int nv = p->numverts;
		int count;
		size_t vstart;
		lmappolyvert_t *dst;
		int i, k;

		if (nv < 3)
			continue;

		count = (nv - 2) * 3;
		vstart = st->world_lmap_vertex_offset[slot];
		if (vstart + (size_t)count * sizeof(lmappolyvert_t) > WORLD_LMAP_VERTEX_RING_BYTES)
			break;	/* ring exhausted, skip the rest of the chain */

		dst = ring + vstart / sizeof(lmappolyvert_t);
		for (k = 0; k < nv - 2; k++)
		{
			const float *src;

			src = p->verts[0];
			dst->vertex[0] = src[0];
			dst->vertex[1] = src[1];
			dst->vertex[2] = src[2];
			dst->texCoord[0] = src[3] + scroll;
			dst->texCoord[1] = src[4];
			dst->texCoordLmap[0] = src[5];
			dst->texCoordLmap[1] = src[6];
			dst++;

			for (i = k + 1; i <= k + 2; i++)
			{
				src = p->verts[i];
				dst->vertex[0] = src[0];
				dst->vertex[1] = src[1];
				dst->vertex[2] = src[2];
				dst->texCoord[0] = src[3] + scroll;
				dst->texCoord[1] = src[4];
				dst->texCoordLmap[0] = src[5];
				dst->texCoordLmap[1] = src[6];
				dst++;
			}
		}
		st->world_lmap_vertex_offset[slot] += (size_t)count * sizeof(lmappolyvert_t);

		ubo_addr = MTL_EmitWorldUbo(slot, model, color);
		if (ubo_addr == 0)
			break;

		[st->lmap_vert_table setAddress:st->world_lmap_vertex_buffer[slot].gpuAddress + vstart atIndex:0];
		[st->lmap_vert_table setAddress:ubo_addr atIndex:1];
		[st->lmap_frag_table setTexture:texture.gpuResourceID atIndex:0];
		[st->lmap_frag_table setTexture:lmap.gpuResourceID atIndex:1];
		[st->lmap_frag_table setAddress:ubo_addr atIndex:0];

		[st->encoder setRenderPipelineState:st->pipeline_lmap];
		[st->encoder setArgumentTable:st->lmap_vert_table atStages:MTLRenderStageVertex];
		[st->encoder setArgumentTable:st->lmap_frag_table atStages:MTLRenderStageFragment];
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)count];
	}
}

void MTL_FreeLightmaps (void)
{
	unsigned i;

	for (i = 0; i < MAX_LIGHTMAPS * 2; i++)
	{
		[mtl_state.lightmap_textures[i] release];
		mtl_state.lightmap_textures[i] = nil;
	}
}
