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
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307,
 * USA.
 *
 * =======================================================================
 *
 * W5a: alias models (MD2/SP2)
 *
 * Ported from ref_vk (vk_mesh.c). The glcmd strip/fan list is expanded
 * into triangle lists on the CPU (Metal has no strip/fan topology), with
 * the exact winding ref_vk's index buffers use (see vk_common.c
 * RebuildTriangleIndexBuffer): fan vertex i emits (0, i+1, i+2); strip
 * vertex i emits (i-2, i-1, i) for even i and (i, i-1, i-2) for odd i.
 * Vertices land in the per-slot alias ring; one alias_ubo_t (model
 * matrix + viewproj + textured flag) is written to the world UBO ring
 * per model and shared by all of its draws.
 *
 * Deferred from ref_vk: shadows (vk_shadows). The depth-hack / gun-FOV
 * projection (I2) rides on the per-draw alias UBO and the r_lefthand
 * mirror (I2) on the encoder cull state; neither disturbs the global
 * view matrices.
 *
 * =======================================================================
 */

#include "header/mtl.h"

#define SHADEDOT_QUANT	16

static float r_avertexnormals[NUMVERTEXNORMALS][3] = {
#include "../constants/anorms.h"
};
static float r_avertexnormal_dots[SHADEDOT_QUANT][256] = {
#include "../constants/anormtab.h"
};

static float shadelight[3];
static float *shadedots;

/*
 * Lerped vertex positions in model space, one vec3 per vertex of the
 * current frame. Reallocated on demand like ref_vk's Mesh_VertsRealloc.
 */
static float *s_lerped;	// s_lerped_count * 3 floats
static int s_lerped_count;

/* Parsed glcmd vertices of the command currently being expanded. */
typedef struct
{
	float uv[2];
	int index;
} alias_cmdvert_t;

static alias_cmdvert_t *s_cmdverts;	// s_cmdverts_count records
static int s_cmdverts_count;

static int
Alias_LerpRealloc(int count)
{
	void *ptr;

	if (s_lerped_count >= count)
		return 0;

	s_lerped_count = ROUNDUP(count, 256);
	ptr = realloc(s_lerped, (size_t)s_lerped_count * sizeof(float) * 3);
	if (!ptr)
		return -1;
	s_lerped = ptr;

	return 0;
}

static int
Alias_CmdvertRealloc(int count)
{
	void *ptr;

	if (s_cmdverts_count >= count)
		return 0;

	s_cmdverts_count = ROUNDUP(count, 256);
	ptr = realloc(s_cmdverts, (size_t)s_cmdverts_count * sizeof(alias_cmdvert_t));
	if (!ptr)
		return -1;
	s_cmdverts = ptr;

	return 0;
}

/*
==============
MTL_ShutdownAliasScratch

L2: free the alias scratch buffers on renderer shutdown; ref_vk
frees its lerped-vertex buffer in Mesh_Free(), called from
QVk_WaitAndShutdownAll. Zeroing the capacity counters makes the
next RE_Init reallocate on demand.
==============
*/
void
MTL_ShutdownAliasScratch(void)
{
	free(s_lerped);
	s_lerped = NULL;
	s_lerped_count = 0;

	free(s_cmdverts);
	s_cmdverts = NULL;
	s_cmdverts_count = 0;
}

/*
 * Writes one alias_ubo_t into the slot's world UBO ring and returns its
 * byte offset within the ring buffer (SIZE_MAX when exhausted). The
 * model matrix is in model space (rotation + translation only); the
 * vertex shader applies viewproj * model. I2: the viewproj is passed
 * in rather than read from r_viewproj_matrix so depth-hack / left-hand
 * entities can supply their own variant without disturbing the global
 * matrix (the UBO record captures it at emit time; later entities keep
 * the global one automatically).
 */
size_t
MTL_EmitAliasUbo(size_t slot, const float *model, const float *viewproj, float textured)
{
	mtlstate_t *st = &mtl_state;
	alias_ubo_t *ubo;
	size_t off;

	if (st->world_ubo_offset[slot] + MTL_UBO_ALIGN(sizeof(alias_ubo_t)) > WORLD_UBO_RING_BYTES)
		return MTL_UboRingDry();

	off = st->world_ubo_offset[slot];
	ubo = (alias_ubo_t *)((byte *)st->world_ubo[slot].contents + off);
	memcpy(ubo->viewproj, viewproj, sizeof(float) * 16);
	memcpy(ubo->model, model, sizeof(float) * 16);
	ubo->textured = textured;
	/* F4: advance keeps the next ring offset 16-byte aligned */
	st->world_ubo_offset[slot] += MTL_UBO_ALIGN(sizeof(alias_ubo_t));

	return off;
}

/*
 * I2 (ref_vk R_DrawAliasModel's RF_DEPTHHACK / RDF_NOWORLDMODEL block):
 * rebuilds the view-projection matrix for view models so their depth
 * lands in a compressed front band and they can't poke through world
 * geometry. ref_vk post-multiplies its projection by the correction
 * matrix r_vulkan_correction_dh with [10] = [14] = c (0.3, or 0.2 while
 * the player-setup menu's RDF_NOWORLDMODEL flag is set, to keep the
 * setup model off the view model), which maps GL NDC z in [-1,1] to
 * [0, 2c]. ref_mtl's Mat_Perspective emits Metal's [0,1] depth range
 * directly, so the same band is folded into the matrix by scaling the
 * depth row pair by 2c: z' = 2c*z_ndc (Metal NDC). The near plane is 4
 * (the gun model distance) and fovy follows r_gunfov for
 * RF_WEAPONMODEL, matching ref_vk: a negative r_gunfov means "follow
 * the main FOV" (r_newrefdef.fov_y), otherwise the cvar value is used.
 */
void
MTL_BuildDepthHackViewproj(const entity_t *e, float *out)
{
	float dist = (r_farsee->value == 0) ? 4096.0f : 8192.0f;
	float c = 0.3f - (r_newrefdef.rdflags & RDF_NOWORLDMODEL) * 0.1f;
	float fovy;
	float proj[16];

	if ((e->flags & RF_WEAPONMODEL) && r_gunfov->value < 0)
	{
		fovy = r_newrefdef.fov_y;
	}
	else
	{
		fovy = r_gunfov->value;
	}

	Mat_Perspective(proj, fovy, (float)r_newrefdef.width / r_newrefdef.height, 4, dist);
	/* fold the [0,1] depth range into the [0, 2c] band: scale the
	   depth row pair by 2c, z' = 2c*z_ndc (row-vector convention,
	   w row untouched) */
	proj[10] *= 2.0f * c;
	proj[14] *= 2.0f * c;

	Mat_Mul(r_view_matrix, proj, out);
}

/*
 * Writes one sprite_ubo_t (viewproj + gamma) into the slot's world UBO
 * ring and returns its byte offset within the ring buffer (SIZE_MAX
 * when exhausted). Also used by the textured particle path (W5c),
 * which needs the same viewproj + gamma UBO.
 */
size_t
MTL_EmitSpriteUbo(size_t slot)
{
	mtlstate_t *st = &mtl_state;
	sprite_ubo_t *ubo;
	size_t off;

	if (st->world_ubo_offset[slot] + MTL_UBO_ALIGN(sizeof(sprite_ubo_t)) > WORLD_UBO_RING_BYTES)
		return MTL_UboRingDry();

	off = st->world_ubo_offset[slot];
	ubo = (sprite_ubo_t *)((byte *)st->world_ubo[slot].contents + off);
	memcpy(ubo->viewproj, r_viewproj_matrix, sizeof(r_viewproj_matrix));
	ubo->gamma = 2.1f - vid_gamma->value;
	/* F4: advance keeps the next ring offset 16-byte aligned */
	st->world_ubo_offset[slot] += MTL_UBO_ALIGN(sizeof(sprite_ubo_t));

	return off;
}

/*
 * Interpolates the frame's vertices between two frames and origins
 * (ref_vk Vk_LerpVerts). The result lands in s_lerped, one vec3 per
 * vertex. Shells offset the vertices along their normals by
 * POWERSUIT_SCALE so the power armor shell wraps the body.
 */
static void
Alias_LerpVerts(int nverts, dtrivertx_t *v, dtrivertx_t *ov, dtrivertx_t *verts,
    float *lerp, const float move[3], const float frontv[3], const float backv[3],
    entity_t *currententity)
{
	int i;

	if (currententity->flags & (RF_SHELL_RED | RF_SHELL_GREEN | RF_SHELL_BLUE | RF_SHELL_DOUBLE | RF_SHELL_HALF_DAM))
	{
		for (i = 0; i < nverts; i++, v++, ov++, lerp += 3)
		{
			float *normal = r_avertexnormals[verts[i].lightnormalindex];

			lerp[0] = move[0] + ov->v[0]*backv[0] + v->v[0]*frontv[0] + normal[0] * POWERSUIT_SCALE;
			lerp[1] = move[1] + ov->v[1]*backv[1] + v->v[1]*frontv[1] + normal[1] * POWERSUIT_SCALE;
			lerp[2] = move[2] + ov->v[2]*backv[2] + v->v[2]*frontv[2] + normal[2] * POWERSUIT_SCALE;
		}
	}
	else
	{
		for (i = 0; i < nverts; i++, v++, ov++, lerp += 3)
		{
			lerp[0] = move[0] + ov->v[0]*backv[0] + v->v[0]*frontv[0];
			lerp[1] = move[1] + ov->v[1]*backv[1] + v->v[1]*frontv[1];
			lerp[2] = move[2] + ov->v[2]*backv[2] + v->v[2]*frontv[2];
		}
	}
}

/*
 * One alias ring record for a parsed glcmd vertex: the lerped position,
 * the texture coordinates from the glcmd list (unused by shells), and
 * the per-vertex light color (shadedots * shadelight, or plain
 * shadelight for shells).
 */
static void
MTL_WriteAliasVert(aliasvert_t *dst, const alias_cmdvert_t *cv, dtrivertx_t *verts,
    float alpha, qboolean shell)
{
	dst->position[0] = s_lerped[cv->index * 3 + 0];
	dst->position[1] = s_lerped[cv->index * 3 + 1];
	dst->position[2] = s_lerped[cv->index * 3 + 2];

	if (shell)
	{
		/* shells are untextured solid color (see alias_fragment) */
		dst->uv[0] = 0.f;
		dst->uv[1] = 0.f;
		dst->color[0] = shadelight[0];
		dst->color[1] = shadelight[1];
		dst->color[2] = shadelight[2];
	}
	else
	{
		/* texture coordinates come from the draw list */
		dst->uv[0] = cv->uv[0];
		dst->uv[1] = cv->uv[1];

		/* normals and vertexes come from the frame list */
		{
			float l = shadedots[verts[cv->index].lightnormalindex];

			dst->color[0] = l * shadelight[0];
			dst->color[1] = l * shadelight[1];
			dst->color[2] = l * shadelight[2];
		}
	}
	dst->color[3] = alpha;
}

/*
 * Walks one glcmd list (a mesh node's strip/fan commands) and draws it.
 * Each command is parsed into s_cmdverts, CPU-expanded into a triangle
 * list in the slot's alias ring (ref_vk winding, see the file header),
 * and drawn with the model's UBO and skin.
 *
 * Returns 0 when the whole list was consumed; -1 when the ring was
 * exhausted or a vertex index was out of range (the rest of the model
 * is skipped).
 */
static int
MTL_DrawAliasGlcmds(int *order, int *order_end, float alpha, image_t *skin,
    dtrivertx_t *verts, int num_xyz, size_t ubo_off,
    qboolean shell, qboolean translucent, qboolean lefthand)
{
	mtlstate_t *st = &mtl_state;
	size_t slot;
	aliasvert_t *ring;

	if (st->encoder == nil || skin == NULL || skin->mtl_texture == nil)
		return 0;

	slot = st->frame_slot;
	ring = (aliasvert_t *)st->alias_vertex_buffer[slot].contents;

	while (1)
	{
		int count;
		qboolean fan;
		size_t vstart;
		aliasvert_t *dst;
		int tri_count;
		int i, k;

		count = *order++;

		if (!count || order >= order_end)
			break;	/* done */

		fan = count < 0;
		if (fan)
			count = -count;

		if (count < 3)
		{
			/* I3: malformed command (ref_vk has no such check): the
			   vertex words still have to be stepped over, otherwise
			   the next iteration reads a vertex float as the command
			   count and the whole list desyncs. Clamp the skip to
			   order_end so a truncated tail cannot run off the end. */
			order += Q_min(3 * count, (int)(order_end - order));
			continue;
		}

		if (Alias_CmdvertRealloc(count))
		{
			Com_Error(ERR_FATAL, "MTL_DrawAliasGlcmds: can't allocate memory\n");
		}

		/* parse the command's vertices and validate the indices.
		   I3: also stop at order_end: a header claiming more vertices
		   than the node's range holds must not read past the end of
		   the command list. */
		for (i = 0; i < count; i++)
		{
			int index_xyz;

			if (order + 3 > order_end)
			{
				Com_Printf("MTL_DrawAliasGlcmds: truncated glcmd list\n");
				return -1;
			}

			index_xyz = order[2];

			if (index_xyz < 0 || index_xyz >= num_xyz)
			{
				Com_Printf("MTL_DrawAliasGlcmds: model has issues with lerped index\n");
				return -1;
			}

			s_cmdverts[i].uv[0] = ((float *)order)[0];
			s_cmdverts[i].uv[1] = ((float *)order)[1];
			s_cmdverts[i].index = index_xyz;
			order += 3;
		}

		/* expand the strip/fan into a triangle list */
		tri_count = (count - 2) * 3;
		vstart = st->alias_vertex_offset[slot];
		if (vstart + (size_t)tri_count * sizeof(aliasvert_t) > ALIAS_VERTEX_RING_BYTES)
			return -1;	/* ring exhausted, skip the rest */

		dst = ring + vstart / sizeof(aliasvert_t);
		if (fan)
		{
			for (i = 0; i < count - 2; i++)
			{
				for (k = 0; k < 3; k++)
					MTL_WriteAliasVert(dst++, &s_cmdverts[k == 0 ? 0 : i + k], verts, alpha, shell);
			}
		}
		else
		{
			for (i = 2; i < count; i++)
			{
				if (i & 1)
				{
					MTL_WriteAliasVert(dst++, &s_cmdverts[i], verts, alpha, shell);
					MTL_WriteAliasVert(dst++, &s_cmdverts[i - 1], verts, alpha, shell);
					MTL_WriteAliasVert(dst++, &s_cmdverts[i - 2], verts, alpha, shell);
				}
				else
				{
					MTL_WriteAliasVert(dst++, &s_cmdverts[i - 2], verts, alpha, shell);
					MTL_WriteAliasVert(dst++, &s_cmdverts[i - 1], verts, alpha, shell);
					MTL_WriteAliasVert(dst++, &s_cmdverts[i], verts, alpha, shell);
				}
			}
		}
		st->alias_vertex_offset[slot] += (size_t)tri_count * sizeof(aliasvert_t);

		[st->encoder setVertexBuffer:st->alias_vertex_buffer[slot]
			offset:vstart atIndex:0];
		[st->encoder setVertexBuffer:st->world_ubo[slot]
			offset:ubo_off atIndex:1];
		[st->encoder setFragmentTexture:skin->mtl_texture atIndex:0];
		[st->encoder setFragmentBuffer:st->world_ubo[slot]
			offset:ubo_off atIndex:0];

		[st->encoder setRenderPipelineState:translucent ? st->pipeline_alias_translucent : st->pipeline_alias];
		[st->encoder setDepthStencilState:translucent ? st->depth_state_nodwrite : st->depth_state];

		/* K2: set the model draws' raster state explicitly before
		   every drawPrimitives, and restore the pass baseline
		   (MTL_SetPassDefaults) right after, so draw order can
		   never leak a cull into another group. The model-file
		   triangle data (glcmds, and the shells that reuse them)
		   faces Clockwise under mtl's projection - mtl's clip
		   space does NOT mirror winding against vk, so this pair
		   is ref_vk's fan pipeline's: global CW frontFace +
		   CULL_MODE_BACK (qvk.h). The mirrored (lefthand) viewproj
		   flips on-screen winding, so the cull discards the other
		   side, exactly like vk's dedicated lefthand model fan
		   (CULL_MODE_FRONT). Evidence trail: README and
		   REVIEW_EXTERNAL.md, round 6 (J3/K2). */
		[st->encoder setFrontFacingWinding:MTLWindingClockwise];
		[st->encoder setCullMode:lefthand ? MTLCullModeFront : MTLCullModeBack];
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)tri_count];
		MTL_SetPassDefaults(st->encoder);
	}

	return 0;
}

/*
 * Draws the model's lerped frame for each mesh node (ref_vk
 * Vk_DrawAliasFrameLerp). The model matrix and UBO are computed once;
 * all of the model's glcmd draws share them.
 */
static void
MTL_DrawAliasFrameLerp(dmdl_t *paliashdr, float backlerp, image_t *skin,
    float *modelMatrix, const float *viewproj, entity_t *currententity)
{
	daliasframe_t *frame, *oldframe;
	dtrivertx_t *v, *ov, *verts;
	int *order;
	float frontlerp;
	float alpha;
	vec3_t move, delta, vectors[3];
	vec3_t frontv, backv;
	int i;
	float *lerp;
	int num_mesh_nodes;
	short *mesh_nodes;
	qboolean shell, translucent;
	qboolean lefthand;
	size_t ubo_off;

	frame = (daliasframe_t *)((byte *)paliashdr + paliashdr->ofs_frames
	    + currententity->frame * paliashdr->framesize);
	verts = v = frame->verts;

	oldframe = (daliasframe_t *)((byte *)paliashdr + paliashdr->ofs_frames
	    + currententity->oldframe * paliashdr->framesize);
	ov = oldframe->verts;

	order = (int *)((byte *)paliashdr + paliashdr->ofs_glcmds);

	if (currententity->flags & RF_TRANSLUCENT)
	{
		alpha = currententity->alpha;
	}
	else
	{
		alpha = 1.0;
	}

	frontlerp = 1.0 - backlerp;

	/* move should be the delta back to the previous frame * backlerp */
	VectorSubtract(currententity->oldorigin, currententity->origin, delta);
	AngleVectors(currententity->angles, vectors[0], vectors[1], vectors[2]);

	move[0] = DotProduct(delta, vectors[0]); /* forward */
	move[1] = -DotProduct(delta, vectors[1]); /* left */
	move[2] = DotProduct(delta, vectors[2]); /* up */

	VectorAdd(move, oldframe->translate, move);

	for (i = 0; i < 3; i++)
	{
		move[i] = backlerp * move[i] + frontlerp * frame->translate[i];

		frontv[i] = frontlerp * frame->scale[i];
		backv[i] = backlerp * oldframe->scale[i];
	}

	if (Alias_LerpRealloc(paliashdr->num_xyz))
	{
		Com_Error(ERR_FATAL, "MTL_DrawAliasFrameLerp: can't allocate memory\n");
	}

	lerp = s_lerped;
	Alias_LerpVerts(paliashdr->num_xyz, v, ov, verts, lerp, move, frontv, backv, currententity);

	shell = (currententity->flags & (RF_SHELL_RED | RF_SHELL_GREEN | RF_SHELL_BLUE)) != 0;
	translucent = (currententity->flags & RF_TRANSLUCENT) != 0;

	ubo_off = MTL_EmitAliasUbo(mtl_state.frame_slot, modelMatrix, viewproj,
	    shell ? 0.f : (r_lightmap->value ? 0.f : 1.f));
	if (ubo_off == SIZE_MAX)
		return;	/* UBO ring exhausted */

	lefthand = ((currententity->flags & RF_WEAPONMODEL) && r_lefthand->value == 1.0f);

	num_mesh_nodes = (paliashdr->ofs_skins - sizeof(dmdl_t)) / sizeof(short) / 2;
	mesh_nodes = (short *)((char *)paliashdr + sizeof(dmdl_t));

	if (num_mesh_nodes > 0)
	{
		for (i = 0; i < num_mesh_nodes; i++)
		{
			if (MTL_DrawAliasGlcmds(order + mesh_nodes[i * 2],
			    order + Q_min(paliashdr->num_glcmds, mesh_nodes[i * 2] + mesh_nodes[i * 2 + 1]),
			    alpha, skin, verts, paliashdr->num_xyz, ubo_off, shell, translucent, lefthand))
				return;
		}
	}
	else
	{
		MTL_DrawAliasGlcmds(order, order + paliashdr->num_glcmds,
		    alpha, skin, verts, paliashdr->num_xyz, ubo_off, shell, translucent, lefthand);
	}
}

/*
 * Frustum culls the model with a per-frame bounding box (ref_vk
 * R_CullAliasModel): the frame and oldframe translate/scale extents are
 * combined into an axis-aligned box, its 8 corners are rotated into view
 * space (yaw negated, matching the entity rotation) and offset by the
 * origin, then tested against the 4 frustum planes with an aggregate
 * mask.
 */
static qboolean
R_CullAliasModel(vec3_t bbox[8], entity_t *e, const model_t *currentmodel)
{
	int i;
	vec3_t mins, maxs;
	dmdl_t *paliashdr;
	vec3_t vectors[3];
	vec3_t thismins, oldmins, thismaxs, oldmaxs;
	daliasframe_t *pframe, *poldframe;
	vec3_t angles;

	paliashdr = (dmdl_t *)currentmodel->extradata;

	if ((e->frame >= paliashdr->num_frames) || (e->frame < 0))
	{
		Com_Printf("R_CullAliasModel %s: no such frame %d\n",
		    currentmodel->name, e->frame);
		e->frame = 0;
	}
	if ((e->oldframe >= paliashdr->num_frames) || (e->oldframe < 0))
	{
		Com_Printf("R_CullAliasModel %s: no such oldframe %d\n",
		    currentmodel->name, e->oldframe);
		e->oldframe = 0;
	}

	pframe = (daliasframe_t *)((byte *)paliashdr +
	    paliashdr->ofs_frames + e->frame * paliashdr->framesize);

	poldframe = (daliasframe_t *)((byte *)paliashdr +
	    paliashdr->ofs_frames + e->oldframe * paliashdr->framesize);

	/*
	** compute axially aligned mins and maxs
	*/
	if (pframe == poldframe)
	{
		for (i = 0; i < 3; i++)
		{
			mins[i] = pframe->translate[i];
			maxs[i] = mins[i] + pframe->scale[i]*255;
		}
	}
	else
	{
		for (i = 0; i < 3; i++)
		{
			thismins[i] = pframe->translate[i];
			thismaxs[i] = thismins[i] + pframe->scale[i]*255;

			oldmins[i] = poldframe->translate[i];
			oldmaxs[i] = oldmins[i] + poldframe->scale[i]*255;

			if (thismins[i] < oldmins[i])
				mins[i] = thismins[i];
			else
				mins[i] = oldmins[i];

			if (thismaxs[i] > oldmaxs[i])
				maxs[i] = thismaxs[i];
			else
				maxs[i] = oldmaxs[i];
		}
	}

	/*
	** compute a full bounding box
	*/
	for (i = 0; i < 8; i++)
	{
		vec3_t tmp;

		if (i & 1)
			tmp[0] = mins[0];
		else
			tmp[0] = maxs[0];

		if (i & 2)
			tmp[1] = mins[1];
		else
			tmp[1] = maxs[1];

		if (i & 4)
			tmp[2] = mins[2];
		else
			tmp[2] = maxs[2];

		VectorCopy(tmp, bbox[i]);
	}

	/*
	** rotate the bounding box
	*/
	VectorCopy(e->angles, angles);
	angles[YAW] = -angles[YAW];
	AngleVectors(angles, vectors[0], vectors[1], vectors[2]);

	for (i = 0; i < 8; i++)
	{
		vec3_t tmp;

		VectorCopy(bbox[i], tmp);

		bbox[i][0] = DotProduct(vectors[0], tmp);
		bbox[i][1] = -DotProduct(vectors[1], tmp);
		bbox[i][2] = DotProduct(vectors[2], tmp);

		VectorAdd(e->origin, bbox[i], bbox[i]);
	}

	{
		int p, f, aggregatemask = ~0;

		for (p = 0; p < 8; p++)
		{
			int mask = 0;

			for (f = 0; f < 4; f++)
			{
				float dp = DotProduct(frustum[f].normal, bbox[p]);

				if ((dp - frustum[f].dist) < 0)
				{
					mask |= (1 << f);
				}
			}

			aggregatemask &= mask;
		}

		return aggregatemask != 0;
	}
}

/*
 * Draws one alias model (ref_vk R_DrawAliasModel, minus the deferred
 * depthhack/lefthand/shadow paths).
 */
void
R_DrawAliasModel(entity_t *currententity, const model_t *currentmodel)
{
	int i;
	dmdl_t *paliashdr;

	if (!(currententity->flags & RF_WEAPONMODEL))
	{
		vec3_t bbox[8];

		if (R_CullAliasModel(bbox, currententity, currentmodel))
			return;
	}
	else if (r_lefthand->value == 2)
	{
		/* I2: hand 2 hides the view weapon (ref_vk's early return) */
		return;
	}

	paliashdr = (dmdl_t *)currentmodel->extradata;

	/*
	 * get lighting information
	 */
	if (currententity->flags & (RF_SHELL_HALF_DAM | RF_SHELL_GREEN | RF_SHELL_RED | RF_SHELL_BLUE | RF_SHELL_DOUBLE))
	{
		VectorClear(shadelight);
		if (currententity->flags & RF_SHELL_HALF_DAM)
		{
			shadelight[0] = 0.56;
			shadelight[1] = 0.59;
			shadelight[2] = 0.45;
		}
		if (currententity->flags & RF_SHELL_DOUBLE)
		{
			shadelight[0] = 0.9;
			shadelight[1] = 0.7;
		}
		if (currententity->flags & RF_SHELL_RED)
			shadelight[0] = 1.0;
		if (currententity->flags & RF_SHELL_GREEN)
			shadelight[1] = 1.0;
		if (currententity->flags & RF_SHELL_BLUE)
			shadelight[2] = 1.0;
	}
	else if (currententity->flags & RF_FULLBRIGHT)
	{
		for (i = 0; i < 3; i++)
			shadelight[i] = 1.0;
	}
	else
	{
		R_LightPoint(r_worldmodel->grid, currententity->origin, shadelight, currententity);

		/* player lighting hack for communication back to server */
		if (currententity->flags & RF_WEAPONMODEL)
		{
			if (shadelight[0] > shadelight[1])
			{
				if (shadelight[0] > shadelight[2])
					r_lightlevel->value = 150*shadelight[0];
				else
					r_lightlevel->value = 150*shadelight[2];
			}
			else
			{
				if (shadelight[1] > shadelight[2])
					r_lightlevel->value = 150*shadelight[1];
				else
					r_lightlevel->value = 150*shadelight[2];
			}
		}
	}

	if (currententity->flags & RF_MINLIGHT)
	{
		for (i = 0; i < 3; i++)
			if (shadelight[i] > 0.1)
				break;
		if (i == 3)
		{
			shadelight[0] = 0.1;
			shadelight[1] = 0.1;
			shadelight[2] = 0.1;
		}
	}

	if (currententity->flags & RF_GLOW)
	{
		/* bonus items will pulse with time */
		float scale;

		scale = 0.1 * sin(r_newrefdef.time * 7);

		for (i = 0; i < 3; i++)
		{
			float min;

			min = shadelight[i] * 0.8;
			shadelight[i] += scale;

			if (shadelight[i] < min)
			{
				shadelight[i] = min;
			}
		}
	}

	/* ir goggles color override */
	if ((r_newrefdef.rdflags & RDF_IRGOGGLES) &&
	    (currententity->flags & RF_IR_VISIBLE))
	{
		shadelight[0] = 1.0;
		shadelight[1] = 0.0;
		shadelight[2] = 0.0;
	}

	shadedots = r_avertexnormal_dots[((int)(currententity->angles[1] * (SHADEDOT_QUANT / 360.0))) & (SHADEDOT_QUANT - 1)];

	/* locate the proper data */
	c_alias_polys += paliashdr->num_tris;

	currententity->angles[PITCH] = -currententity->angles[PITCH];	// sigh.
	{
		float model[16];
		image_t *skin;

		Mat_Identity(model);
		R_RotateForEntity(currententity, model);

		currententity->angles[PITCH] = -currententity->angles[PITCH];	// sigh.

		/* select skin */
		if (currententity->skin)
		{
			skin = currententity->skin;	/* custom player skin */
		}
		else
		{
			if (currententity->skinnum >= MAX_MD2SKINS)
				skin = currentmodel->skins[0];
			else
			{
				skin = currentmodel->skins[currententity->skinnum];
				if (!skin)
					skin = currentmodel->skins[0];
			}
		}

		if (!skin)
		{
			skin = r_notexture;	/* fallback */
		}

		/* clamp the frames (also done in R_CullAliasModel, but the
		   culled path is skipped for RF_WEAPONMODEL) */
		if ((currententity->frame >= paliashdr->num_frames)
		    || (currententity->frame < 0))
		{
			Com_Printf("R_DrawAliasModel %s: no such frame %d\n",
			    currentmodel->name, currententity->frame);
			currententity->frame = 0;
			currententity->oldframe = 0;
		}

		if ((currententity->oldframe >= paliashdr->num_frames)
		    || (currententity->oldframe < 0))
		{
			Com_Printf("R_DrawAliasModel %s: no such oldframe %d\n",
			    currentmodel->name, currententity->oldframe);
			currententity->frame = 0;
			currententity->oldframe = 0;
		}

		if (!r_lerpmodels->value)
		{
			currententity->backlerp = 0;
		}

		/* I2: RF_DEPTHHACK / RDF_NOWORLDMODEL entities draw with the
		   compressed-depth projection; hand 1 mirrors the view weapon
		   in X (ref_vk Mat_Scale(viewproj, -1, 1, 1) on top of the
		   depth-hack variant when both apply). r_viewproj_matrix is
		   never touched: the alias UBO record captures whichever
		   matrix this entity draws with. */
		{
			float viewproj[16];

			if ((currententity->flags & RF_DEPTHHACK) ||
			    (r_newrefdef.rdflags & RDF_NOWORLDMODEL))
			{
				MTL_BuildDepthHackViewproj(currententity, viewproj);
			}
			else
			{
				memcpy(viewproj, r_viewproj_matrix, sizeof(viewproj));
			}

			if ((currententity->flags & RF_WEAPONMODEL) && r_lefthand->value == 1.0f)
			{
				Mat_Scale(viewproj, -1.f, 1.f, 1.f);
			}

			MTL_DrawAliasFrameLerp(paliashdr, currententity->backlerp, skin,
			    model, viewproj, currententity);
		}
	}
}

/*
 * Draws one sprite (ref_vk R_DrawSpriteModel): a camera-facing quad built
 * from vup/vright around the entity origin, in world space (no model
 * matrix), with per-vertex color white * alpha. Six 36-byte vertices ride
 * on the alias ring; the UBO carries viewproj + gamma, and the fragment
 * discards pixels whose blended alpha drops below 0.0666.
 */
void
R_DrawSpriteModel(entity_t *currententity, const model_t *currentmodel)
{
	mtlstate_t *st = &mtl_state;
	float alpha = 1.0F;
	vec3_t point;
	dsprframe_t *frame;
	dsprite_t *psprite;
	image_t *skin;
	size_t slot, vstart;
	aliasvert_t *dst;
	size_t ubo_off;
	int i;
	float quad[4][3];

	if (st->encoder == nil)
		return;

	/* don't even bother culling, because it's just
	   a single polygon without a surface cache */
	psprite = (dsprite_t *)currentmodel->extradata;

	currententity->frame %= psprite->numframes;
	frame = &psprite->frames[currententity->frame];

	if (currententity->flags & RF_TRANSLUCENT)
	{
		alpha = currententity->alpha;
	}

	/* normal sprite: billboard corners in the vup/vright plane */
	VectorMA(currententity->origin, -frame->origin_y, vup, point);
	VectorMA(point, -frame->origin_x, vright, quad[0]);
	VectorMA(currententity->origin, frame->height - frame->origin_y, vup, point);
	VectorMA(point, -frame->origin_x, vright, quad[1]);
	VectorMA(currententity->origin, frame->height - frame->origin_y, vup, point);
	VectorMA(point, frame->width - frame->origin_x, vright, quad[2]);
	VectorMA(currententity->origin, -frame->origin_y, vup, point);
	VectorMA(point, frame->width - frame->origin_x, vright, quad[3]);

	skin = currentmodel->skins[currententity->frame];
	if (!skin)
	{
		skin = r_notexture;	/* fallback */
	}
	if (skin->mtl_texture == nil)
		return;

	slot = st->frame_slot;
	vstart = st->alias_vertex_offset[slot];
	if (vstart + 6 * sizeof(aliasvert_t) > ALIAS_VERTEX_RING_BYTES)
		return;	/* ring exhausted */

	ubo_off = MTL_EmitSpriteUbo(slot);
	if (ubo_off == SIZE_MAX)
		return;	/* UBO ring exhausted */

	/* triangle list: p0,p1,p2 / p0,p2,p3 (ref_vk sprite quadVerts) */
	{
		static const int order[6] = { 0, 1, 2, 0, 2, 3 };
		static const float uvs[6][2] = {
			{ 0.f, 1.f }, { 0.f, 0.f }, { 1.f, 0.f },
			{ 0.f, 1.f }, { 1.f, 0.f }, { 1.f, 1.f }
		};

		dst = (aliasvert_t *)st->alias_vertex_buffer[slot].contents + vstart / sizeof(aliasvert_t);
		for (i = 0; i < 6; i++)
		{
			dst->position[0] = quad[order[i]][0];
			dst->position[1] = quad[order[i]][1];
			dst->position[2] = quad[order[i]][2];
			dst->uv[0] = uvs[i][0];
			dst->uv[1] = uvs[i][1];
			dst->color[0] = 1.f;
			dst->color[1] = 1.f;
			dst->color[2] = 1.f;
			dst->color[3] = alpha;
			dst++;
		}
	}
	st->alias_vertex_offset[slot] += 6 * sizeof(aliasvert_t);

	[st->encoder setVertexBuffer:st->alias_vertex_buffer[slot]
		offset:vstart atIndex:0];
	[st->encoder setVertexBuffer:st->world_ubo[slot]
		offset:ubo_off atIndex:1];
	[st->encoder setFragmentTexture:skin->mtl_texture atIndex:0];
	[st->encoder setFragmentBuffer:st->world_ubo[slot]
		offset:ubo_off atIndex:0];

	[st->encoder setRenderPipelineState:st->pipeline_sprite];
	[st->encoder setDepthStencilState:st->depth_state];
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

/* One beam tube vertex: position plus the beam's flat RGBA color. The
   component-by-component copy is deliberate: an I1-development
   revision fed the ring corners through an array of `const vec3_t *`
   with VectorCopy(*tri[k], dst), and the components loaded at byte
   offsets 0/12/24 - a vertex holding the x components of three
   neighbouring ring points. An earlier J2 note here blamed this
   host's clang; that was wrong (K1): shared.h defines
   VectorCopy(a, b) with unparenthesised arguments, so the expansion
   `*tri[k][j]` parses as the valid C `*(tri[k][j])` - with
   `const vec3_t *tri[]` that indexes j whole vec3_t elements
   (pointer-to-array arithmetic, 12-byte steps) and decays to that
   element's first float. Present at -O0, silent under UBSan, and
   the explicit (*tri[k])[j] form compiles correctly. The macro is
   byte-identical upstream (yquake2/ref_vk shared.h); no call site
   in any tree passes a *- or &-prefixed or ternary argument, so
   only this comment records the trap. Explicit component copies
   stay. */
static void
MTL_PutBeamVert(beamvert_t *v, const vec3_t p, const float *color)
{
	v->vertex[0] = p[0];
	v->vertex[1] = p[1];
	v->vertex[2] = p[2];
	v->color[0] = color[0];
	v->color[1] = color[1];
	v->color[2] = color[2];
	v->color[3] = color[3];
}

/*
 * Draws one RF_BEAM entity (ref_vk R_DrawBeam, vk_main.c): a 6-sided
 * tube between origin and oldorigin, radius frame/2, flat color from
 * d_8to24table[skinnum & 0xFF] at entity alpha. ref_vk draws the ring
 * pairs (s_i, e_i, s_i+1, e_i+1) as a 24-vertex triangle strip; the
 * strip parity rule turns each side into the triangles
 * (s_i, e_i, s_i+1) and (s_i+1, e_i, e_i+1) - the odd strip triangle
 * swaps the last two corners of the quad - plus degenerate connector
 * triangles at the segment seams. mtl expands the same pair into its
 * 36-vertex triangle-list convention; the pair shares one winding, so
 * back-culling keeps the front half of the tube and the silhouette
 * matches vk. (An earlier revision paired (s_i+1, e_i+1, e_i), which
 * flips orientation per quad and leaves half of every side culled.)
 * Drawn with the beam pipeline (standard alpha blend, matching the vk
 * beam pipeline) and no depth writes, under a clockwise front winding
 * and back-face culling: vk's global frontFace is CLOCKWISE and the
 * beam pipeline keeps the default CULL_MODE_BACK (QVk_CreatePipeline).
 * Culling must stay on: the TE_LASER beam is drawn translucent
 * (cl_laseralpha, default 0.3), and without culling the back half of
 * the tube blends under the front half - the jail1 test laser measured
 * ~1.8x the vk core color density with culling off. The encoder state
 * is restored to the pass baseline afterwards (see the K2 note below
 * the draw).
 */
static void
R_DrawBeam(entity_t *currententity)
{
#define NUM_BEAM_SEGS 6

	mtlstate_t *st = &mtl_state;
	vec3_t perpvec;
	vec3_t direction, normalized_direction;
	vec3_t start_points[NUM_BEAM_SEGS], end_points[NUM_BEAM_SEGS];
	vec3_t oldorigin, origin;
	float color[4];
	beamvert_t *dst;
	size_t slot, vstart, ubo_off;
	int i;

	if (st->encoder == nil || st->pipeline_beam == nil)
	{
		return;
	}

	VectorCopy(currententity->oldorigin, oldorigin);
	VectorCopy(currententity->origin, origin);

	VectorSubtract(oldorigin, origin, direction);
	VectorCopy(direction, normalized_direction);

	if (VectorNormalize(normalized_direction) == 0)
	{
		return;
	}

	PerpendicularVector(perpvec, normalized_direction);
	VectorScale(perpvec, currententity->frame / 2, perpvec);

	for (i = 0; i < NUM_BEAM_SEGS; i++)
	{
		RotatePointAroundVector(start_points[i], normalized_direction,
		    perpvec, (360.0 / NUM_BEAM_SEGS) * i);
		VectorAdd(start_points[i], origin, start_points[i]);
		VectorAdd(start_points[i], direction, end_points[i]);
	}

	{
		unsigned int pal = d_8to24table[currententity->skinnum & 0xFF];

		color[0] = (float)(pal & 0xFF) * (1.0 / 255.0);
		color[1] = (float)((pal >> 8) & 0xFF) * (1.0 / 255.0);
		color[2] = (float)((pal >> 16) & 0xFF) * (1.0 / 255.0);
		color[3] = currententity->alpha;
	}

	slot = st->frame_slot;
	vstart = st->beam_vertex_offset[slot];
	if (vstart + 36 * sizeof(beamvert_t) > BEAM_VERTEX_RING_BYTES)
	{
		return;	/* ring exhausted, skip this beam */
	}

	ubo_off = MTL_EmitViewProjUbo(slot);
	if (ubo_off == SIZE_MAX)
	{
		return;	/* UBO ring exhausted */
	}

	dst = (beamvert_t *)st->beam_vertex_buffer[slot].contents +
	    vstart / sizeof(beamvert_t);
	for (i = 0; i < NUM_BEAM_SEGS; i++)
	{
		const int next = (i + 1) % NUM_BEAM_SEGS;

		MTL_PutBeamVert(dst++, start_points[i], color);
		MTL_PutBeamVert(dst++, end_points[i], color);
		MTL_PutBeamVert(dst++, start_points[next], color);
		MTL_PutBeamVert(dst++, start_points[next], color);
		MTL_PutBeamVert(dst++, end_points[i], color);
		MTL_PutBeamVert(dst++, end_points[next], color);
	}
	st->beam_vertex_offset[slot] += 36 * sizeof(beamvert_t);

	[st->encoder setVertexBuffer:st->beam_vertex_buffer[slot]
		offset:vstart atIndex:0];
	[st->encoder setVertexBuffer:st->world_ubo[slot]
		offset:ubo_off atIndex:1];

	[st->encoder setDepthStencilState:st->depth_state_nodwrite];
	[st->encoder setFrontFacingWinding:MTLWindingClockwise];
	[st->encoder setCullMode:MTLCullModeBack];

	[st->encoder setRenderPipelineState:st->pipeline_beam];
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36];

	/* K2: restore the pass baseline (MTL_SetPassDefaults: Clockwise +
	   culling disabled, Metal's documented fresh-encoder state). Draw
	   order must not be load-bearing: every special draw sets its own
	   winding + cull pair before drawPrimitives and restores right
	   after. The beam's own CW + back-cull above is deliberate, not
	   baseline: the constructed tube quads face Clockwise under mtl's
	   projection and must be culled so the translucent laser core
	   blends once, matching vk (global CW frontFace + the fan
	   pipeline's BACK default, qvk.h). */
	[st->encoder setDepthStencilState:st->depth_state];
	MTL_SetPassDefaults(st->encoder);
}

/*
 * Walks the refdef entity list and draws the non-world entities (ref_vk
 * R_DrawEntitiesOnList): opaque first, translucent second. The world
 * itself is r_newrefdef.entities[0] and was already drawn by
 * R_DrawWorld. RF_BEAM entities are drawn as tubes (see R_DrawBeam),
 * in both passes like ref_vk (beams are often RF_TRANSLUCENT).
 */
void
R_DrawEntitiesOnList(void)
{
	int i;

	if (!r_drawentities->value)
	{
		return;
	}

	/* draw non-transparent first */
	for (i = 0; i < r_newrefdef.num_entities; i++)
	{
		entity_t *currententity = &r_newrefdef.entities[i];

		if (currententity->flags & RF_TRANSLUCENT)
		{
			continue; /* solid */
		}

		if (currententity->flags & RF_BEAM)
		{
			R_DrawBeam(currententity);
			continue;
		}

		{
			const model_t *currentmodel = currententity->model;

			if (!currentmodel)
			{
				continue;
			}

			switch (currentmodel->type)
			{
				case mod_alias:
					R_DrawAliasModel(currententity, currentmodel);
					break;
				case mod_brush:
					R_DrawBrushModel(currententity, currentmodel);
					break;
				case mod_sprite:
					R_DrawSpriteModel(currententity, currentmodel);
					break;
				default:
					Com_Printf("R_DrawEntitiesOnList: Bad modeltype %d\n",
					    currentmodel->type);
					return;
			}
		}
	}

	/* draw transparent entities */
	for (i = 0; i < r_newrefdef.num_entities; i++)
	{
		entity_t *currententity = &r_newrefdef.entities[i];

		if (!(currententity->flags & RF_TRANSLUCENT))
		{
			continue; /* solid */
		}

		if (currententity->flags & RF_BEAM)
		{
			R_DrawBeam(currententity);
			continue;
		}

		{
			const model_t *currentmodel = currententity->model;

			if (!currentmodel)
			{
				continue;
			}

			switch (currentmodel->type)
			{
				case mod_alias:
					R_DrawAliasModel(currententity, currentmodel);
					break;
				case mod_brush:
					R_DrawBrushModel(currententity, currentmodel);
					break;
				case mod_sprite:
					R_DrawSpriteModel(currententity, currentmodel);
					break;
				default:
					Com_Printf("R_DrawEntitiesOnList: Bad modeltype %d\n",
					    currentmodel->type);
					return;
			}
		}
	}
}
