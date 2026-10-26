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
 * Refresher setup and main part of the frame generation.
 *
 * W1: device/queue/surface setup and first clear-color frame.
 *
 * =======================================================================
 */

#include "header/mtl.h"
#include "header/mtl_shaders.h"

#define REF_VERSION "Yamagi Quake II Metal 4 Refresher " MTL_VERSION

viddef_t vid;

refimport_t ri;

mtlstate_t mtl_state;

model_t		*r_worldmodel;

cplane_t	frustum[4];

int			r_visframecount;	// bumped when going to a new PVS
int			r_framecount;		// used for dlight push checking

int			c_brush_polys, c_alias_polys;

static float	v_blend[4];		// final blending color

//
// view origin
//
vec3_t	vup;
vec3_t	vpn;
vec3_t	vright;
vec3_t	r_origin;

float	r_view_matrix[16];
float	r_projection_matrix[16];
float	r_viewproj_matrix[16];
// correction matrix for perspective in Metal 4 (see Mat_Perspective)
static float r_metal_correction[16] = { 1.f, 0.f, 0.f, 0.f,
                                        0.f, 1.f, 0.f, 0.f,
                                        0.f, 0.f, .5f, .5f,
                                        0.f, 0.f, 0.f, 1.f
                                      };

//
// screen size info
//
refdef_t	r_newrefdef;

int		r_viewcluster, r_viewcluster2, r_oldviewcluster, r_oldviewcluster2;

//
// cvars
//
cvar_t		*r_vsync;
static cvar_t	*r_mode;
static cvar_t	*r_customwidth;
static cvar_t	*r_customheight;
cvar_t		*vid_fullscreen;
cvar_t		*vid_gamma;
cvar_t		*viewsize;

cvar_t		*r_lefthand;
cvar_t		*r_drawworld;
cvar_t		*r_drawentities;
cvar_t		*r_novis;
cvar_t		*r_lerpmodels;
cvar_t		*r_lockpvs;
cvar_t		*r_modulate;
cvar_t		*r_clear;
cvar_t		*r_lightlevel;
cvar_t		*r_gunfov;
cvar_t		*r_farsee;

cvar_t		*mtl_overbrightbits;
cvar_t		*r_validation;
cvar_t		*r_cull;
cvar_t		*mtl_picmip;
cvar_t		*r_palettedtexture;
cvar_t		*mtl_flashblend;
cvar_t		*mtl_polyblend;
cvar_t		*mtl_dynamic;
cvar_t		*mtl_showtris;
cvar_t		*r_lightmap;
cvar_t		*mtl_mip_nearfilter;
cvar_t		*r_retexturing;
cvar_t		*r_scale8bittextures;
cvar_t		*r_nolerp_list;
cvar_t		*r_lerp_list;
cvar_t		*r_2D_unfiltered;
cvar_t		*r_videos_unfiltered;
cvar_t		*r_fixsurfsky;

/*
==============
R_Register

Registers the cvars the renderer owns. Every cvar referenced by the
mtl sources (see the externs in mtl.h) is registered here.
==============
*/
static void
R_Register(void)
{
	/* Init default value */
	s_blocklights = NULL;
	s_blocklights_max = NULL;

	r_lefthand = ri.Cvar_Get("hand", "0", CVAR_USERINFO | CVAR_ARCHIVE);
	r_drawworld = ri.Cvar_Get("r_drawworld", "1", 0);
	r_drawentities = ri.Cvar_Get("r_drawentities", "1", 0);
	r_novis = ri.Cvar_Get("r_novis", "0", 0);
	r_cull = ri.Cvar_Get("r_cull", "1", 0);
	r_lerpmodels = ri.Cvar_Get("r_lerpmodels", "1", 0);
	r_lightlevel = ri.Cvar_Get("r_lightlevel", "0", 0);
	r_mode = ri.Cvar_Get("r_mode", "11", CVAR_ARCHIVE);
	r_vsync = ri.Cvar_Get("r_vsync", "0", CVAR_ARCHIVE);
	r_gunfov = ri.Cvar_Get("r_gunfov", "80", CVAR_ARCHIVE);
	r_farsee = ri.Cvar_Get("r_farsee", "0", CVAR_LATCH | CVAR_ARCHIVE);
	r_customwidth = ri.Cvar_Get("r_customwidth", "1024", CVAR_ARCHIVE);
	r_customheight = ri.Cvar_Get("r_customheight", "768", CVAR_ARCHIVE);

	mtl_overbrightbits = ri.Cvar_Get("mtl_overbrightbits", "1.0", CVAR_ARCHIVE);
	r_validation = ri.Cvar_Get("r_validation", "0", CVAR_ARCHIVE);
	mtl_picmip = ri.Cvar_Get("mtl_picmip", "0", 0);
	r_palettedtexture = ri.Cvar_Get("r_palettedtexture", "0", 0);
	mtl_flashblend = ri.Cvar_Get("mtl_flashblend", "0", 0);
	mtl_polyblend = ri.Cvar_Get("mtl_polyblend", "1", 0);
	r_clear = ri.Cvar_Get("r_clear", "0", CVAR_ARCHIVE);
	r_lockpvs = ri.Cvar_Get("r_lockpvs", "0", 0);
	r_modulate = ri.Cvar_Get("r_modulate", "1", CVAR_ARCHIVE);
	mtl_dynamic = ri.Cvar_Get("mtl_dynamic", "1", 0);
	mtl_showtris = ri.Cvar_Get("mtl_showtris", "0", 0);
	r_lightmap = ri.Cvar_Get("r_lightmap", "0", 0);
	mtl_mip_nearfilter = ri.Cvar_Get("mtl_mip_nearfilter", "0", CVAR_ARCHIVE);
	r_retexturing = ri.Cvar_Get("r_retexturing", "1", CVAR_ARCHIVE);
	r_scale8bittextures = ri.Cvar_Get("r_scale8bittextures", "0", CVAR_ARCHIVE);
	/* don't bilerp characters and crosshairs */
	r_nolerp_list = ri.Cvar_Get("r_nolerp_list", DEFAULT_NOLERP_LIST, CVAR_ARCHIVE);
	/* textures that should always be filtered, even if r_2D_unfiltered or an unfiltered gl mode is used */
	r_lerp_list = ri.Cvar_Get("r_lerp_list", "", CVAR_ARCHIVE);
	/* don't bilerp any 2D elements */
	r_2D_unfiltered = ri.Cvar_Get("r_2D_unfiltered", "0", CVAR_ARCHIVE);
	/* don't bilerp videos */
	r_videos_unfiltered = ri.Cvar_Get("r_videos_unfiltered", "0", CVAR_ARCHIVE);
	r_fixsurfsky = ri.Cvar_Get("r_fixsurfsky", "0", CVAR_ARCHIVE);

	vid_fullscreen = ri.Cvar_Get("vid_fullscreen", "0", CVAR_ARCHIVE);
	vid_gamma = ri.Cvar_Get("vid_gamma", "1.0", CVAR_ARCHIVE);
	viewsize = ri.Cvar_Get("viewsize", "100", CVAR_ARCHIVE);
}

/*
==============
Matrix helpers (ported from ref_vk, row-major)

The view matrix (see R_SetupFrame) puts +z "going up" of the Quake world
along -z of the view space; the frustum matrix is then converted to the
Metal 4 coordinate system (NDC x right, y up, depth [0..1]) by
r_metal_correction.
==============
*/
void Mat_Identity(float *matrix)
{
	matrix[0] = 1.f;
	matrix[1] = 0.f;
	matrix[2] = 0.f;
	matrix[3] = 0.f;
	matrix[4] = 0.f;
	matrix[5] = 1.f;
	matrix[6] = 0.f;
	matrix[7] = 0.f;
	matrix[8] = 0.f;
	matrix[9] = 0.f;
	matrix[10] = 1.f;
	matrix[11] = 0.f;
	matrix[12] = 0.f;
	matrix[13] = 0.f;
	matrix[14] = 0.f;
	matrix[15] = 1.f;
}

void Mat_Mul(float *m1, float *m2, float *res)
{
	float mul[16] = { m1[0] * m2[0] + m1[1] * m2[4] + m1[2] * m2[8] + m1[3] * m2[12],
					  m1[0] * m2[1] + m1[1] * m2[5] + m1[2] * m2[9] + m1[3] * m2[13],
					  m1[0] * m2[2] + m1[1] * m2[6] + m1[2] * m2[10] + m1[3] * m2[14],
					  m1[0] * m2[3] + m1[1] * m2[7] + m1[2] * m2[11] + m1[3] * m2[15],
					  m1[4] * m2[0] + m1[5] * m2[4] + m1[6] * m2[8] + m1[7] * m2[12],
					  m1[4] * m2[1] + m1[5] * m2[5] + m1[6] * m2[9] + m1[7] * m2[13],
					  m1[4] * m2[2] + m1[5] * m2[6] + m1[6] * m2[10] + m1[7] * m2[14],
					  m1[4] * m2[3] + m1[5] * m2[7] + m1[6] * m2[11] + m1[7] * m2[15],
					  m1[8] * m2[0] + m1[9] * m2[4] + m1[10] * m2[8] + m1[11] * m2[12],
					  m1[8] * m2[1] + m1[9] * m2[5] + m1[10] * m2[9] + m1[11] * m2[13],
					  m1[8] * m2[2] + m1[9] * m2[6] + m1[10] * m2[10] + m1[11] * m2[14],
					  m1[8] * m2[3] + m1[9] * m2[7] + m1[10] * m2[11] + m1[11] * m2[15],
					  m1[12] * m2[0] + m1[13] * m2[4] + m1[14] * m2[8] + m1[15] * m2[12],
					  m1[12] * m2[1] + m1[13] * m2[5] + m1[14] * m2[9] + m1[15] * m2[13],
					  m1[12] * m2[2] + m1[13] * m2[6] + m1[14] * m2[10] + m1[15] * m2[14],
					  m1[12] * m2[3] + m1[13] * m2[7] + m1[14] * m2[11] + m1[15] * m2[15]
	};

	memcpy(res, mul, sizeof(float) * 16);
}

void Mat_Translate(float *matrix, float x, float y, float z)
{
	float t[16] = { 1.f, 0.f, 0.f, 0.f,
					0.f, 1.f, 0.f, 0.f,
					0.f, 0.f, 1.f, 0.f,
					  x,   y,   z, 1.f };

	Mat_Mul(matrix, t, matrix);
}

void Mat_Rotate(float *matrix, float deg, float x, float y, float z)
{
	double c = cos(deg * M_PI / 180.0);
	double s = sin(deg * M_PI / 180.0);
	double cd = 1.0 - c;
	vec3_t r = { x, y, z };
	VectorNormalize(r);

	float rot[16] = { r[0]*r[0]*cd + c,		 r[1]*r[0]*cd + r[2]*s, r[0]*r[2]*cd - r[1]*s,	0.f,
					  r[0]*r[1]*cd - r[2]*s, r[1]*r[1]*cd + c,		r[1]*r[2]*cd + r[0]*s,	0.f,
					  r[0]*r[2]*cd + r[1]*s, r[1]*r[2]*cd - r[0]*s, r[2]*r[2]*cd + c,		0.f,
					  0.f,					 0.f,					0.f,					1.f
	};

	Mat_Mul(matrix, rot, matrix);
}

void Mat_Scale(float *matrix, float x, float y, float z)
{
	float s[16] = {   x, 0.f, 0.f, 0.f,
					0.f,   y, 0.f, 0.f,
					0.f, 0.f,   z, 0.f,
					0.f, 0.f, 0.f, 1.f
	};

	Mat_Mul(matrix, s, matrix);
}

void Mat_Perspective(float *matrix, float *correction_matrix, float fovy, float aspect,
	float zNear, float zFar)
{
	float xmin, xmax, ymin, ymax;

	ymax = zNear * tan(fovy * M_PI / 360.0);
	ymin = -ymax;

	xmin = ymin * aspect;
	xmax = ymax * aspect;

	xmin += -(2 * mtl_state.camera_separation) / zNear;
	xmax += -(2 * mtl_state.camera_separation) / zNear;

	float proj[16];
	memset(proj, 0, sizeof(float) * 16);
	proj[0] = 2.f * zNear / (xmax - xmin);
	proj[2] = (xmax + xmin) / (xmax - xmin);
	proj[5] = 2.f * zNear / (ymax - ymin);
	proj[6] = (ymax + ymin) / (ymax - ymin);
	proj[10] = -(zFar + zNear) / (zFar - zNear);
	proj[11] = -1.f;
	proj[14] = -2.f * zFar * zNear / (zFar - zNear);

	// Convert projection matrix to Metal 4 coordinate system
	Mat_Mul(proj, correction_matrix, matrix);
}

void Mat_Ortho(float *matrix, float left, float right, float bottom, float top,
			   float zNear, float zFar)
{
	float proj[16];
	memset(proj, 0, sizeof(float) * 16);
	proj[0] = 2.f / (right - left);
	proj[3] = (right + left) / (right - left);
	proj[5] = 2.f / (top - bottom);
	proj[7] = (top + bottom) / (top - bottom);
	proj[10] = -2.f / (zFar - zNear);
	proj[11] = -(zFar + zNear) / (zFar - zNear);
	proj[15] = 1.f;

	// Convert projection matrix to Metal 4 coordinate system
	Mat_Mul(proj, r_metal_correction, matrix);
}

/*
==============
R_SetupFrame

Sets up the per-frame view state: view origin, viewcluster and the
view/projection matrices. W3.0: defined for the W4 draw path but not
called at runtime yet (RE_RenderFrame is a clear-only pass).
==============
*/
void
R_SetupFrame(void)
{
	int i;
	mleaf_t *leaf;

	r_framecount++;

	/* build the transformation matrix for the given view angles */
	VectorCopy(r_newrefdef.vieworg, r_origin);

	AngleVectors(r_newrefdef.viewangles, vpn, vright, vup);

	/* current viewcluster */
	if (!(r_newrefdef.rdflags & RDF_NOWORLDMODEL))
	{
		if (!r_worldmodel)
		{
			Com_Error(ERR_DROP, "%s: bad world model", __func__);
			return;
		}

		r_oldviewcluster = r_viewcluster;
		r_oldviewcluster2 = r_viewcluster2;
		leaf = Mod_PointInLeaf(r_origin, r_worldmodel->nodes);
		r_viewcluster = r_viewcluster2 = leaf->cluster;

		/* check above and below so crossing solid water doesn't draw wrong */
		if (!leaf->contents)
		{
			/* look down a bit */
			vec3_t temp;

			VectorCopy(r_origin, temp);
			temp[2] -= 16;
			leaf = Mod_PointInLeaf(temp, r_worldmodel->nodes);

			if (!(leaf->contents & CONTENTS_SOLID) &&
				(leaf->cluster != r_viewcluster2))
			{
				r_viewcluster2 = leaf->cluster;
			}
		}
		else
		{
			/* look up a bit */
			vec3_t temp;

			VectorCopy(r_origin, temp);
			temp[2] += 16;
			leaf = Mod_PointInLeaf(temp, r_worldmodel->nodes);

			if (!(leaf->contents & CONTENTS_SOLID) &&
				(leaf->cluster != r_viewcluster2))
			{
				r_viewcluster2 = leaf->cluster;
			}
		}
	}

	for (i = 0; i < 4; i++)
	{
		v_blend[i] = r_newrefdef.blend[i];
	}

	c_brush_polys = 0;
	c_alias_polys = 0;

	/* W3.0: the RDF_NOWORLDMODEL clear rectangle is a no-op; the full
	   clear happens in RE_RenderFrame. */

	// set up projection matrix
	{
		float dist;

		if (r_farsee->value)
		{
			dist = 4096;
		}
		else
		{
			dist = r_newrefdef.width / tan(r_newrefdef.fov_x * M_PI / 360);
		}

		Mat_Perspective(r_projection_matrix, r_metal_correction,
			r_newrefdef.fov_y, (float)r_newrefdef.width / r_newrefdef.height, 4, dist);
	}

	R_SetFrustum(vup, vpn, vright, r_origin, r_newrefdef.fov_x, r_newrefdef.fov_y,
		frustum);

	// set up view matrix
	Mat_Identity(r_view_matrix);
	// put Z going up
	Mat_Translate(r_view_matrix, -r_newrefdef.vieworg[0], -r_newrefdef.vieworg[1], -r_newrefdef.vieworg[2]);
	Mat_Rotate(r_view_matrix, -r_newrefdef.viewangles[1], 0.f, 0.f, 1.f);
	Mat_Rotate(r_view_matrix, -r_newrefdef.viewangles[0], 0.f, 1.f, 0.f);
	Mat_Rotate(r_view_matrix, -r_newrefdef.viewangles[2], 1.f, 0.f, 0.f);
	Mat_Rotate(r_view_matrix, 90.f, 0.f, 0.f, 1.f);
	Mat_Rotate(r_view_matrix, -90.f, 1.f, 0.f, 0.f);

	// precalculate view-projection matrix
	Mat_Mul(r_view_matrix, r_projection_matrix, r_viewproj_matrix);
}

/*
==============
R_RotateForEntity
==============
*/
void
R_RotateForEntity(entity_t *e, float *mvMatrix)
{
	Mat_Rotate(mvMatrix, -e->angles[2], 1.f, 0.f, 0.f);
	Mat_Rotate(mvMatrix, -e->angles[0], 0.f, 1.f, 0.f);
	Mat_Rotate(mvMatrix,  e->angles[1], 0.f, 0.f, 1.f);
	Mat_Translate(mvMatrix, e->origin[0], e->origin[1], e->origin[2]);
}

/*
==============
Draw_InitLocal

2D UI is stubbed in W3.0; nothing to initialize.
==============
*/
void
Draw_InitLocal(void)
{
}

static qboolean
R_SetMode(void);

static void
R_ReleaseShaders(mtlstate_t *st);

/*
==============
RE_Init
==============
*/
static qboolean
RE_Init(void)
{
	Com_Printf("Refresh: " REF_VERSION "\n");
	Com_Printf("Platform: " YQ2OSTYPE "\n");
	Com_Printf("Architecture: " YQ2ARCH "\n");
	Com_Printf("Build date: " BUILD_DATE "\n\n");

	R_Register();

	// set video mode/screen resolution
	if (!R_SetMode())
	{
		Com_Printf("%s() - could not R_SetMode()\n", __func__);
		return false;
	}

	/* W3: image/model state must be initialized after the window and
	   device exist (R_SetMode -> GLimp_InitGraphics -> RE_InitContext). */
	MTL_InitImages();
	Mod_Init();
	RE_InitParticleTexture();
	Draw_InitLocal();

	ri.Vid_MenuInit();

	Com_Printf("Successfully initialized Metal 4 refresher!\n");

	return true;
}

/*
==============
RE_ShutdownContext

Shuts down the window specific context (Metal view and layer). Called
by the host before the window is destroyed (mode change) or the
renderer is shut down. The device, queue, command buffer, allocators
and shared event survive mode changes and are released in RE_Shutdown.
==============
*/
static void
RE_ShutdownContext(void)
{
	mtlstate_t *st = &mtl_state;

	if (st->layer != NULL && st->queue != nil)
	{
		CAMetalLayer *layer = (CAMetalLayer *)st->layer;

		if (layer.residencySet != nil)
		{
			[st->queue removeResidencySet:layer.residencySet];
		}
	}

	if (st->metal_view != NULL)
	{
		SDL_Metal_DestroyView((SDL_MetalView)st->metal_view);
	}

	st->window = NULL;
	st->metal_view = NULL;
	st->layer = NULL;
	st->drawable = nil;
	st->frame_active = false;
}

void
RE_Shutdown(void)
{
	mtlstate_t *st = &mtl_state;

	// no commands registered in W1
	RE_ShutdownContext();

	// W2: shaders and test resources
	R_ReleaseShaders(st);

	if (st->pass_descriptor != nil)
	{
		[st->pass_descriptor release];
	}
	if (st->color_attachment != nil)
	{
		[st->color_attachment release];
	}
	if (st->command_buffer != nil)
	{
		[st->command_buffer release];
	}
	if (st->shared_event != nil)
	{
		[st->shared_event release];
	}
	for (int i = 0; i < 3; i++)
	{
		if (st->allocators[i] != nil)
		{
			[st->allocators[i] release];
		}
	}
	if (st->queue != nil)
	{
		[st->queue release];
	}
	if (st->device != nil)
	{
		[st->device release];
	}

	memset(&mtl_state, 0, sizeof(mtl_state));
}

/*
==============
RE_PrepareForWindow

Called before the window is created. Ask SDL for a window that can
host a Metal view.
==============
*/
static int
RE_PrepareForWindow(void)
{
	return SDL_WINDOW_METAL;
}



/*
============
R_ReleaseShaders

Release everything R_InitShaders allocated (partial state included)
and nil the state fields. Safe to call repeatedly.
============
*/
static void
R_ReleaseShaders(mtlstate_t *st)
{
	int i;

	if (st->residency_set != nil)
	{
		if (st->queue != nil)
		{
			[st->queue removeResidencySet:st->residency_set];
		}
		[st->residency_set release];
		st->residency_set = nil;
	}
	for (i = 0; i < 3; i++)
	{
		if (st->world_ubo[i] != nil)
		{
			[st->world_ubo[i] release];
			st->world_ubo[i] = nil;
		}
		if (st->world_lmap_vertex_buffer[i] != nil)
		{
			[st->world_lmap_vertex_buffer[i] release];
			st->world_lmap_vertex_buffer[i] = nil;
		}
		if (st->world_vertex_buffer[i] != nil)
		{
			[st->world_vertex_buffer[i] release];
			st->world_vertex_buffer[i] = nil;
		}
		if (st->dlight_vertex_buffer[i] != nil)
		{
			[st->dlight_vertex_buffer[i] release];
			st->dlight_vertex_buffer[i] = nil;
		}
		if (st->showtris_vertex_buffer[i] != nil)
		{
			[st->showtris_vertex_buffer[i] release];
			st->showtris_vertex_buffer[i] = nil;
		}
		if (st->alias_vertex_buffer[i] != nil)
		{
			[st->alias_vertex_buffer[i] release];
			st->alias_vertex_buffer[i] = nil;
		}
	}
	if (st->flash_vertex_buffer != nil)
	{
		[st->flash_vertex_buffer release];
		st->flash_vertex_buffer = nil;
	}
	if (st->depth_state_none != nil)
	{
		[st->depth_state_none release];
		st->depth_state_none = nil;
	}
	if (st->depth_state_nodwrite != nil)
	{
		[st->depth_state_nodwrite release];
		st->depth_state_nodwrite = nil;
	}
	if (st->depth_state != nil)
	{
		[st->depth_state release];
		st->depth_state = nil;
	}
	if (st->depth_texture != nil)
	{
		[st->depth_texture release];
		st->depth_texture = nil;
	}
	if (st->lmap_frag_table != nil)
	{
		[st->lmap_frag_table release];
		st->lmap_frag_table = nil;
	}
	if (st->lmap_vert_table != nil)
	{
		[st->lmap_vert_table release];
		st->lmap_vert_table = nil;
	}
	if (st->plain_frag_table != nil)
	{
		[st->plain_frag_table release];
		st->plain_frag_table = nil;
	}
	if (st->plain_vert_table != nil)
	{
		[st->plain_vert_table release];
		st->plain_vert_table = nil;
	}
	if (st->dlight_vert_table != nil)
	{
		[st->dlight_vert_table release];
		st->dlight_vert_table = nil;
	}
	if (st->flash_vert_table != nil)
	{
		[st->flash_vert_table release];
		st->flash_vert_table = nil;
	}
	if (st->alias_frag_table != nil)
	{
		[st->alias_frag_table release];
		st->alias_frag_table = nil;
	}
	if (st->alias_vert_table != nil)
	{
		[st->alias_vert_table release];
		st->alias_vert_table = nil;
	}
	if (st->pipeline_dlight != nil)
	{
		[st->pipeline_dlight release];
		st->pipeline_dlight = nil;
	}
	if (st->pipeline_flash != nil)
	{
		[st->pipeline_flash release];
		st->pipeline_flash = nil;
	}
	if (st->pipeline_showtris != nil)
	{
		[st->pipeline_showtris release];
		st->pipeline_showtris = nil;
	}
	if (st->pipeline_alias_translucent != nil)
	{
		[st->pipeline_alias_translucent release];
		st->pipeline_alias_translucent = nil;
	}
	if (st->pipeline_alias != nil)
	{
		[st->pipeline_alias release];
		st->pipeline_alias = nil;
	}
	if (st->pipeline_sky != nil)
	{
		[st->pipeline_sky release];
		st->pipeline_sky = nil;
	}
	if (st->pipeline_lmap != nil)
	{
		[st->pipeline_lmap release];
		st->pipeline_lmap = nil;
	}
	if (st->pipeline_plain != nil)
	{
		[st->pipeline_plain release];
		st->pipeline_plain = nil;
	}
	if (st->library != nil)
	{
		[st->library release];
		st->library = nil;
	}
	if (st->compiler != nil)
	{
		[st->compiler release];
		st->compiler = nil;
	}
}

/*
=============
R_InitShaders

W3: create the MTL4Compiler, compile the embedded world.msl into a
library, build the three world render pipelines (plain / lightmapped /
sky), the four shared argument tables, and the per-slot vertex/UBO
rings.

Called once from RE_InitContext, right after the device is created;
everything here survives mode changes. Returns false on any failure -
the host then falls back to the next renderer in r_order.
=============
*/
static qboolean
R_InitShaders(void)
{
	mtlstate_t *st = &mtl_state;
	NSError *err = nil;
	int i;

	/* MTL4Compiler - the Metal 4 runtime compiler. */
	{
		MTL4CompilerDescriptor *cd = [MTL4CompilerDescriptor new];
		cd.label = @"ref_mtl";

		st->compiler = [st->device newCompilerWithDescriptor:cd error:&err];
		if (st->compiler == nil)
		{
			Com_Printf("ref_mtl: failed to create MTL4Compiler: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* Compile the embedded MSL source into a library. */
	{
		MTLCompileOptions *opts = [MTLCompileOptions new];
		opts.languageVersion = MTLLanguageVersion3_2;

		MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
		ld.source = [NSString stringWithUTF8String:world];
		ld.options = opts;
		ld.name = @"ref_mtl.world";

		st->library = [st->compiler newLibraryWithDescriptor:ld error:&err];
		if (st->library == nil)
		{
			Com_Printf("ref_mtl: MSL compilation failed:\n%s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* Render pipelines. All three share the plain fragment shader;
	   only the vertex stages and the argument tables differ. */
	{
		static const struct
		{
			const char *vertex;
			const char *fragment;
			int stride;		// polyvert_t = 20, lmappolyvert_t = 28
		} pipelines[3] = {
			{ "world_plain_vertex", "world_plain_fragment", (int)sizeof(polyvert_t) },
			{ "world_lmap_vertex", "world_lmap_fragment", (int)sizeof(lmappolyvert_t) },
			{ "world_sky_vertex", "world_plain_fragment", (int)sizeof(polyvert_t) },
		};

		for (i = 0; i < 3; i++)
		{
			MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

			MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
			vf.name = [NSString stringWithUTF8String:pipelines[i].vertex];
			vf.library = st->library;
			pd.vertexFunctionDescriptor = vf;

			MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
			ff.name = [NSString stringWithUTF8String:pipelines[i].fragment];
			ff.library = st->library;
			pd.fragmentFunctionDescriptor = ff;

			/* Vertex layout: float3 position at offset 0, float2 uv at
			   offset 12 (and float2 lmapuv at offset 20 for the lightmapped
			   pipeline), all in vertex data buffer 0. */
			MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
			vd.attributes[0].format = MTLVertexFormatFloat3;
			vd.attributes[0].offset = 0;
			vd.attributes[0].bufferIndex = 0;
			vd.attributes[1].format = MTLVertexFormatFloat2;
			vd.attributes[1].offset = 12;
			vd.attributes[1].bufferIndex = 0;
			if (i == 1)
			{
				vd.attributes[2].format = MTLVertexFormatFloat2;
				vd.attributes[2].offset = 20;
				vd.attributes[2].bufferIndex = 0;
			}
			vd.layouts[0].stride = pipelines[i].stride;
			pd.vertexDescriptor = vd;

			pd.rasterSampleCount = 1;
			pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;

			id<MTLRenderPipelineState> pipeline = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
			if (pipeline == nil)
			{
				Com_Printf("ref_mtl: pipeline creation failed (%s): %s\n",
				           pipelines[i].vertex, err.localizedDescription.UTF8String);
				R_ReleaseShaders(st);
				return false;
			}

			switch (i)
			{
				case 0: st->pipeline_plain = pipeline; break;
				case 1: st->pipeline_lmap = pipeline; break;
				case 2: st->pipeline_sky = pipeline; break;
			}
		}
	}

	/* W4: dynamic light billboard quads. 24-byte vertices (pos3 +
	   color3), additive blend, no depth write. The fragment stage has no
	   resource bindings, so only the vertex argument table exists. */
	{
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"dlight_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"dlight_fragment";
		ff.library = st->library;
		pd.fragmentFunctionDescriptor = ff;

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat3;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat3;
		vd.attributes[1].offset = 12;
		vd.attributes[1].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(dlightvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
		pd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_dlight = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_dlight == nil)
		{
			Com_Printf("ref_mtl: dlight pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W4: view flash (R_PolyBlend). Full-screen clip-space quad with a
	   uniform color from v_blend, standard alpha blend (matching the vk
	   color-rect pipeline), no depth test or write. The six vertices are
	   static; the color is written into the world UBO ring per frame. */
	{
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"flash_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"flash_fragment";
		ff.library = st->library;
		pd.fragmentFunctionDescriptor = ff;

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(flashvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
		pd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_flash = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_flash == nil)
		{
			Com_Printf("ref_mtl: flash pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		/* Static full-screen quad: two triangles in the mtl convention
		   (triangle list, no index buffers). Winding is irrelevant - the
		   flash draws with culling disabled. */
		st->flash_vertex_buffer = [st->device newBufferWithLength:6 * sizeof(flashvert_t) options:MTLResourceStorageModeShared];
		if (st->flash_vertex_buffer == nil)
		{
			Com_Printf("ref_mtl: failed to create flash vertex buffer\n");
			R_ReleaseShaders(st);
			return false;
		}
		{
			static const float corners[12] = {
				-1.f, -1.f,  1.f, -1.f,  1.f,  1.f,
				-1.f, -1.f, -1.f,  1.f,  1.f,  1.f,
			};
			flashvert_t *dst = (flashvert_t *)st->flash_vertex_buffer.contents;

			for (i = 0; i < 6; i++)
			{
				dst[i].position[0] = corners[i * 2];
				dst[i].position[1] = corners[i * 2 + 1];
			}
		}
	}

	/* W4: showtris (R_DrawTriangleOutlines). Reuses the dlight vertex and
	   fragment functions (same 24B pos+color layout, same viewproj UBO);
	   the differences live in the pipeline/encoder state - no blend, and
	   the draws are line primitives with culling and depth test disabled
	   (see R_DrawTriangleOutlines). */
	{
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"dlight_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"dlight_fragment";
		ff.library = st->library;
		pd.fragmentFunctionDescriptor = ff;

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat3;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat3;
		vd.attributes[1].offset = 12;
		vd.attributes[1].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(dlightvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;

		st->pipeline_showtris = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_showtris == nil)
		{
			Com_Printf("ref_mtl: showtris pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W5a: alias models. 36-byte vertices (pos3 + uv2 + color4), one UBO
	   per model (alias_ubo_t, shared by all of the model's draws). The
	   translucent variant alpha-blends and skips depth writes, like the
	   flash pipeline. */
	{
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"alias_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"alias_fragment";
		ff.library = st->library;
		pd.fragmentFunctionDescriptor = ff;

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat3;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat2;
		vd.attributes[1].offset = 12;
		vd.attributes[1].bufferIndex = 0;
		vd.attributes[2].format = MTLVertexFormatFloat4;
		vd.attributes[2].offset = 20;
		vd.attributes[2].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(aliasvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;

		st->pipeline_alias = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_alias == nil)
		{
			Com_Printf("ref_mtl: alias pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		pd = [MTL4RenderPipelineDescriptor new];
		pd.vertexFunctionDescriptor = vf;
		pd.fragmentFunctionDescriptor = ff;
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
		pd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_alias_translucent = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_alias_translucent == nil)
		{
			Com_Printf("ref_mtl: alias translucent pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->alias_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->alias_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create alias vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxTextureBindCount = 1;
		atd.maxBufferBindCount = 1;
		st->alias_frag_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->alias_frag_table == nil)
		{
			Com_Printf("ref_mtl: failed to create alias fragment argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* Per-slot vertex/UBO rings. The CPU writes world vertices and one
	   world_ubo_t per draw into the current slot's rings; the GPU consumes
	   them within the same frame. The slots are gated by the shared event
	   (see RE_BeginFrame), so per-frame offset resets are safe. */
	for (i = 0; i < 3; i++)
	{
		st->world_vertex_buffer[i] = [st->device newBufferWithLength:WORLD_VERTEX_RING_BYTES options:MTLResourceStorageModeShared];
		st->world_lmap_vertex_buffer[i] = [st->device newBufferWithLength:WORLD_LMAP_VERTEX_RING_BYTES options:MTLResourceStorageModeShared];
		st->world_ubo[i] = [st->device newBufferWithLength:WORLD_UBO_RING_BYTES options:MTLResourceStorageModeShared];
		st->dlight_vertex_buffer[i] = [st->device newBufferWithLength:DLIGHT_VERTEX_RING_BYTES options:MTLResourceStorageModeShared];
		st->showtris_vertex_buffer[i] = [st->device newBufferWithLength:SHOWTRIS_VERTEX_RING_BYTES options:MTLResourceStorageModeShared];
		st->alias_vertex_buffer[i] = [st->device newBufferWithLength:ALIAS_VERTEX_RING_BYTES options:MTLResourceStorageModeShared];

		if (st->world_vertex_buffer[i] == nil ||
		    st->world_lmap_vertex_buffer[i] == nil ||
		    st->world_ubo[i] == nil ||
		    st->dlight_vertex_buffer[i] == nil ||
		    st->showtris_vertex_buffer[i] == nil ||
		    st->alias_vertex_buffer[i] == nil)
		{
			Com_Printf("ref_mtl: failed to create vertex/UBO ring buffers\n");
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* Argument tables, one per pipeline stage. Buffer and texture index
	   spaces are separate within one table. The vertex tables carry the
	   vertex data buffer (index 0) and the UBO (index 1); the fragment
	   tables the surface (index 0), lightmap (index 1, lmap path) and the
	   UBO (index 0). Bindings are updated before each draw. */
	{
		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->plain_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->plain_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create plain vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxTextureBindCount = 1;
		atd.maxBufferBindCount = 1;
		st->plain_frag_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->plain_frag_table == nil)
		{
			Com_Printf("ref_mtl: failed to create plain fragment argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->lmap_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->lmap_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create lmap vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxTextureBindCount = 2;
		atd.maxBufferBindCount = 1;
		st->lmap_frag_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->lmap_frag_table == nil)
		{
			Com_Printf("ref_mtl: failed to create lmap fragment argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->dlight_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->dlight_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create dlight vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->flash_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->flash_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create flash vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W4: single depth state for the whole world pass - less-than compare,
	   writes enabled. The pass descriptor's depth attachment clears to 1.0
	   in RE_RenderFrame. */
	{
		MTLDepthStencilDescriptor *dsd = [[MTLDepthStencilDescriptor alloc] init];

		dsd.depthCompareFunction = MTLCompareFunctionLess;
		dsd.depthWriteEnabled = YES;
		st->depth_state = [st->device newDepthStencilStateWithDescriptor:dsd];
		if (st->depth_state == nil)
		{
			Com_Printf("ref_mtl: failed to create depth stencil state\n");
			R_ReleaseShaders(st);
			return false;
		}

		/* Dlights compare against the world depth but never write it, so
		   the billboards cannot carve holes for later transparent passes. */
		dsd.depthWriteEnabled = NO;
		st->depth_state_nodwrite = [st->device newDepthStencilStateWithDescriptor:dsd];
		if (st->depth_state_nodwrite == nil)
		{
			Com_Printf("ref_mtl: failed to create no-write depth stencil state\n");
			R_ReleaseShaders(st);
			return false;
		}

		/* The flash is drawn last in the world pass, full-screen, and must
		   never test or write depth. */
		dsd.depthCompareFunction = MTLCompareFunctionAlways;
		st->depth_state_none = [st->device newDepthStencilStateWithDescriptor:dsd];
		if (st->depth_state_none == nil)
		{
			Com_Printf("ref_mtl: failed to create no-compare depth stencil state\n");
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* Metal 4 residency: GPU-visible resources must be part of a committed
	   residency set attached to the queue, otherwise the GPU reads zeros
	   and compute writes do not land - without any error. The layer's own
	   residency set (which covers the drawables) is added in RE_InitContext;
	   this one covers our world rings. */
	{
		MTLResidencySetDescriptor *rsd = [MTLResidencySetDescriptor new];
		st->residency_set = [st->device newResidencySetWithDescriptor:rsd error:&err];
		if (st->residency_set == nil)
		{
			Com_Printf("ref_mtl: failed to create residency set: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		for (i = 0; i < 3; i++)
		{
			[st->residency_set addAllocation:st->world_vertex_buffer[i]];
			[st->residency_set addAllocation:st->world_lmap_vertex_buffer[i]];
			[st->residency_set addAllocation:st->world_ubo[i]];
			[st->residency_set addAllocation:st->dlight_vertex_buffer[i]];
			[st->residency_set addAllocation:st->showtris_vertex_buffer[i]];
			[st->residency_set addAllocation:st->alias_vertex_buffer[i]];
		}
		[st->residency_set addAllocation:st->flash_vertex_buffer];
		[st->residency_set commit];
		[st->queue addResidencySet:st->residency_set];
	}

	Com_Printf("ref_mtl: W3 shaders compiled (plain/lmap/sky/dlight/flash/showtris/alias pipelines)\n");

	return true;
}

/*
==============
RE_InitContext

Called after the window was created. Creates the SDL Metal view and
CAMetalLayer for this window, and (the first time) the Metal 4 device,
command queue, command buffer, command allocators and shared event.
==============
*/
static int
RE_InitContext(void *sdl_window)
{
	char title[40] = {0};
	mtlstate_t *st = &mtl_state;

	SDL_Window *window = (SDL_Window *)sdl_window;

	if (window == NULL)
	{
		Com_Printf("%s() must not be called with NULL argument!", __func__);
		return false;
	}

	/* Window title - set here so we can display renderer name in it */
	snprintf(title, sizeof(title), "Yamagi Quake II - Metal 4 Render");
	SDL_SetWindowTitle(window, title);

	st->window = window;

	/* Metal 4 has no device side capability flag; the MTL4 APIs are
	   simply unavailable on older systems, so this is an OS check. */
	NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
	if (os.majorVersion < 26)
	{
		Com_Printf("ref_mtl: Metal 4 requires macOS 26 or later, found %d.%d. Not initializing.\n",
		           (int)os.majorVersion, (int)os.minorVersion);
		return false;
	}

	/* The device and friends survive mode changes. */
	if (st->device == nil)
	{
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();

		if (device == nil)
		{
			Com_Printf("ref_mtl: no default Metal device available\n");
			return false;
		}

		id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
		id<MTLSharedEvent> shared_event = [device newSharedEvent];
		id<MTL4CommandBuffer> command_buffer = [device newCommandBuffer];
		id<MTL4CommandAllocator> allocators[3];
		int i;

		for (i = 0; i < 3; i++)
		{
			allocators[i] = [device newCommandAllocator];
		}

		if (queue == nil || shared_event == nil || command_buffer == nil)
		{
			Com_Printf("ref_mtl: failed to create Metal 4 core objects (queue/event/command buffer)\n");
			return false;
		}
		for (i = 0; i < 3; i++)
		{
			if (allocators[i] == nil)
			{
				Com_Printf("ref_mtl: failed to create command allocator %d\n", i);
				return false;
			}
		}

		st->device = device;
		st->queue = queue;
		st->shared_event = shared_event;
		st->command_buffer = command_buffer;
		for (i = 0; i < 3; i++)
		{
			st->allocators[i] = allocators[i];
		}

		st->pass_descriptor = [MTL4RenderPassDescriptor new];
		st->color_attachment = [[MTLRenderPassColorAttachmentDescriptor alloc] init];
	}

	/* W3: runtime shader compilation and world rings. Guarded by the
	   plain pipeline so a failed first attempt is retried on mode changes. */
	if (st->pipeline_plain == nil && !R_InitShaders())
	{
		return false;
	}

	/* The SDL Metal view owns the CAMetalLayer we render into. */
	SDL_MetalView metal_view = SDL_Metal_CreateView(window);
	CAMetalLayer *layer = (CAMetalLayer *)SDL_Metal_GetLayer(metal_view);

	if (metal_view == NULL || layer == NULL)
	{
		Com_Printf("ref_mtl: failed to create SDL Metal view: %s\n", SDL_GetError());
		return false;
	}

	/* The layer must know its device before the first drawable is
	   requested (macOS). */
	layer.device = st->device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
	layer.framebufferOnly = YES;
	layer.maximumDrawableCount = 3;

	/* Retina: CAMetalLayer's default contentsScale on macOS is 1.0,
	   so derive it from the window's pixel size. The drawable size is
	   left at (0,0) and auto-tracks bounds * contentsScale. */
	int w = 1, h = 1, pw = 0, ph = 0;
	SDL_GetWindowSize(window, &w, &h);
	SDL_GetWindowSizeInPixels(window, &pw, &ph);
	float pixel_scale = 1.0f;

	if (w > 0 && pw > 0)
	{
		pixel_scale = (float)pw / (float)w;
	}
	layer.contentsScale = pixel_scale;

	/* Keep the layer's residency set resident for all command buffers
	   committed to this queue. */
	if (layer.residencySet != nil)
	{
		[st->queue addResidencySet:layer.residencySet];
	}

	st->metal_view = metal_view;
	st->layer = layer;
	st->drawable = nil;
	st->frame_number = 0;
	st->frame_slot = 0;
	memset(st->slot_done, 0, sizeof(st->slot_done));
	st->frame_active = false;
	st->pixel_scale = pixel_scale;

	return true;
}

/*
==============
RE_GetDrawableSize

Returns the size of the drawable in pixels.
==============
*/
static void
RE_GetDrawableSize(int *width, int *height)
{
	if (mtl_state.window == NULL)
	{
		return;
	}

	if (mtl_state.layer != NULL)
	{
		CGSize size = ((CAMetalLayer *)mtl_state.layer).drawableSize;

		if (size.width > 0 && size.height > 0)
		{
			*width = (int)size.width;
			*height = (int)size.height;
			return;
		}
	}

	SDL_GetWindowSize(mtl_state.window, width, height);
}

/*
==============
RE_IsVSyncActive
==============
*/
static qboolean
RE_IsVSyncActive(void)
{
	if (r_vsync != NULL && r_vsync->value)
	{
		return true;
	}

	return false;
}

/*
==============
RE_SetMode

Changes the video mode.
==============
*/
static int
Mtlimp_SetMode(int *pwidth, int *pheight, int mode, int fullscreen)
{
	Com_Printf("Setting mode %d:", mode);

	/* mode -1 is not in the vid mode table - so we keep the values in pwidth
	   and pheight and don't even try to look up the mode info */
	if ((mode >= 0) && !ri.Vid_GetModeInfo(pwidth, pheight, mode))
	{
		Com_Printf(" invalid mode\n");
		return rserr_invalid_mode;
	}

	/* We trying to get resolution from desktop */
	if (mode == -2)
	{
		if (!ri.GLimp_GetDesktopMode(pwidth, pheight))
		{
			Com_Printf(" can't detect mode\n");
			return rserr_invalid_mode;
		}
	}

	Com_Printf(" %dx%d (vid_fullscreen %i)\n", *pwidth, *pheight, fullscreen);

	if (!ri.GLimp_InitGraphics(fullscreen, pwidth, pheight))
	{
		return rserr_invalid_mode;
	}

	return rserr_ok;
}

static qboolean
R_SetMode(void)
{
	rserr_t err;
	int fullscreen;

	r_mode->modified = false;
	r_vsync->modified = false;

	fullscreen = (int)vid_fullscreen->value;
	vid_gamma->modified = false;

	/* a bit hackish approach to enable custom resolutions:
	   Glimp_SetMode needs these values set for mode -1 */
	vid.width = r_customwidth->value;
	vid.height = r_customheight->value;

	if ((err = Mtlimp_SetMode((int*)&vid.width, (int*)&vid.height, r_mode->value, fullscreen)) == rserr_ok)
	{
		return true;
	}

	if (err == rserr_invalid_mode)
	{
		Com_Printf("%s() - invalid mode\n", __func__);
	}

	// try setting it back to something safe
	if (Mtlimp_SetMode((int*)&vid.width, (int*)&vid.height, 4, false) != rserr_ok)
	{
		Com_Printf("%s() - could not revert to safe mode\n", __func__);
		return false;
	}

	return true;
}

/*
==============
RE_BeginFrame
==============
*/
static void
RE_BeginFrame(float camera_separation)
{
	mtlstate_t *st = &mtl_state;

	if (st->queue == nil || st->command_buffer == nil || st->layer == NULL)
	{
		return; // not initialized
	}

	st->frame_number++;
	st->frame_slot = (int)(st->frame_number % 3);

	/* CPU gate: don't touch this slot's command allocator until the GPU
	   is done with the last frame that used it. Skipped frames never
	   signal, so slot_done only advances for frames that were rendered. */
	if (st->slot_done[st->frame_slot] > 0)
	{
		if (![st->shared_event waitUntilSignaledValue:st->slot_done[st->frame_slot] timeoutMS:1000])
		{
			Com_DPrintf("ref_mtl: CPU gate timed out, skipping frame %llu\n",
			           (unsigned long long)st->frame_number);
			return;
		}
	}

	[st->allocators[st->frame_slot] reset];

	id<CAMetalDrawable> drawable = [(CAMetalLayer *)st->layer nextDrawable];
	if (drawable == nil)
	{
		Com_DPrintf("ref_mtl: no drawable available, skipping frame\n");
		return;
	}
	st->drawable = drawable;

	// W4: the per-slot vertex/UBO rings are consumed sequentially during
	// the frame, so their offsets reset to zero once a drawable is in
	// hand (the slot was just gated above).
	st->world_vertex_offset[st->frame_slot] = 0;
	st->world_lmap_vertex_offset[st->frame_slot] = 0;
	st->world_ubo_offset[st->frame_slot] = 0;
	st->dlight_vertex_offset[st->frame_slot] = 0;
	st->showtris_vertex_offset[st->frame_slot] = 0;
	st->alias_vertex_offset[st->frame_slot] = 0;

	// W4: the depth texture is sized to the drawable and recreated when
	// the window (or its contentsScale) changes.
	if (st->depth_width != (int)drawable.texture.width ||
	    st->depth_height != (int)drawable.texture.height)
	{
		MTLTextureDescriptor *dd;

		if (st->depth_texture != nil)
		{
			[st->residency_set removeAllocation:st->depth_texture];
			[st->depth_texture release];
			st->depth_texture = nil;
		}

		dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
		        MTLPixelFormatDepth32Float
		        width:drawable.texture.width
		        height:drawable.texture.height
		        mipmapped:NO];
		dd.usage = MTLTextureUsageRenderTarget;
		dd.storageMode = MTLStorageModeShared;
		st->depth_texture = [st->device newTextureWithDescriptor:dd];
		[st->residency_set addAllocation:st->depth_texture];
		[st->residency_set commit];
		st->depth_width = (int)drawable.texture.width;
		st->depth_height = (int)drawable.texture.height;
	}

	[st->command_buffer beginCommandBufferWithAllocator:st->allocators[st->frame_slot]];
	st->frame_active = true;
}

/*
==============
RE_EndWorldRenderpass
==============
*/
static qboolean
RE_EndWorldRenderpass(void)
{
	// W1: the world pass (clear color) was rendered in RE_RenderFrame
	return true;
}

/*
==============
RE_EndFrame
==============
*/
static void
RE_EndFrame(void)
{
	mtlstate_t *st = &mtl_state;

	if (!st->frame_active)
	{
		return;
	}
	st->frame_active = false;

	[st->command_buffer endCommandBuffer];

	/* The display may still be scanning out this drawable. */
	[st->queue waitForDrawable:st->drawable];

	{
		id<MTL4CommandBuffer> cmdbuf = st->command_buffer;
		[st->queue commit:&cmdbuf count:1];
	}

	/* Safe to present now, then actually present. */
	[st->queue signalDrawable:st->drawable];
	[st->drawable present];

	/* GPU side: signal frame completion after all of its work. The
	   CPU gate in RE_BeginFrame waits on this value before reusing the
	   slot's allocator three frames later. */
	[st->queue signalEvent:st->shared_event value:st->frame_number];
	st->slot_done[st->frame_slot] = st->frame_number;
	st->drawable = nil;
}

/*
==============
RE_SetPalette
==============
*/
unsigned r_rawpalette[256];

static void
RE_SetPalette(const unsigned char *palette)
{
	int i;

	byte *rp = (byte *)r_rawpalette;

	if (palette)
	{
		for (i = 0; i < 256; i++)
		{
			rp[i * 4 + 0] = palette[i * 3 + 0];
			rp[i * 4 + 1] = palette[i * 3 + 1];
			rp[i * 4 + 2] = palette[i * 3 + 2];
			rp[i * 4 + 3] = 0xff;
		}
	}
	else
	{
		for (i = 0; i < 256; i++)
		{
			rp[i * 4 + 0] = d_8to24table[i] & 0xff;
			rp[i * 4 + 1] = (d_8to24table[i] >> 8) & 0xff;
			rp[i * 4 + 2] = (d_8to24table[i] >> 16) & 0xff;
			rp[i * 4 + 3] = 0xff;
		}
	}
}

/*
=============
R_RenderFlash

View flash (the vk R_PolyBlend equivalent): a full-screen quad tinted with
v_blend (pain / damage feedback from the core), drawn last in the world
pass. Gated by mtl_polyblend and skipped when v_blend's alpha is zero. The
color rides on the slot's world UBO ring (16 bytes), like the dlight UBOs.
=============
*/
static void
R_RenderFlash(void)
{
	mtlstate_t *st = &mtl_state;
	size_t slot;
	MTLGPUAddress ubo_addr;
	float *ubo;

	if (!mtl_polyblend->value || !v_blend[3])
	{
		return;
	}

	if (st->encoder == nil || st->pipeline_flash == nil)
	{
		return;
	}

	slot = st->frame_slot;
	if (st->world_ubo_offset[slot] + sizeof(float) * 4 > WORLD_UBO_RING_BYTES)
	{
		return;	/* ring exhausted, skip the flash */
	}

	ubo_addr = st->world_ubo[slot].gpuAddress + st->world_ubo_offset[slot];
	ubo = (float *)((byte *)st->world_ubo[slot].contents + st->world_ubo_offset[slot]);
	ubo[0] = v_blend[0];
	ubo[1] = v_blend[1];
	ubo[2] = v_blend[2];
	ubo[3] = v_blend[3];
	st->world_ubo_offset[slot] += sizeof(float) * 4;

	[st->flash_vert_table setAddress:st->flash_vertex_buffer.gpuAddress atIndex:0];
	[st->flash_vert_table setAddress:ubo_addr atIndex:1];

	[st->encoder setDepthStencilState:st->depth_state_none];
	[st->encoder setRenderPipelineState:st->pipeline_flash];
	[st->encoder setArgumentTable:st->flash_vert_table atStages:MTLRenderStageVertex];
	[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

	/* restore the world-pass encoder state */
	[st->encoder setDepthStencilState:st->depth_state];
}

/*
==============
RE_RenderFrame

Encodes the world pass: clear color and depth, set up the view from the
refdef (R_SetupFrame), draw the world (R_DrawWorld), then end the
encoder. All world draw functions encode into st->encoder.
==============
*/
static void
RE_RenderFrame(refdef_t *fd)
{
	mtlstate_t *st = &mtl_state;

	if (!st->frame_active || st->drawable == nil || st->pipeline_plain == nil)
	{
		return;
	}

	r_newrefdef = *fd;

	st->color_attachment.texture = st->drawable.texture;
	st->color_attachment.loadAction = MTLLoadActionClear;
	st->color_attachment.storeAction = MTLStoreActionStore;
	st->color_attachment.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
	st->pass_descriptor.colorAttachments[0] = st->color_attachment;

	st->pass_descriptor.depthAttachment.texture = st->depth_texture;
	st->pass_descriptor.depthAttachment.level = 0;
	st->pass_descriptor.depthAttachment.loadAction = MTLLoadActionClear;
	st->pass_descriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
	st->pass_descriptor.depthAttachment.clearDepth = 1.0;

	st->encoder = [st->command_buffer renderCommandEncoderWithDescriptor:st->pass_descriptor];
	if (st->encoder == nil)
	{
		Com_DPrintf("ref_mtl: failed to create render command encoder\n");
		return;
	}

	[st->encoder setDepthStencilState:st->depth_state];

	/* W4: mark the surfaces hit by dynamic lights before the framecount
	   advances in R_SetupFrame (matches the vk frame order). */
	R_PushDlights();

	R_SetupFrame();
	R_DrawWorld();
	R_DrawEntitiesOnList();
	R_RenderDlights();
	R_RenderFlash();

	[st->encoder endEncoding];
	st->encoder = nil;

	/* Attach the residency set to this command buffer (Apple's MTL4
	   template pattern); together with the queue-level set this makes
	   the bound resources visible to the GPU. */
	[st->command_buffer useResidencySet:st->residency_set];
}

/*
==============
2D UI stubs (W0)
==============
*/
static struct image_s *
RE_Draw_FindPic(const char *name)
{
	return NULL;
}

static void
RE_Draw_GetPicSize(int *w, int *h, const char *name)
{
	*w = 0;
	*h = 0;
}

static void
RE_Draw_PicScaled(int x, int y, const char *pic, float factor)
{
}

static void
RE_Draw_StretchPic(int x, int y, int w, int h, const char *name)
{
}

static void
RE_Draw_CharScaled(int x, int y, int num, float scale)
{
}

static void
RE_Draw_TileClear(int x, int y, int w, int h, const char *name)
{
}

static void
RE_Draw_Fill(int x, int y, int w, int h, int c)
{
}

static void
RE_Draw_FadeScreen(void)
{
}

static void
RE_Draw_StretchRaw(int x, int y, int w, int h, int cols, int rows, const byte *data, int bits)
{
}

static void
RE_Draw_PicScaledCol(int x, int y, const char *pic, float factor, const float color[3])
{
}

/*
==============
RE_GetSDLVersion
==============
*/
static int
RE_GetSDLVersion(void)
{
#ifdef USE_SDL3
	int version = SDL_GetVersion();
	return SDL_VERSIONNUM_MAJOR(version);
#else
	SDL_version ver;
	SDL_VERSION(&ver);
	return ver.major;
#endif
}

/*
==============
GetRefAPI
==============
*/
Q2_DLL_EXPORTED refexport_t
GetRefAPI(refimport_t imp)
{
	refexport_t refexport = {0};

	ri = imp;

	refexport.api_version = API_VERSION;
	refexport.framework_version = RE_GetSDLVersion();

	refexport.BeginRegistration = RE_BeginRegistration;
	refexport.RegisterModel = RE_RegisterModel;
	refexport.RegisterSkin = RE_RegisterSkin;
	refexport.DrawFindPic = RE_Draw_FindPic;
	refexport.SetSky = RE_SetSky;
	refexport.EndRegistration = RE_EndRegistration;

	refexport.RenderFrame = RE_RenderFrame;

	refexport.DrawGetPicSize = RE_Draw_GetPicSize;
	refexport.DrawPicScaled = RE_Draw_PicScaled;
	refexport.DrawStretchPic = RE_Draw_StretchPic;
	refexport.DrawCharScaled = RE_Draw_CharScaled;
	refexport.DrawTileClear = RE_Draw_TileClear;
	refexport.DrawFill = RE_Draw_Fill;
	refexport.DrawFadeScreen = RE_Draw_FadeScreen;

	refexport.DrawStretchRaw = RE_Draw_StretchRaw;

	refexport.DrawPicScaledCol = RE_Draw_PicScaledCol;

	refexport.Init = RE_Init;
	refexport.IsVSyncActive = RE_IsVSyncActive;
	refexport.Shutdown = RE_Shutdown;
	refexport.InitContext = RE_InitContext;
	refexport.GetDrawableSize = RE_GetDrawableSize;
	refexport.ShutdownContext = RE_ShutdownContext;
	refexport.PrepareForWindow = RE_PrepareForWindow;

	refexport.SetPalette = RE_SetPalette;
	refexport.BeginFrame = RE_BeginFrame;
	refexport.EndWorldRenderpass = RE_EndWorldRenderpass;
	refexport.EndFrame = RE_EndFrame;

	// Tell the client that we're using the
	// new renderer restart API.
	ri.Vid_RequestRestart(RESTART_NO);

	Swap_Init();

	return refexport;
}

/*
==============
R_Printf
==============
*/
void R_Printf(int level, const char* msg, ...)
{
	va_list argptr;
	va_start(argptr, msg);
	ri.Com_VPrintf(level, msg, argptr);
	va_end(argptr);
}

/*
 * this is only here so the functions in shared source files
 * (shared.c, mem.c/hunk.c) can link
 */
void
Sys_Error(const char *error, ...)
{
	va_list argptr;
	char text[4096]; // MAXPRINTMSG == 4096

	va_start(argptr, error);
	vsnprintf(text, sizeof(text), error, argptr);
	va_end(argptr);

	ri.Sys_Error(ERR_FATAL, "%s", text);
}

void
Com_Printf(const char *msg, ...)
{
	va_list argptr;
	va_start(argptr, msg);
	ri.Com_VPrintf(PRINT_ALL, msg, argptr);
	va_end(argptr);
}

void
Com_DPrintf(const char *fmt, ...)
{
	va_list argptr;
	va_start(argptr, fmt);
	ri.Com_VPrintf(PRINT_DEVELOPER, fmt, argptr);
	va_end(argptr);
}

void
Com_Error(int code, const char *fmt, ...)
{
	va_list argptr;
	char text[4096]; // MAXPRINTMSG == 4096

	va_start(argptr, fmt);
	vsnprintf(text, sizeof(text), fmt, argptr);
	va_end(argptr);

	ri.Sys_Error(code, "%s", text);
}
