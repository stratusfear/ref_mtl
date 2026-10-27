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
cvar_t		*mtl_custom_particles;
cvar_t		*mtl_particle_size;
cvar_t		*mtl_particle_att_a;
cvar_t		*mtl_particle_att_b;
cvar_t		*mtl_particle_att_c;
cvar_t		*mtl_particle_min_size;
cvar_t		*mtl_particle_max_size;
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
	mtl_custom_particles = ri.Cvar_Get("mtl_custom_particles", "1", CVAR_ARCHIVE);
	mtl_particle_size = ri.Cvar_Get("mtl_particle_size", "40", CVAR_ARCHIVE);
	mtl_particle_att_a = ri.Cvar_Get("mtl_particle_att_a", "0.01", CVAR_ARCHIVE);
	mtl_particle_att_b = ri.Cvar_Get("mtl_particle_att_b", "0.0", CVAR_ARCHIVE);
	mtl_particle_att_c = ri.Cvar_Get("mtl_particle_att_c", "0.01", CVAR_ARCHIVE);
	mtl_particle_min_size = ri.Cvar_Get("mtl_particle_min_size", "2", CVAR_ARCHIVE);
	mtl_particle_max_size = ri.Cvar_Get("mtl_particle_max_size", "40", CVAR_ARCHIVE);
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
along -z of the view space. The projection matrices are emitted directly in
the Metal 4 coordinate system (NDC x right, y up, depth [0..1], w = -view_z)
for the row-vector convention used by Mat_Mul and the MSL float4x4.
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

void Mat_Perspective(float *matrix, float fovy, float aspect,
	float zNear, float zFar)
{
	float xmin, xmax, ymin, ymax;

	ymax = zNear * tan(fovy * M_PI / 360.0);
	ymin = -ymax;

	xmin = ymin * aspect;
	xmax = ymax * aspect;

	xmin += -(2 * mtl_state.camera_separation) / zNear;
	xmax += -(2 * mtl_state.camera_separation) / zNear;

	/*
	** Metal 4 clip space, row-vector convention (p' = p * M, matching the
	** Mat_Mul/MSL float4x4 application used everywhere in ref_mtl):
	**   - w = -view_z (positive in front of the camera)
	**   - z remapped from OpenGL's [-1,1] to Metal's [0,1] depth range
	**     (z_ndc = (z_gl + 1) / 2), so the near plane is 0 and the far
	**     plane is 1, matching the pass descriptor's depth clear of 1.0.
	** The matrix is emitted directly in this form; no post-multiply
	** correction is applied (a right-multiply by a z-remap matrix would
	** leak into the w-row and skew every projected point).
	*/
	memset(matrix, 0, sizeof(float) * 16);
	matrix[0] = 2.f * zNear / (xmax - xmin);
	matrix[2] = (xmax + xmin) / (xmax - xmin);
	matrix[5] = 2.f * zNear / (ymax - ymin);
	matrix[6] = (ymax + ymin) / (ymax - ymin);
	matrix[10] = -zFar / (zFar - zNear);
	matrix[11] = -1.f;
	matrix[14] = -zFar * zNear / (zFar - zNear);
}

void Mat_Ortho(float *matrix, float left, float right, float bottom, float top,
			   float zNear, float zFar)
{
	/* Metal 4 clip space, row-vector convention (p' = p * M): w is
	   constant 1, x/y map [left,right]/[bottom,top] to [-1,1], and z
	   maps the near plane to 0 and the far plane to 1 (Metal depth).
	   Translations live in row 3 (they multiply w). */
	memset(matrix, 0, sizeof(float) * 16);
	matrix[0] = 2.f / (right - left);
	matrix[5] = 2.f / (top - bottom);
	matrix[10] = -1.f / (zFar - zNear);
	matrix[12] = (right + left) / (right - left);
	matrix[13] = (top + bottom) / (top - bottom);
	matrix[14] = -zNear / (zFar - zNear);
	matrix[15] = 1.f;
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

		Mat_Perspective(r_projection_matrix,
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

W5d: find the console character font. The 2D UI (RE_Draw_*) renders
console text, menus and HUD from this 16x16 character atlas; without it
there is no way to draw text, so a missing conchars is fatal (matches
ref_vk Draw_InitLocal).
==============
*/
static image_t *draw_chars;

/* W5d: RE_Draw_StretchRaw's dynamic texture, recreated when the size
   changes (see RE_Draw_StretchRaw). */
static id<MTLTexture> raw_texture;
static int raw_texture_width;
static int raw_texture_height;

void
Draw_InitLocal(void)
{
	draw_chars = R_FindPic("conchars", (findimage_t)MTL_FindImage);

	/* Anachronox */
	if (!draw_chars)
	{
		draw_chars = R_FindPic("fonts/conchars", (findimage_t)MTL_FindImage);
	}

	/* Daikatana */
	if (!draw_chars)
	{
		draw_chars = R_FindPic("dkchars", (findimage_t)MTL_FindImage);
	}

	if (!draw_chars)
	{
		Com_Error(ERR_FATAL, "%s: Couldn't load pics/conchars", __func__);
	}
}

static qboolean
R_SetMode(void);

static void
R_ReleaseShaders(mtlstate_t *st);

/* W5d: 2D UI pass (see the definitions before RE_Draw_FindPic). */
static void
MTL_BeginUIPass(void);
static void
MTL_EndUIPass(void);

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

	// W5d: StretchRaw's dynamic texture (still referenced by the residency
	// set until it is released)
	if (raw_texture != nil)
	{
		if (st->residency_set != nil)
		{
			[st->residency_set removeAllocation:raw_texture];
		}
		[raw_texture release];
		raw_texture = nil;
	}

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
	if (st->ui_pass_descriptor != nil)
	{
		[st->ui_pass_descriptor release];
	}
	if (st->ui_color_attachment != nil)
	{
		[st->ui_color_attachment release];
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
	if (st->ui_tex_vertex_buffer != nil)
	{
		[st->ui_tex_vertex_buffer release];
		st->ui_tex_vertex_buffer = nil;
	}
	if (st->ui_color_vertex_buffer != nil)
	{
		[st->ui_color_vertex_buffer release];
		st->ui_color_vertex_buffer = nil;
	}
	if (st->ui_tex_frag_table != nil)
	{
		[st->ui_tex_frag_table release];
		st->ui_tex_frag_table = nil;
	}
	if (st->ui_tint_frag_table != nil)
	{
		[st->ui_tint_frag_table release];
		st->ui_tint_frag_table = nil;
	}
	if (st->ui_tex_vert_table != nil)
	{
		[st->ui_tex_vert_table release];
		st->ui_tex_vert_table = nil;
	}
	if (st->ui_tint_vert_table != nil)
	{
		[st->ui_tint_vert_table release];
		st->ui_tint_vert_table = nil;
	}
	if (st->ui_color_vert_table != nil)
	{
		[st->ui_color_vert_table release];
		st->ui_color_vert_table = nil;
	}
	if (st->pipeline_ui_tex != nil)
	{
		[st->pipeline_ui_tex release];
		st->pipeline_ui_tex = nil;
	}
	if (st->pipeline_ui_tint != nil)
	{
		[st->pipeline_ui_tint release];
		st->pipeline_ui_tint = nil;
	}
	if (st->pipeline_ui_color != nil)
	{
		[st->pipeline_ui_color release];
		st->pipeline_ui_color = nil;
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
	if (st->sprite_frag_table != nil)
	{
		[st->sprite_frag_table release];
		st->sprite_frag_table = nil;
	}
	if (st->sprite_vert_table != nil)
	{
		[st->sprite_vert_table release];
		st->sprite_vert_table = nil;
	}
	if (st->pipeline_sprite != nil)
	{
		[st->pipeline_sprite release];
		st->pipeline_sprite = nil;
	}
	if (st->point_particle_vert_table != nil)
	{
		[st->point_particle_vert_table release];
		st->point_particle_vert_table = nil;
	}
	if (st->pipeline_point_particle != nil)
	{
		[st->pipeline_point_particle release];
		st->pipeline_point_particle = nil;
	}
	if (st->particle_frag_table != nil)
	{
		[st->particle_frag_table release];
		st->particle_frag_table = nil;
	}
	if (st->particle_vert_table != nil)
	{
		[st->particle_vert_table release];
		st->particle_vert_table = nil;
	}
	if (st->pipeline_particle != nil)
	{
		[st->pipeline_particle release];
		st->pipeline_particle = nil;
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
			pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

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
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
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
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
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
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

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
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

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
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
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

	/* W5b: sprites (mod_sprite). Same 36-byte vertex layout as the alias
	   models (the CPU writes color = white * alpha per vertex); the UBO is
	   the smaller sprite_ubo_t (viewproj + gamma). Blending is always on,
	   like ref_vk's sprite pipeline; depth state is set per draw. */
	{
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"sprite_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"sprite_fragment";
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
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_sprite = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_sprite == nil)
		{
			Com_Printf("ref_mtl: sprite pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->sprite_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->sprite_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create sprite vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxTextureBindCount = 1;
		atd.maxBufferBindCount = 1;
		st->sprite_frag_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->sprite_frag_table == nil)
		{
			Com_Printf("ref_mtl: failed to create sprite fragment argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W5c: particles. Textured mode reuses the sprite vertex function and
	   UBO (viewproj + gamma); only the fragment threshold differs (0.5,
	   ref_vk basic.frag aTreshold). Point mode computes the attenuated
	   point size in the vertex shader; its fragment has no bindings at
	   all. Both blend like the sprite pipeline (ref_vk default blendOpts). */
	{
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"sprite_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"particle_fragment";
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
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_particle = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_particle == nil)
		{
			Com_Printf("ref_mtl: particle pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->particle_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->particle_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create particle vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxTextureBindCount = 1;
		atd.maxBufferBindCount = 1;
		st->particle_frag_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->particle_frag_table == nil)
		{
			Com_Printf("ref_mtl: failed to create particle fragment argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	{
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"particle_point_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"particle_point_fragment";
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
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_point_particle = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_point_particle == nil)
		{
			Com_Printf("ref_mtl: point particle pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->point_particle_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->point_particle_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create point particle vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W5d: 2D UI (RE_Draw_*). Three pipelines over one static full-screen
	   quad pair, all sharing the 56-byte ui_ubo_t (which rides on the world
	   UBO ring): the tex path samples a picture and applies gamma, the tint
	   path additionally multiplies by the UBO color (crosshair /
	   PicScaledCol), and the color path outputs the UBO color with standard
	   alpha blending (Fill / FadeScreen). The quads are CPU-expanded triangle
	   lists (six vertices, no index buffers in Metal); the tex quad carries a
	   uv per corner, the color quad only positions. No depth: the UI pass has
	   no depth attachment. */
	{
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"ui_tex_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"ui_tex_fragment";
		ff.library = st->library;
		pd.fragmentFunctionDescriptor = ff;

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat2;
		vd.attributes[1].offset = 8;
		vd.attributes[1].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(uitexvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		st->pipeline_ui_tex = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_ui_tex == nil)
		{
			Com_Printf("ref_mtl: ui tex pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->ui_tex_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->ui_tex_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create ui tex vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxTextureBindCount = 1;
		atd.maxBufferBindCount = 1;
		st->ui_tex_frag_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->ui_tex_frag_table == nil)
		{
			Com_Printf("ref_mtl: failed to create ui tex fragment argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	{
		/* tint path: same vertex function and quad, the fragment multiplies
		   by the UBO color after gamma. */
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"ui_tex_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"ui_tint_fragment";
		ff.library = st->library;
		pd.fragmentFunctionDescriptor = ff;

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat2;
		vd.attributes[1].offset = 8;
		vd.attributes[1].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(uitexvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		st->pipeline_ui_tint = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_ui_tint == nil)
		{
			Com_Printf("ref_mtl: ui tint pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->ui_tint_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->ui_tint_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create ui tint vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		atd = [MTL4ArgumentTableDescriptor new];
		atd.maxTextureBindCount = 1;
		atd.maxBufferBindCount = 1;
		st->ui_tint_frag_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->ui_tint_frag_table == nil)
		{
			Com_Printf("ref_mtl: failed to create ui tint fragment argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	{
		/* color path: the UBO color is output by the vertex stage and
		   returned raw by the fragment, standard alpha blend. No fragment
		   argument table (no resource bindings). */
		MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];

		MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor new];
		vf.name = @"ui_color_vertex";
		vf.library = st->library;
		pd.vertexFunctionDescriptor = vf;

		MTL4LibraryFunctionDescriptor *ff = [MTL4LibraryFunctionDescriptor new];
		ff.name = @"ui_color_fragment";
		ff.library = st->library;
		pd.fragmentFunctionDescriptor = ff;

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(uicolorvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_ui_color = [st->compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&err];
		if (st->pipeline_ui_color == nil)
		{
			Com_Printf("ref_mtl: ui color pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 2;
		st->ui_color_vert_table = [st->device newArgumentTableWithDescriptor:atd error:&err];
		if (st->ui_color_vert_table == nil)
		{
			Com_Printf("ref_mtl: failed to create ui color vertex argument table: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* Static UI quads: the ref_vk CreateStaticBuffers texVerts/colorVerts
	   corners expanded through indices {0,1,2, 0,3,1} into triangle lists. */
	st->ui_tex_vertex_buffer = [st->device newBufferWithLength:6 * sizeof(uitexvert_t) options:MTLResourceStorageModeShared];
	if (st->ui_tex_vertex_buffer == nil)
	{
		Com_Printf("ref_mtl: failed to create ui tex vertex buffer\n");
		R_ReleaseShaders(st);
		return false;
	}
	{
		static const float corners[24] = {
			-1.f, -1.f, 0.f, 0.f,  1.f, 1.f, 1.f, 1.f,  -1.f, 1.f, 0.f, 1.f,
			-1.f, -1.f, 0.f, 0.f,  1.f, -1.f, 1.f, 0.f,  1.f, 1.f, 1.f, 1.f,
		};
		uitexvert_t *dst = (uitexvert_t *)st->ui_tex_vertex_buffer.contents;

		for (i = 0; i < 6; i++)
		{
			dst[i].position[0] = corners[i * 4];
			dst[i].position[1] = corners[i * 4 + 1];
			dst[i].uv[0] = corners[i * 4 + 2];
			dst[i].uv[1] = corners[i * 4 + 3];
		}
	}

	st->ui_color_vertex_buffer = [st->device newBufferWithLength:6 * sizeof(uicolorvert_t) options:MTLResourceStorageModeShared];
	if (st->ui_color_vertex_buffer == nil)
	{
		Com_Printf("ref_mtl: failed to create ui color vertex buffer\n");
		R_ReleaseShaders(st);
		return false;
	}
	{
		static const float corners[12] = {
			-1.f, -1.f,  1.f,  1.f,  -1.f,  1.f,
			-1.f, -1.f,  1.f, -1.f,  1.f,  1.f,
		};
		uicolorvert_t *dst = (uicolorvert_t *)st->ui_color_vertex_buffer.contents;

		for (i = 0; i < 6; i++)
		{
			dst[i].position[0] = corners[i * 2];
			dst[i].position[1] = corners[i * 2 + 1];
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
		[st->residency_set addAllocation:st->ui_tex_vertex_buffer];
		[st->residency_set addAllocation:st->ui_color_vertex_buffer];
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

		/* W5d: the 2D UI pass shares the drawable but has no depth
		   attachment; it is opened lazily on the first RE_Draw_* call. */
		st->ui_pass_descriptor = [MTL4RenderPassDescriptor new];
		st->ui_color_attachment = [[MTLRenderPassColorAttachmentDescriptor alloc] init];
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
	/* Non-sRGB: the shaders emit final 8-bit display values (same
	   convention as ref_vk's B8G8R8A8_UNORM swapchain and gl1's raw
	   RGBA8 framebuffer). An sRGB target would make the hardware
	   sRGB-encode on write, brightening the whole image ~2x. */
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
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

	/* W5d: close the 2D UI pass (if one was opened) before the command
	   buffer ends. */
	MTL_EndUIPass();

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
 * W5c: particles (ported from ref_vk R_DrawParticles / Vk_DrawParticles).
 * mtl_custom_particles selects the path, mirroring vk_custom_particles:
 *   1 (default) - point sprites, size and attenuation computed on the GPU
 *   2           - textured triangles with r_squaretexture
 *   otherwise   - textured triangles with the dot texture
 * Vertices ride on the alias vertex ring (36B pos3+uv2+color4; uv is
 * unused in point mode); UBOs ride on the world UBO ring. Blending and
 * depth state match the vk particle pipelines (default blendOpts, depth
 * test + write).
 */

/*
 * Writes one particle_point_ubo_t into the slot's world UBO ring and
 * returns its GPU address (0 when the ring is exhausted).
 */
static MTLGPUAddress
MTL_EmitParticlePointUbo(size_t slot)
{
	mtlstate_t *st = &mtl_state;
	particle_point_ubo_t *ubo;
	MTLGPUAddress addr;

	if (st->world_ubo_offset[slot] + sizeof(particle_point_ubo_t) > WORLD_UBO_RING_BYTES)
		return 0;

	addr = st->world_ubo[slot].gpuAddress + st->world_ubo_offset[slot];
	ubo = (particle_point_ubo_t *)((byte *)st->world_ubo[slot].contents + st->world_ubo_offset[slot]);
	memcpy(ubo->viewproj, r_viewproj_matrix, sizeof(r_viewproj_matrix));
	ubo->pointSize = mtl_particle_size->value;
	ubo->pointScale = vid.width * viewsize->value / 102400;
	ubo->minPointSize = mtl_particle_min_size->value;
	ubo->maxPointSize = mtl_particle_max_size->value;
	ubo->att_a = mtl_particle_att_a->value;
	ubo->att_b = mtl_particle_att_b->value;
	ubo->att_c = mtl_particle_att_c->value;
	st->world_ubo_offset[slot] += sizeof(particle_point_ubo_t);

	return addr;
}

static void
R_DrawParticles(void)
{
	mtlstate_t *st = &mtl_state;
	size_t slot, vstart;
	MTLGPUAddress ubo_addr;

	if (!r_newrefdef.num_particles || st->encoder == nil)
	{
		return;
	}

	if (r_newrefdef.num_particles > MAX_PARTICLES)
	{
		r_newrefdef.num_particles = MAX_PARTICLES;
	}

	slot = st->frame_slot;
	vstart = st->alias_vertex_offset[slot];

	if (mtl_custom_particles->value == 1)
	{
		/* point mode: one vertex per particle, size computed on the GPU */
		static aliasvert_t visibleParticles[MAX_PARTICLES];
		const particle_t *p;
		unsigned color;
		aliasvert_t *dst;
		int i;

		if (vstart + r_newrefdef.num_particles * sizeof(aliasvert_t) > ALIAS_VERTEX_RING_BYTES)
		{
			return;	/* ring exhausted */
		}

		ubo_addr = MTL_EmitParticlePointUbo(slot);
		if (ubo_addr == 0)
		{
			return;	/* UBO ring exhausted */
		}

		for (i = 0, p = r_newrefdef.particles; i < r_newrefdef.num_particles; i++, p++)
		{
			color = d_8to24table[p->color];
			dst = &visibleParticles[i];
			dst->position[0] = p->origin[0];
			dst->position[1] = p->origin[1];
			dst->position[2] = p->origin[2];
			dst->uv[0] = 0;
			dst->uv[1] = 0;
			dst->color[0] = (color & 0xff) / 255.f;
			dst->color[1] = ((color >> 8) & 0xff) / 255.f;
			dst->color[2] = ((color >> 16) & 0xff) / 255.f;
			dst->color[3] = p->alpha;
		}

		memcpy((byte *)st->alias_vertex_buffer[slot].contents + vstart,
		       visibleParticles, r_newrefdef.num_particles * sizeof(aliasvert_t));
		st->alias_vertex_offset[slot] += r_newrefdef.num_particles * sizeof(aliasvert_t);

		[st->point_particle_vert_table setAddress:st->alias_vertex_buffer[slot].gpuAddress + vstart atIndex:0];
		[st->point_particle_vert_table setAddress:ubo_addr atIndex:1];

		[st->encoder setRenderPipelineState:st->pipeline_point_particle];
		[st->encoder setDepthStencilState:st->depth_state];
		[st->encoder setArgumentTable:st->point_particle_vert_table atStages:MTLRenderStageVertex];
		[st->encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:r_newrefdef.num_particles];
	}
	else
	{
		/* textured mode: one triangle per particle (three vertices),
		   uvs centered on the dot/square texture */
		static aliasvert_t visibleParticles[MAX_PARTICLES * 3];
		const particle_t *p;
		vec3_t up, right;
		image_t *skin;
		unsigned color;
		aliasvert_t *dst;
		float scale;
		int i;

		VectorScale(vup, 1.5, up);
		VectorScale(vright, 1.5, right);

		skin = (mtl_custom_particles->value == 2) ? r_squaretexture : r_particletexture;
		if (!skin || skin->mtl_texture == nil)
		{
			return;
		}

		if (vstart + r_newrefdef.num_particles * 3 * sizeof(aliasvert_t) > ALIAS_VERTEX_RING_BYTES)
		{
			return;	/* ring exhausted */
		}

		ubo_addr = MTL_EmitSpriteUbo(slot);
		if (ubo_addr == 0)
		{
			return;	/* UBO ring exhausted */
		}

		for (i = 0, p = r_newrefdef.particles; i < r_newrefdef.num_particles; i++, p++)
		{
			color = d_8to24table[p->color];

			// hack a scale up to keep particles from disapearing
			scale = (p->origin[0] - r_origin[0]) * vpn[0] +
				(p->origin[1] - r_origin[1]) * vpn[1] +
				(p->origin[2] - r_origin[2]) * vpn[2];

			if (scale < 20)
			{
				scale = 1;
			}
			else
			{
				scale = 1 + scale * 0.004;
			}

			dst = &visibleParticles[i * 3];
			dst->position[0] = p->origin[0];
			dst->position[1] = p->origin[1];
			dst->position[2] = p->origin[2];
			dst->uv[0] = 0.0625;
			dst->uv[1] = 0.0625;
			dst->color[0] = (color & 0xff) / 255.f;
			dst->color[1] = ((color >> 8) & 0xff) / 255.f;
			dst->color[2] = ((color >> 16) & 0xff) / 255.f;
			dst->color[3] = p->alpha;
			dst++;

			dst->position[0] = p->origin[0] + up[0] * scale;
			dst->position[1] = p->origin[1] + up[1] * scale;
			dst->position[2] = p->origin[2] + up[2] * scale;
			dst->uv[0] = 1.0625;
			dst->uv[1] = 0.0625;
			dst->color[0] = (color & 0xff) / 255.f;
			dst->color[1] = ((color >> 8) & 0xff) / 255.f;
			dst->color[2] = ((color >> 16) & 0xff) / 255.f;
			dst->color[3] = p->alpha;
			dst++;

			dst->position[0] = p->origin[0] + right[0] * scale;
			dst->position[1] = p->origin[1] + right[1] * scale;
			dst->position[2] = p->origin[2] + right[2] * scale;
			dst->uv[0] = 0.0625;
			dst->uv[1] = 1.0625;
			dst->color[0] = (color & 0xff) / 255.f;
			dst->color[1] = ((color >> 8) & 0xff) / 255.f;
			dst->color[2] = ((color >> 16) & 0xff) / 255.f;
			dst->color[3] = p->alpha;
		}

		memcpy((byte *)st->alias_vertex_buffer[slot].contents + vstart,
		       visibleParticles, r_newrefdef.num_particles * 3 * sizeof(aliasvert_t));
		st->alias_vertex_offset[slot] += r_newrefdef.num_particles * 3 * sizeof(aliasvert_t);

		[st->particle_vert_table setAddress:st->alias_vertex_buffer[slot].gpuAddress + vstart atIndex:0];
		[st->particle_vert_table setAddress:ubo_addr atIndex:1];
		[st->particle_frag_table setTexture:skin->mtl_texture.gpuResourceID atIndex:0];
		[st->particle_frag_table setAddress:ubo_addr atIndex:0];

		[st->encoder setRenderPipelineState:st->pipeline_particle];
		[st->encoder setDepthStencilState:st->depth_state];
		[st->encoder setArgumentTable:st->particle_vert_table atStages:MTLRenderStageVertex];
		[st->encoder setArgumentTable:st->particle_frag_table atStages:MTLRenderStageFragment];
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:r_newrefdef.num_particles * 3];
	}
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

	/* W5d: if the 2D UI opened a pass before the world (SCR_TileClear runs
	   before V_RenderView when viewsize < 100), end it first so the two
	   passes do not overlap, and LOAD the color attachment so the tiles the
	   UI just drew survive outside the (unclipped) world region. Depth still
	   clears. ref_mtl does not scissor the world to the vrect, so this is
	   cosmetically a no-op today; it matches ref_vk and future-proofs a
	   later viewport clip. */
	qboolean ui_before_world = (st->ui_encoder != nil);
	if (ui_before_world)
	{
		MTL_EndUIPass();
	}

	st->color_attachment.texture = st->drawable.texture;
	st->color_attachment.loadAction = ui_before_world ? MTLLoadActionLoad : MTLLoadActionClear;
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
	R_DrawParticles();
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
2D UI (W5d) - ported from ref_vk vk_draw.c
==============

The 2D UI (console, menus, HUD, raw stretched surfaces) is drawn into the
same drawable as the world but in its own render pass with no depth
attachment. Three pipelines share one static full-screen quad pair and one
56-byte ui_ubo_t (which rides on the world UBO ring):
  tex   - sample a picture, apply gamma            (CharScaled/StretchPic/
                                                   TileClear/StretchRaw)
  tint  - like tex, then multiply by the UBO color (PicScaledCol/crosshair)
  color - output the UBO color, standard alpha blend (Fill/FadeScreen)
The NDC math lives in the vertex stage (world.msl ui_*_vertex); here we only
fill the UBO. offset/scale place the quad in pixels, uv_offset/uv_scale map
the picture, color is the tint/clear color and gamma is 2.1 - vid_gamma.
*/

static void
MTL_BeginUIPass(void)
{
	mtlstate_t *st = &mtl_state;

	if (st->ui_encoder != nil)
	{
		return;		// already open
	}

	if (!st->frame_active || st->drawable == nil || st->pipeline_ui_tex == nil)
	{
		return;
	}

	st->ui_color_attachment.texture = st->drawable.texture;
	st->ui_color_attachment.loadAction = MTLLoadActionLoad;
	st->ui_color_attachment.storeAction = MTLStoreActionStore;
	st->ui_pass_descriptor.colorAttachments[0] = st->ui_color_attachment;

	st->ui_encoder = [st->command_buffer renderCommandEncoderWithDescriptor:st->ui_pass_descriptor];
}

static void
MTL_EndUIPass(void)
{
	mtlstate_t *st = &mtl_state;

	if (st->ui_encoder == nil)
	{
		return;
	}

	[st->ui_encoder endEncoding];
	st->ui_encoder = nil;
}

/*
 * Writes one ui_ubo_t into the slot's world UBO ring and returns its GPU
 * address (0 when the ring is exhausted). The ring is a plain byte stream
 * shared with the world UBOs; the offset advances by sizeof(ui_ubo_t) like
 * every other emitter.
 */
static MTLGPUAddress
MTL_EmitUiUbo(size_t slot, const ui_ubo_t *ubo)
{
	mtlstate_t *st = &mtl_state;
	ui_ubo_t *dst;
	MTLGPUAddress addr;

	if (st->world_ubo_offset[slot] + sizeof(ui_ubo_t) > WORLD_UBO_RING_BYTES)
	{
		return 0;
	}

	addr = st->world_ubo[slot].gpuAddress + st->world_ubo_offset[slot];
	dst = (ui_ubo_t *)((byte *)st->world_ubo[slot].contents + st->world_ubo_offset[slot]);
	memcpy(dst, ubo, sizeof(ui_ubo_t));
	st->world_ubo_offset[slot] += sizeof(ui_ubo_t);

	return addr;
}

/*
 * Draws the static textured quad (tex or tint pipeline) with the given UBO.
 * The tex fragment ignores the UBO color (white multiply) but the tint
 * fragment uses it, so it is always written.
 */
static void
MTL_DrawUiTex(image_t *image, const ui_ubo_t *ubo_in, qboolean tint)
{
	mtlstate_t *st = &mtl_state;
	size_t slot = (size_t)st->frame_slot;
	MTLGPUAddress ubo_addr;
	id<MTL4ArgumentTable> vert_table;
	id<MTL4ArgumentTable> frag_table;
	id<MTLRenderPipelineState> pipeline;

	if (image == NULL || image->mtl_texture == nil)
	{
		return;
	}

	ubo_addr = MTL_EmitUiUbo(slot, ubo_in);
	if (ubo_addr == 0)
	{
		return;		// ring exhausted
	}

	vert_table = tint ? st->ui_tint_vert_table : st->ui_tex_vert_table;
	frag_table = tint ? st->ui_tint_frag_table : st->ui_tex_frag_table;
	pipeline = tint ? st->pipeline_ui_tint : st->pipeline_ui_tex;

	[vert_table setAddress:st->ui_tex_vertex_buffer.gpuAddress atIndex:0];
	[vert_table setAddress:ubo_addr atIndex:1];
	[frag_table setTexture:image->mtl_texture.gpuResourceID atIndex:0];
	[frag_table setAddress:ubo_addr atIndex:0];

	[st->ui_encoder setRenderPipelineState:pipeline];
	[st->ui_encoder setArgumentTable:vert_table atStages:MTLRenderStageVertex];
	[st->ui_encoder setArgumentTable:frag_table atStages:MTLRenderStageFragment];
	[st->ui_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

/*
 * Draws the static color quad (color pipeline) with the given UBO. The UBO
 * color is output by the vertex stage and returned raw by the fragment; the
 * pipeline does standard alpha blending.
 */
static void
MTL_DrawUiColor(const ui_ubo_t *ubo_in)
{
	mtlstate_t *st = &mtl_state;
	size_t slot = (size_t)st->frame_slot;
	MTLGPUAddress ubo_addr;

	ubo_addr = MTL_EmitUiUbo(slot, ubo_in);
	if (ubo_addr == 0)
	{
		return;		// ring exhausted
	}

	[st->ui_color_vert_table setAddress:st->ui_color_vertex_buffer.gpuAddress atIndex:0];
	[st->ui_color_vert_table setAddress:ubo_addr atIndex:1];

	[st->ui_encoder setRenderPipelineState:st->pipeline_ui_color];
	[st->ui_encoder setArgumentTable:st->ui_color_vert_table atStages:MTLRenderStageVertex];
	[st->ui_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

static struct image_s *
RE_Draw_FindPic(const char *name)
{
	return R_FindPic(name, (findimage_t)MTL_FindImage);
}

static void
RE_Draw_GetPicSize(int *w, int *h, const char *name)
{
	struct image_s *image;

	image = R_FindPic(name, (findimage_t)MTL_FindImage);
	if (!image)
	{
		*w = -1;
		*h = -1;
		return;
	}

	*w = image->width;
	*h = image->height;
}

/*
 * Shared body for RE_Draw_StretchPic and RE_Draw_PicScaledCol. If `color`
 * is non-NULL the tint pipeline is used (RGB multiply); otherwise the plain
 * textured pipeline.
 */
static void
DrawStretchPicCommon(int x, int y, int w, int h, const char *name, const float *color)
{
	mtlstate_t *st = &mtl_state;
	struct image_s *image;
	ui_ubo_t ubo;

	if (!st->frame_active)
	{
		return;
	}

	image = R_FindPic(name, (findimage_t)MTL_FindImage);
	if (!image)
	{
		Com_Printf("%s(): Can't find pic: %s\n", __func__, name);
		return;
	}

	memset(&ubo, 0, sizeof(ubo));
	ubo.offset[0] = (float)x / vid.width;
	ubo.offset[1] = (float)y / vid.height;
	ubo.scale[0] = (float)w / vid.width;
	ubo.scale[1] = (float)h / vid.height;
	ubo.uv_offset[0] = 0.f;
	ubo.uv_offset[1] = 0.f;
	ubo.uv_scale[0] = 1.f;
	ubo.uv_scale[1] = 1.f;
	if (color)
	{
		ubo.color[0] = color[0];
		ubo.color[1] = color[1];
		ubo.color[2] = color[2];
		ubo.color[3] = 1.f;
	}
	else
	{
		ubo.color[0] = ubo.color[1] = ubo.color[2] = ubo.color[3] = 1.f;
	}
	ubo.gamma = 2.1f - vid_gamma->value;

	MTL_BeginUIPass();
	if (st->ui_encoder == nil)
	{
		return;
	}
	MTL_DrawUiTex(image, &ubo, color != NULL);
}

static void
RE_Draw_StretchPic(int x, int y, int w, int h, const char *name)
{
	DrawStretchPicCommon(x, y, w, h, name, NULL);
}

static void
RE_Draw_PicScaled(int x, int y, const char *pic, float factor)
{
	mtlstate_t *st = &mtl_state;
	struct image_s *image;

	if (!st->frame_active)
	{
		return;
	}

	image = R_FindPic(pic, (findimage_t)MTL_FindImage);
	if (!image)
	{
		Com_Printf("%s(): Can't find pic: %s\n", __func__, pic);
		return;
	}

	RE_Draw_StretchPic(x, y, image->width * factor, image->height * factor, pic);
}

static void
RE_Draw_PicScaledCol(int x, int y, const char *pic, float factor, const float color[3])
{
	mtlstate_t *st = &mtl_state;
	struct image_s *image;

	if (!st->frame_active)
	{
		return;
	}

	image = R_FindPic(pic, (findimage_t)MTL_FindImage);
	if (!image)
	{
		Com_Printf("%s(): Can't find pic: %s\n", __func__, pic);
		return;
	}

	DrawStretchPicCommon(x, y, image->width * factor, image->height * factor, pic, color);
}

/*
 * Draws one 8x8 console character (0 is transparent), scaled. The character
 * index selects a cell in the 16x16 conchars atlas: row = num >> 4,
 * col = num & 15. Clipped to the top of the screen (y <= -8) so the console
 * can scroll off smoothly.
 */
static void
RE_Draw_CharScaled(int x, int y, int num, float scale)
{
	mtlstate_t *st = &mtl_state;
	ui_ubo_t ubo;
	int row, col;
	float frow, fcol, size;

	if (!st->frame_active)
	{
		return;
	}

	num &= 255;

	if ((num & 127) == 32)
	{
		return;		// space
	}

	if (y <= -8)
	{
		return;		// totally off screen
	}

	row = num >> 4;
	col = num & 15;

	frow = row * 0.0625;
	fcol = col * 0.0625;
	size = 0.0625;

	memset(&ubo, 0, sizeof(ubo));
	ubo.offset[0] = (float)x / vid.width;
	ubo.offset[1] = (float)y / vid.height;
	ubo.scale[0] = 8.f * scale / vid.width;
	ubo.scale[1] = 8.f * scale / vid.height;
	ubo.uv_offset[0] = fcol;
	ubo.uv_offset[1] = frow;
	ubo.uv_scale[0] = size;
	ubo.uv_scale[1] = size;
	ubo.color[0] = ubo.color[1] = ubo.color[2] = ubo.color[3] = 1.f;
	ubo.gamma = 2.1f - vid_gamma->value;

	MTL_BeginUIPass();
	if (st->ui_encoder == nil)
	{
		return;
	}
	MTL_DrawUiTex(draw_chars, &ubo, false);
}

/*
 * Repeats a 64x64 tile graphic to fill the screen around a sized-down
 * refresh window. The uv transform maps the (x,y)-(x+w,y+h) pixel region
 * onto (x/64,y/64)-(+w/64,+h/64) so the tile repeats every 64 pixels; the
 * repeating world_sampler wraps it.
 */
static void
RE_Draw_TileClear(int x, int y, int w, int h, const char *name)
{
	mtlstate_t *st = &mtl_state;
	struct image_s *image;
	ui_ubo_t ubo;

	if (!st->frame_active)
	{
		return;
	}

	image = R_FindPic(name, (findimage_t)MTL_FindImage);
	if (!image)
	{
		Com_Printf("%s(): Can't find pic: %s\n", __func__, name);
		return;
	}

	memset(&ubo, 0, sizeof(ubo));
	ubo.offset[0] = (float)x / vid.width;
	ubo.offset[1] = (float)y / vid.height;
	ubo.scale[0] = (float)w / vid.width;
	ubo.scale[1] = (float)h / vid.height;
	ubo.uv_offset[0] = (float)x / 64.f;
	ubo.uv_offset[1] = (float)y / 64.f;
	ubo.uv_scale[0] = (float)w / 64.f;
	ubo.uv_scale[1] = (float)h / 64.f;
	ubo.color[0] = ubo.color[1] = ubo.color[2] = ubo.color[3] = 1.f;
	ubo.gamma = 2.1f - vid_gamma->value;

	MTL_BeginUIPass();
	if (st->ui_encoder == nil)
	{
		return;
	}
	MTL_DrawUiTex(image, &ubo, false);
}

/*
 * Fills a box of pixels with a single palette color (solid quad, alpha 1).
 */
static void
RE_Draw_Fill(int x, int y, int w, int h, int c)
{
	mtlstate_t *st = &mtl_state;
	union
	{
		unsigned	c;
		byte		v[4];
	} color;
	ui_ubo_t ubo;

	if (!st->frame_active)
	{
		return;
	}

	if ((unsigned)c > 255)
	{
		Com_Error(ERR_FATAL, "%s: bad color", __func__);
	}

	color.c = d_8to24table[c];

	memset(&ubo, 0, sizeof(ubo));
	ubo.offset[0] = (float)x / vid.width;
	ubo.offset[1] = (float)y / vid.height;
	ubo.scale[0] = (float)w / vid.width;
	ubo.scale[1] = (float)h / vid.height;
	ubo.color[0] = color.v[0] / 255.f;
	ubo.color[1] = color.v[1] / 255.f;
	ubo.color[2] = color.v[2] / 255.f;
	ubo.color[3] = 1.f;
	ubo.gamma = 2.1f - vid_gamma->value;

	MTL_BeginUIPass();
	if (st->ui_encoder == nil)
	{
		return;
	}
	MTL_DrawUiColor(&ubo);
}

/*
 * Fades the whole screen with a translucent black overlay (death / damage
 * feedback). Passes raw pixel dimensions as the scale, so the quad is
 * intentionally oversized and clipped to the screen by the rasterizer.
 */
static void
RE_Draw_FadeScreen(void)
{
	mtlstate_t *st = &mtl_state;
	ui_ubo_t ubo;

	if (!st->frame_active)
	{
		return;
	}

	memset(&ubo, 0, sizeof(ubo));
	ubo.offset[0] = 0.f;
	ubo.offset[1] = 0.f;
	ubo.scale[0] = (float)vid.width;
	ubo.scale[1] = (float)vid.height;
	ubo.color[0] = 0.f;
	ubo.color[1] = 0.f;
	ubo.color[2] = 0.f;
	ubo.color[3] = 0.8f;
	ubo.gamma = 2.1f - vid_gamma->value;

	MTL_BeginUIPass();
	if (st->ui_encoder == nil)
	{
		return;
	}
	MTL_DrawUiColor(&ubo);
}

/*
 * Stretches a raw pixel buffer (palette-indexed or 32-bit) into the screen.
 * The buffer is converted to RGBA32 (applying r_retexturing 2x/3x scaling
 * and smoothing for palette data), uploaded to a persistent dynamic texture,
 * and drawn as a textured quad.
 */
static void
RE_Draw_StretchRaw(int x, int y, int w, int h, int cols, int rows, const byte *data, int bits)
{
	mtlstate_t *st = &mtl_state;
	ui_ubo_t ubo;
	int i, j;
	unsigned *dest;
	byte *source;
	byte *image_scaled = NULL;
	unsigned *raw_image32;

	if (!st->frame_active)
	{
		return;
	}

	if (bits == 32)
	{
		raw_image32 = malloc((size_t)cols * rows * sizeof(unsigned));
		if (!raw_image32)
		{
			return;
		}
		memcpy(raw_image32, data, (size_t)cols * rows * sizeof(unsigned));
	}
	else
	{
		if (r_retexturing->value)
		{
			// triple scaling
			if (cols < (vid.width / 3) || rows < (vid.height / 3))
			{
				image_scaled = malloc((size_t)cols * rows * 9);
				scale3x(data, image_scaled, cols, rows);
				cols = cols * 3;
				rows = rows * 3;
			}
			else
			// double scaling
			{
				image_scaled = malloc((size_t)cols * rows * 4);
				scale2x(data, image_scaled, cols, rows);
				cols = cols * 2;
				rows = rows * 2;
			}
		}
		else
		{
			image_scaled = (byte *)data;
		}

		raw_image32 = malloc((size_t)cols * rows * sizeof(unsigned));
		if (!raw_image32)
		{
			if (image_scaled != data)
			{
				free(image_scaled);
			}
			return;
		}

		source = image_scaled;
		dest = raw_image32;
		for (i = 0; i < rows; ++i)
		{
			int rowOffset = i * cols;
			for (j = 0; j < cols; ++j)
			{
				byte palIdx = source[rowOffset + j];
				dest[rowOffset + j] = r_rawpalette[palIdx];
			}
		}

		if (r_retexturing->value)
		{
			int scaled_size = cols * rows;
			free(image_scaled);
			SmoothColorImage(raw_image32, scaled_size, (size_t)scaled_size >> 7);
		}
	}

	/* (Re)create the dynamic texture when the size changes. */
	if (raw_texture != nil &&
	    (raw_texture_width != cols || raw_texture_height != rows))
	{
		[st->residency_set removeAllocation:raw_texture];
		[raw_texture release];
		raw_texture = nil;
	}

	if (raw_texture == nil)
	{
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
		        MTLPixelFormatRGBA8Unorm
		        width:(NSUInteger)cols
		        height:(NSUInteger)rows
		        mipmapped:NO];
		td.storageMode = MTLStorageModeShared;
		raw_texture = [st->device newTextureWithDescriptor:td];
		if (raw_texture == nil)
		{
			free(raw_image32);
			return;
		}
		[st->residency_set addAllocation:raw_texture];
		[st->residency_set commit];
		raw_texture_width = cols;
		raw_texture_height = rows;
	}

	[raw_texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)cols, (NSUInteger)rows)
	        mipmapLevel:0 slice:0 withBytes:raw_image32
	        bytesPerRow:cols * 4 bytesPerImage:cols * rows * 4];

	free(raw_image32);

	/* Draw the raw texture as a quad. */
	{
		struct image_s fake;

		memset(&fake, 0, sizeof(fake));
		fake.mtl_texture = raw_texture;

		memset(&ubo, 0, sizeof(ubo));
		ubo.offset[0] = (float)x / vid.width;
		ubo.offset[1] = (float)y / vid.height;
		ubo.scale[0] = (float)w / vid.width;
		ubo.scale[1] = (float)h / vid.height;
		ubo.uv_offset[0] = 0.f;
		ubo.uv_offset[1] = 0.f;
		ubo.uv_scale[0] = 1.f;
		ubo.uv_scale[1] = 1.f;
		ubo.color[0] = ubo.color[1] = ubo.color[2] = ubo.color[3] = 1.f;
		ubo.gamma = 2.1f - vid_gamma->value;

		MTL_BeginUIPass();
		if (st->ui_encoder == nil)
		{
			return;
		}
		MTL_DrawUiTex(&fake, &ubo, false);
	}
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
