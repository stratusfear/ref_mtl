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
static cvar_t	*mtl_underwater;	// W6b: underwater screen warp (vk_underwater parity)
static cvar_t	*mtl_postprocess;	// W6c: world postprocess (vk_postprocess parity)
static cvar_t	*mtl_pixel_size;	// W6e: world downscale (vk_pixel_size parity)
static cvar_t	*mtl_msaa;		// W7: world MSAA (vk_msaa parity)

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
cvar_t		*r_anisotropic;		/* M2: registered here, see RE_Init */
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
	/* M2: max anisotropy, same name/default/semantics as ref_vk's
	   vk_aniso (vk_main.c:1166): 0 disables, values clamp to the API
	   maximum (16 on Metal, cf. vk_common.c:906). */
	r_anisotropic = ri.Cvar_Get("r_anisotropic", "0", CVAR_ARCHIVE);
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
	mtl_underwater = ri.Cvar_Get("mtl_underwater", "1", CVAR_ARCHIVE);
	mtl_postprocess = ri.Cvar_Get("mtl_postprocess", "1", CVAR_ARCHIVE);
	mtl_pixel_size = ri.Cvar_Get("mtl_pixel_size", "1", CVAR_ARCHIVE);
	/* W7: ref_vk registers the same host-side MSAA cvar (vk_main.c:
	   Cvar_Get("r_msaa_samples", "0", CVAR_ARCHIVE)); negative values
	   are clamped away there, keep the identical clamp. */
	mtl_msaa = ri.Cvar_Get("r_msaa_samples", "0", CVAR_ARCHIVE);
	if (mtl_msaa->value < 0)
	{
		ri.Cvar_SetValue("r_msaa_samples", 0);
	}
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

	/* O3: the RDF_NOWORLDMODEL backdrop ref_vk draws here
	   (QVk_DrawColorRect, vk_main.c:684) needs the mtl UI pass and the
	   refdef rectangle before the world pass descriptor is built, so it
	   lives in RE_RenderFrame instead; see the noworld block there. The
	   rest of this function follows ref_vk: the cluster lookup above is
	   skipped for the flag, and the projection/view matrices are built
	   from the (menu) refdef so the model lands inside the rect. */

	// set up projection matrix
	{
		float dist;

		if (r_farsee->value)
		{
			dist = 8192;
		}
		else
		{
			dist = 4096;
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

/* W5d: RE_Draw_StretchRaw's dynamic textures, recreated when the size
   changes (see RE_Draw_StretchRaw). L3: one per frame slot, like G4's
   dynamic lightmaps: a single shared texture rewritten with
   replaceRegion while the 1-2 command buffers still in flight sample
   it let consecutive video frames tear or mix. Frame N now writes and
   samples only slot frame_slot's copy. */
static id<MTLTexture> raw_textures[3];
static int raw_textures_width[3];
static int raw_textures_height[3];
/* L5: one-shot console note for a failed 2x/3x retexturing alloc. */
static int raw_scale_oom_warned;

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

static qboolean
MTL_InitWorldPipelines(mtlstate_t *st, NSUInteger sampleCount);

static void
MTL_ReleaseMSAADrawBuffers(mtlstate_t *st);

/* W5d: 2D UI pass (see the definitions before RE_Draw_FindPic). */
static void
MTL_BeginUIPass(void);
static void
MTL_EndUIPass(void);
static void
MTL_DrawUiColor(const ui_ubo_t *ubo_in);	/* O3: used from RE_RenderFrame */

static void
RE_ScreenShot_f(void);

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

	/* W9: startup device dump, ref_vk's Vk_Strings_f() parity. The
	   device, layer and shaders all exist by now (R_SetMode above ran
	   RE_InitContext + R_InitShaders). */
	Mtl_Strings_f();

	ri.Cmd_AddCommand("screenshot", RE_ScreenShot_f);
	ri.Cmd_AddCommand("mtl_strings", Mtl_Strings_f);
	ri.Cmd_AddCommand("mtl_mem", Mtl_Mem_f);
	ri.Cmd_AddCommand("imagelist", MTL_ImageList_f);
	ri.Cmd_AddCommand("modellist", Mod_Modellist_f);

	Com_Printf("Successfully initialized Metal 4 refresher!\n");

	return true;
}

/*
 ==============
 MTL_AbandonOpenFrame

 Discard a frame left open by a mid-frame error: end any open
 encoder first (releasing a command buffer with an encoder still
 open is a debug-layer assertion), drop the uncommitted command
 buffer, free the abandoned frame's own slot, clear frame_active.
 Callers must invoke it while frame_slot / frame_number still
 refer to the abandoned frame - in RE_BeginFrame that means before
 the frame counter is advanced.
 ==============
*/
static void
MTL_AbandonOpenFrame(void)
{
	mtlstate_t *st = &mtl_state;

	if (!st->frame_active)
	{
		return;
	}

	if (st->encoder != nil)
	{
		[st->encoder endEncoding];
		st->encoder = nil;
	}
	if (st->ui_encoder != nil)
	{
		[st->ui_encoder endEncoding];
		st->ui_encoder = nil;
	}
	if (st->command_buffer != nil)
	{
		[st->command_buffer release];
		st->command_buffer = nil;
	}
	atomic_store_explicit(&st->slot_busy[st->frame_slot], false,
	                      memory_order_release);
	st->frame_active = false;

	Com_DPrintf("ref_mtl: discarding frame %llu left open by a "
	            "mid-frame error\n", (unsigned long long)st->frame_number);
}

/*
 ==============
 MTL_BuildWorldSamplers

 M2: (re)create the world-path sampling states. The filtered pair
 carries maxAnisotropy from r_anisotropic, clamped like ref_vk
 (vk_common.c:906: max(Q_max(v,1), device max); Metal's range is a
 fixed 1..16); the nearest variant has no anisotropy, mirroring
 vk's S_NEAREST which keeps anisotropy off too. Address modes keep
 the old constexpr samplers: world repeats, lightmap clamps. On
 failure the partially built set is dropped and the existing
 states (possibly nil at first init) are left untouched, so a
 rebuild failure keeps the previous sampling working.
 ==============
*/
static qboolean
MTL_BuildWorldSamplers(mtlstate_t *st)
{
	id<MTLSamplerState>	world, nearest, lmap;
	MTLSamplerDescriptor	*sd;
	float			aniso;

	aniso = r_anisotropic->value;
	if (aniso < 1.f)
	{
		aniso = 1.f;
	}
	else if (aniso > 16.f)
	{
		aniso = 16.f;
	}

	sd = [MTLSamplerDescriptor new];
	sd.sAddressMode = MTLSamplerAddressModeRepeat;
	sd.tAddressMode = MTLSamplerAddressModeRepeat;
	sd.minFilter = MTLSamplerMinMagFilterLinear;
	sd.magFilter = MTLSamplerMinMagFilterLinear;
	sd.mipFilter = MTLSamplerMipFilterLinear;
	sd.maxAnisotropy = aniso;
	world = [st->device newSamplerStateWithDescriptor:sd];

	sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
	sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
	lmap = [st->device newSamplerStateWithDescriptor:sd];

	sd.sAddressMode = MTLSamplerAddressModeRepeat;
	sd.tAddressMode = MTLSamplerAddressModeRepeat;
	sd.minFilter = MTLSamplerMinMagFilterNearest;
	sd.magFilter = MTLSamplerMinMagFilterNearest;
	sd.mipFilter = MTLSamplerMipFilterNearest;
	sd.maxAnisotropy = 1.f;
	nearest = [st->device newSamplerStateWithDescriptor:sd];
	[sd release];	/* G1: manual RC, sd is +1 and not kept */

	if (world == nil || lmap == nil || nearest == nil)
	{
		[world release];
		[lmap release];
		[nearest release];
		return false;
	}

	[st->world_sampler release];
	[st->lmap_sampler release];
	[st->world_sampler_nearest release];
	st->world_sampler = world;
	st->lmap_sampler = lmap;
	st->world_sampler_nearest = nearest;
	return true;
}

/*
==============
MTL_DrainInFlightFrames

L1: the ref_vk equivalent of vkDeviceWaitIdle in
QVk_WaitAndShutdownAll (vk_main.c). Up to three frames can be in
flight; their addCompletedHandler: blocks (installed in
RE_EndFrame) run on Metal worker threads and write to
mtl_state.slot_busy, a static in this dylib. The host calls
Sys_FreeLibrary right after re.Shutdown(), so any handler still
running at that point executes unmapped code. Wait for every
slot's handler before releasing anything.

A frame left open by Com_Error mid-frame is handled separately:
RE_BeginFrame set the slot's busy flag but RE_EndFrame's commit
never ran, so no completion handler will ever fire - drop the
uncommitted command buffer and clear the flag instead of spinning
on it (MTL_AbandonOpenFrame). frame_active is an exact marker for
that state: it is cleared at the very top of RE_EndFrame, and
nothing between there and the commit has an error path (all
encoding failures are DPrintf + skip); every real error path, warp
and UI Sys_Error included, runs while frame_active is still set.

M7B2: ERR_DROP while the renderer stays alive (the host returns to
the console and the game keeps rendering) left that abandoned slot
busy forever - every third frame then stalled a second on the CPU
gate. RE_BeginFrame calls MTL_AbandonOpenFrame for the previous
frame before advancing the frame counter, so the abandoned frame's
slot is the one released.
==============
*/
static void
MTL_DrainInFlightFrames(void)
{
	mtlstate_t *st = &mtl_state;
	int slot;

	if (st->device == nil)
	{
		return; // never initialized, nothing can be in flight
	}

	if (st->frame_active)
	{
		MTL_AbandonOpenFrame();
	}

	for (slot = 0; slot < 3; slot++)
	{
		int waited = 0;

		while (atomic_load_explicit(&st->slot_busy[slot],
		                            memory_order_acquire))
		{
			if (++waited > 2000)
			{
				Com_Printf("ref_mtl: GPU frame in slot %d still "
				           "in flight after 2 s, continuing\n",
				           slot);
				break;
			}
			SDL_Delay(1);
		}
	}

	/* The handler clears its flag as its last action, but the block
	   can still be a few instructions from returning when the clear
	   is observed; a short grace period dwarfs that window before
	   the releases - and, in RE_Shutdown, the eventual dlclose -
	   proceed. */
	SDL_Delay(20);
}

/*
==============
RE_ShutdownContext

Shuts down the window specific context (Metal view and layer). Called
by the host before the window is destroyed (mode change) or the
renderer is shut down. The device, command queue and shaders survive
mode changes and are released in RE_Shutdown.
==============
*/
static void
RE_ShutdownContext(void)
{
	mtlstate_t *st = &mtl_state;

	// L1: no frame may outlive the context or the dylib
	MTL_DrainInFlightFrames();

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

	/* L1: drain again at the top of the full shutdown (the drain is
	   idempotent): RE_Shutdown also releases the queue/device and
	   zeroes mtl_state, and nothing in flight may touch any of it. */
	MTL_DrainInFlightFrames();

	/* L2: remove every command this dylib registered, not just
	   "screenshot": the host dlcloses the renderer right after
	   RE_Shutdown, and a leftover command keeps a function pointer
	   into unmapped code (typing imagelist/modellist after a
	   renderer switch jumps into freed memory, and the next
	   RE_Init's Cmd_AddCommand would fail "already defined" and
	   keep the stale pointer). ref_vk removes its five the same way
	   (vk_main.c:1342-1346). */
	ri.Cmd_RemoveCommand("screenshot");
	ri.Cmd_RemoveCommand("mtl_strings");
	ri.Cmd_RemoveCommand("mtl_mem");
	ri.Cmd_RemoveCommand("imagelist");
	ri.Cmd_RemoveCommand("modellist");

	RE_ShutdownContext();

	/* L2: free the model tables and loaded model data before the
	   images they reference go away, matching QVk_WaitAndShutdownAll
	   (Mod_FreeAll/Mod_FreeModelsKnown before Vk_ShutdownImages);
	   both were missing entirely, so the known-model table and the
	   loaded models' hunks leaked on every renderer restart.
	   M7B3: reset the model counters afterwards (helper lives in
	   mtl_model.m; mod_numknown/mod_loaded are static there) so a
	   second RE_Shutdown cannot walk a freed table in Mod_FreeAll;
	   vk dodges this with its vk_initialized guard, we have no
	   guard, so the teardown must leave the tables self-consistent. */
	Mod_FreeAll();
	Mod_FreeModelsKnown();
	Mod_ResetKnown();

	/* G1: MTL_ShutdownImages had no call site, so the image textures
	   and lightmap textures survived (leaked) a renderer shutdown;
	   ref_vk's equivalent calls Vk_ShutdownImages() from
	   QVk_WaitAndShutdownAll(). The command queue is still alive at
	   this point, matching that ordering. */
	MTL_ShutdownImages();

	// W5d/L3: StretchRaw's dynamic textures, all three slots
	for (int i = 0; i < 3; i++)
	{
		if (raw_textures[i] != nil)
		{
			[raw_textures[i] release];
			raw_textures[i] = nil;
		}
		raw_textures_width[i] = 0;
		raw_textures_height[i] = 0;
	}

	// W2: shaders and test resources
	R_ReleaseShaders(st);

	/* W7: the MSAA sample-count bookkeeping resets with the context;
	   RE_InitContext rebuilds the world pipelines at 1 sample. */
	st->msaa_sample_count = 1;
	st->pipeline_sample_count = 1;

	if (st->pass_descriptor != nil)
	{
		[st->pass_descriptor release];
	}
	if (st->ui_pass_descriptor != nil)
	{
		[st->ui_pass_descriptor release];
	}
	if (st->present_pass_descriptor != nil)
	{
		[st->present_pass_descriptor release];
	}
	if (st->command_buffer != nil)
	{
		[st->command_buffer release];
		st->command_buffer = nil;
	}
	if (st->command_queue != nil)
	{
		[st->command_queue release];
	}
	if (st->device != nil)
	{
		[st->device release];
	}

	/* L2: host-memory scratch buffers, freed last (ref_vk frees
	   s_blocklights at the end of its RE_Shutdown, and the lerped
	   vertex buffer in Mesh_Free); their capacity counters reset so
	   the next RE_Init reallocates on demand. */
	MTL_ShutdownLightScratch();
	MTL_ShutdownAliasScratch();

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
		if (st->beam_vertex_buffer[i] != nil)
		{
			[st->beam_vertex_buffer[i] release];
			st->beam_vertex_buffer[i] = nil;
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
	if (st->pipeline_present != nil)
	{
		[st->pipeline_present release];
		st->pipeline_present = nil;
	}
	if (st->pipeline_warp != nil)
	{
		[st->pipeline_warp release];
		st->pipeline_warp = nil;
	}
	if (st->warp_texture != nil)
	{
		[st->warp_texture release];
		st->warp_texture = nil;
	}
	if (st->pipeline_postprocess != nil)
	{
		[st->pipeline_postprocess release];
		st->pipeline_postprocess = nil;
	}
	if (st->post_texture != nil)
	{
		[st->post_texture release];
		st->post_texture = nil;
	}
	st->ui_target = nil;
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
	if (st->ui_sampler_nearest != nil)
	{
		[st->ui_sampler_nearest release];
		st->ui_sampler_nearest = nil;
	}
	if (st->ui_sampler_linear != nil)
	{
		[st->ui_sampler_linear release];
		st->ui_sampler_linear = nil;
	}
	/* M2: the world-path sampling states. */
	if (st->world_sampler != nil)
	{
		[st->world_sampler release];
		st->world_sampler = nil;
	}
	if (st->world_sampler_nearest != nil)
	{
		[st->world_sampler_nearest release];
		st->world_sampler_nearest = nil;
	}
	if (st->lmap_sampler != nil)
	{
		[st->lmap_sampler release];
		st->lmap_sampler = nil;
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
		st->depth_width = st->depth_height = 0;
	}
	if (st->scene_texture != nil)
	{
		[st->scene_texture release];
		st->scene_texture = nil;
		st->scene_width = st->scene_height = 0;
	}
	/* W7: MSAA attachments and the pre-world save copy ride along with
	   the scene/depth textures (recreated by MTL_UpdateMSAA / the
	   BeginFrame resize block). */
	MTL_ReleaseMSAADrawBuffers(st);
	if (st->border_save_texture != nil)
	{
		[st->border_save_texture release];
		st->border_save_texture = nil;
	}
	if (st->pipeline_dlight != nil)
	{
		[st->pipeline_dlight release];
		st->pipeline_dlight = nil;
	}
	if (st->pipeline_beam != nil)
	{
		[st->pipeline_beam release];
		st->pipeline_beam = nil;
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
	if (st->pipeline_sprite != nil)
	{
		[st->pipeline_sprite release];
		st->pipeline_sprite = nil;
	}
	if (st->pipeline_point_particle != nil)
	{
		[st->pipeline_point_particle release];
		st->pipeline_point_particle = nil;
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
============
MTL_InitWorldPipelines

W7: all world-pass render pipelines, created at the given raster sample
count. ref_vk parity: MSAA (r_msaa_samples) only affects the world
render pass (RP_WORLD), so the world pipelines are rebuilt when the
sample count changes while the UI / warp / postprocess / present
pipelines stay at 1 sample.

The creation blocks were factored out of R_InitShaders verbatim; the
only changes are `pd.rasterSampleCount = sampleCount;`,
`pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;` (F7: the
world pass always carries a Depth32Float attachment and the debug layer
asserts on the mismatch) and the failure
returns. Called with sampleCount 1 from R_InitShaders and again from
MTL_UpdateMSAA when r_msaa_samples changes.
============
*/
static qboolean
MTL_InitWorldPipelines(mtlstate_t *st, NSUInteger sampleCount)
{
	NSError *err = nil;
	int i;
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
			MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

			pd.vertexFunction = [st->library newFunctionWithName:
			    [NSString stringWithUTF8String:pipelines[i].vertex]];
			pd.fragmentFunction = [st->library newFunctionWithName:
			    [NSString stringWithUTF8String:pipelines[i].fragment]];

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

			pd.rasterSampleCount = sampleCount;
			pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
			pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

			/* ref_vk parity: vk_drawPolyPipeline / vk_drawPolyWarpPipeline
			   (this pipeline covers both roles) draw with blending enabled
			   (SRC_ALPHA / ONE_MINUS_SRC_ALPHA); that is how the
			   SURF_TRANS33/66 alpha-surface chain renders glass at
			   color[3] = 0.33 / 0.66. Opaque chains pass alpha = 1, where
			   the blend is the identity, exactly as in ref_vk. */
			if (i == 0)
			{
				pd.colorAttachments[0].blendingEnabled = YES;
				pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
				pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
				pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
				pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
			}

			id<MTLRenderPipelineState> pipeline = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
			/* G1: manual RC - pd and its +1 objects (functions from
			   newFunctionWithName, vd) are not kept by the pipeline
			   state; release once it is built, before the nil check so
			   the failure path balances too. */
			[pd.vertexFunction release];
			[pd.fragmentFunction release];
			[pd release];
			[vd release];
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
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"dlight_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"dlight_fragment"];

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat3;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat3;
		vd.attributes[1].offset = 12;
		vd.attributes[1].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(dlightvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_dlight = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];
		if (st->pipeline_dlight == nil)
		{
			Com_Printf("ref_mtl: dlight pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* I1: RF_BEAM tubes (R_DrawBeam). 28-byte vertices (pos3 + color4),
	   standard alpha blend and no depth write, matching the vk beam
	   pipeline (basic_color_quad frag, default SRC_ALPHA /
	   ONE_MINUS_SRC_ALPHA, depthWriteEnable VK_FALSE). The cull/winding
	   state rides on the encoder (clockwise front winding, back-face
	   culling, matching the vk pipeline's default CULL_MODE_BACK under
	   the CLOCKWISE global frontFace; see R_DrawBeam). */
	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"beam_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"beam_fragment"];

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat3;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat4;
		vd.attributes[1].offset = 12;
		vd.attributes[1].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(beamvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_beam = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];
		if (st->pipeline_beam == nil)
		{
			Com_Printf("ref_mtl: beam pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W4: view flash (R_PolyBlend). Full-screen clip-space quad with a
	   uniform color from v_blend, standard alpha blend (matching the vk
	   color-rect pipeline), no depth test or write. The six vertices are
	   static; the color is written into the world UBO ring per frame. */
	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"flash_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"flash_fragment"];

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(flashvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_flash = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];
		if (st->pipeline_flash == nil)
		{
			Com_Printf("ref_mtl: flash pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W4: showtris (R_DrawTriangleOutlines). Reuses the dlight vertex and
	   fragment functions (same 24B pos+color layout, same viewproj UBO);
	   the differences live in the pipeline/encoder state - no blend, and
	   the draws are line primitives with culling and depth test disabled
	   (see R_DrawTriangleOutlines). */
	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"dlight_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"dlight_fragment"];

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat3;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.attributes[1].format = MTLVertexFormatFloat3;
		vd.attributes[1].offset = 12;
		vd.attributes[1].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(dlightvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		st->pipeline_showtris = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];
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
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"alias_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"alias_fragment"];

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

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		st->pipeline_alias = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];	/* G1: manual RC; vd is shared with the next pd,
						   released once below with that one */
		if (st->pipeline_alias == nil)
		{
			Com_Printf("ref_mtl: alias pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

		pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [st->library newFunctionWithName:@"alias_vertex"];
		pd.fragmentFunction = [st->library newFunctionWithName:@"alias_fragment"];
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_alias_translucent = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_alias_translucent == nil)
		{
			Com_Printf("ref_mtl: alias translucent pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}


	}

	/* W5b: sprites (mod_sprite). Same 36-byte vertex layout as the alias
	   models (the CPU writes color = white * alpha per vertex); the UBO is
	   the smaller sprite_ubo_t (viewproj + gamma). Blending is always on,
	   like ref_vk's sprite pipeline; depth state is set per draw. */
	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"sprite_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"sprite_fragment"];

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

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_sprite = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_sprite == nil)
		{
			Com_Printf("ref_mtl: sprite pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
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
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"sprite_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"particle_fragment"];

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

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_particle = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_particle == nil)
		{
			Com_Printf("ref_mtl: particle pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}


	}

	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"particle_point_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"particle_point_fragment"];

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

		pd.rasterSampleCount = sampleCount;
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_point_particle = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_point_particle == nil)
		{
			Com_Printf("ref_mtl: point particle pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}

	}
	return true;
}

/*
============
MTL_ReleaseWorldPipelines

W7: drop the world-pass pipelines for an MSAA sample-count rebuild.
Same block of states R_ReleaseShaders releases (that one additionally
frees the library, the rings and the UI side, which stay).
============
*/
static void
MTL_ReleaseWorldPipelines(mtlstate_t *st)
{
	id<MTLRenderPipelineState> *pps[] = {
		&st->pipeline_plain,
		&st->pipeline_lmap,
		&st->pipeline_sky,
		&st->pipeline_dlight,
		&st->pipeline_beam,
		&st->pipeline_flash,
		&st->pipeline_showtris,
		&st->pipeline_alias,
		&st->pipeline_alias_translucent,
		&st->pipeline_sprite,
		&st->pipeline_particle,
		&st->pipeline_point_particle,
	};
	size_t i;

	for (i = 0; i < sizeof(pps) / sizeof(pps[0]); i++)
	{
		if (*pps[i] != nil)
		{
			[*pps[i] release];
			*pps[i] = nil;
		}
	}
}

/*
============
MTL_DesiredSampleCount

W7: the MSAA sample count for the world pass from r_msaa_samples,
mirroring ref_vk's GetSampleCount(): walk the power-of-two ladder down
from 16 and take the largest count that is both requested (value >=
count) and supported by the device for the scene color format
(ref_vk: framebufferColorSampleLimits). Values < 2 (0 = off) give 1.
============
*/
static NSUInteger
MTL_DesiredSampleCount(void)
{
	NSUInteger value;

	if (mtl_msaa == nil || (int)mtl_msaa->value < 2)
	{
		return 1;
	}

	for (value = 16; value >= 2; value >>= 1)
	{
		if ((int)mtl_msaa->value >= (int)value &&
		    [mtl_state.device supportsTextureSampleCount:value])
		{
			return value;
		}
	}
	return 1;
}

/*
============
MTL_CreateMSAADrawBuffers / MTL_ReleaseMSAADrawBuffers

W7: the multisampled world attachments (ref_vk CreateDrawBuffers with
sampleCount > 1: vk_msaaColorbuffer plus a multisampled vk_depthbuffer,
while vk_colorbuffer and vk_ui_depthbuffer stay single-sample). Sized
like scene_texture / depth_texture.
============
*/
static void
MTL_ReleaseMSAADrawBuffers(mtlstate_t *st)
{
	if (st->msaa_color_texture != nil)
	{
		[st->msaa_color_texture release];
		st->msaa_color_texture = nil;
	}
	if (st->msaa_depth_texture != nil)
	{
		[st->msaa_depth_texture release];
		st->msaa_depth_texture = nil;
	}
}

static qboolean
MTL_CreateMSAADrawBuffers(mtlstate_t *st, NSUInteger sampleCount)
{
	MTLTextureDescriptor *d;

	d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
	        MTLPixelFormatBGRA8Unorm
	        width:(NSUInteger)st->scene_width
	        height:(NSUInteger)st->scene_height
	        mipmapped:NO];
	d.textureType = MTLTextureType2DMultisample;	// 2D rejects sampleCount
	d.usage = MTLTextureUsageRenderTarget;
	/* F5: GPU-only render target; Private lets the driver deduplicate
	   and compress on Apple GPUs. */
	d.storageMode = MTLStorageModePrivate;
	d.sampleCount = sampleCount;
	st->msaa_color_texture = [st->device newTextureWithDescriptor:d];
	if (st->msaa_color_texture == nil)
	{
		Com_Printf("ref_mtl: failed to create %ux MSAA color texture\n",
			(unsigned int)sampleCount);
		return false;
	}

	d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
	        MTLPixelFormatDepth32Float
	        width:(NSUInteger)st->depth_width
	        height:(NSUInteger)st->depth_height
	        mipmapped:NO];
	d.textureType = MTLTextureType2DMultisample;
	d.usage = MTLTextureUsageRenderTarget;
	d.storageMode = MTLStorageModePrivate;	// F5: GPU-only, see above
	d.sampleCount = sampleCount;
	st->msaa_depth_texture = [st->device newTextureWithDescriptor:d];
	if (st->msaa_depth_texture == nil)
	{
		Com_Printf("ref_mtl: failed to create %ux MSAA depth texture\n",
			(unsigned int)sampleCount);
		MTL_ReleaseMSAADrawBuffers(st);
		return false;
	}

	return true;
}

/*
============
MTL_UpdateMSAA

W7: rebuild the world-pass pipelines and multisampled attachments when
r_msaa_samples changes. ref_vk handles the same cvar through
R_SetMode() (it clears vk_msaa->modified) with the render passes and
draw buffers rebuilt in QVk_RecreateSwapchain() -> R_InitVulkan(),
which prints "...MSAAx%d is used" from GetSampleCount(). Checked every
frame here instead: the pipeline/texture swap is cheap, and the host's
video menu may set the cvar without a mode change. Called from
RE_BeginFrame before the frame's command buffer / encoders exist.
============
*/
static void
MTL_UpdateMSAA(mtlstate_t *st)
{
	NSUInteger want = MTL_DesiredSampleCount();

	/* F2b: a request that already failed stays degraded at 1 sample
	   until the cvar changes; this stops the per-frame teardown,
	   rebuild and error print. */
	if (want == st->msaa_failed_want)
	{
		return;
	}

	if (want == st->msaa_sample_count && st->pipeline_sample_count == want)
	{
		st->msaa_failed_want = 0;
		return;
	}

	MTL_ReleaseWorldPipelines(st);
	MTL_ReleaseMSAADrawBuffers(st);

	/* F2a: create the multisampled attachments before the pipelines,
	   so the world pipelines are always built at the sample count the
	   frame buffers can actually provide. */
	if (want > 1 && MTL_CreateMSAADrawBuffers(st, want))
	{
		st->msaa_sample_count = want;
	}
	else
	{
		st->msaa_sample_count = 1;
		if (want > 1)
		{
			Com_Printf("ref_mtl: %ux MSAA draw buffers failed, running without MSAA\n",
				(unsigned int)want);
			st->msaa_failed_want = want;
		}
	}

	if (!MTL_InitWorldPipelines(st, st->msaa_sample_count))
	{
		/* F2c: even the 1-sample fallback matters - the world pass is
		   skipped while pipeline_plain is nil, and msaa_failed_want
		   keeps this from being retried every frame. */
		Com_Printf("ref_mtl: rebuilding world pipelines at %ux samples failed\n",
			(unsigned int)st->msaa_sample_count);
		MTL_ReleaseMSAADrawBuffers(st);
		st->msaa_sample_count = 0;
		st->pipeline_sample_count = 0;
		st->msaa_failed_want = want;
		if (MTL_InitWorldPipelines(st, 1))
		{
			st->msaa_sample_count = st->pipeline_sample_count = 1;
		}
		return;
	}
	st->pipeline_sample_count = st->msaa_sample_count;

	/* Only a request that came up at full count clears the
	   degradation mark; a draw-buffer fallback keeps it set. */
	if (st->msaa_sample_count == want)
	{
		st->msaa_failed_want = 0;
	}

	if (st->msaa_sample_count > 1)
	{
		Com_Printf("...MSAAx%d is used\n", (int)st->msaa_sample_count);
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
		[cd release];	/* G1: manual RC, cd is +1 and not kept */
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
		/* G1: manual RC, ld and opts are +1 and not kept. */
		[ld release];
		[opts release];
		if (st->library == nil)
		{
			Com_Printf("ref_mtl: MSL compilation failed:\n%s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
		st->msl_version = "3.2";
	}

	/* W7: world-pass pipelines at the current MSAA sample count. */
	if (!MTL_InitWorldPipelines(st, 1))
	{
		R_ReleaseShaders(st);
		return false;
	}
	st->pipeline_sample_count = 1;

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

	/* F7: the showtris / alias / alias-translucent / sprite / particle
	   pipelines are built by MTL_InitWorldPipelines above. The pre-W7
	   copies that used to be repeated here would rebuild those six
	   pipelines at rasterSampleCount 1 and overwrite the pointers
	   without releasing, leaking the factored-out objects; removed. */

	/* W8: the two UI sampling states. Nearest (no mip) for nolerp-listed
	   textures (conchars/ch* fonts by default), linear+mip for everything
	   else, matching ref_vk's S_NEAREST vs vk_current_sampler split. */
	{
		MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];

		sd.minFilter = MTLSamplerMinMagFilterNearest;
		sd.magFilter = MTLSamplerMinMagFilterNearest;
		sd.mipFilter = MTLSamplerMipFilterNearest;
		sd.normalizedCoordinates = YES;
		st->ui_sampler_nearest = [st->device newSamplerStateWithDescriptor:sd];
		if (st->ui_sampler_nearest == nil)
		{
			[sd release];	/* G1: manual RC, sd is +1 and not kept */
			Com_Printf("ref_mtl: ui nearest sampler creation failed\n");
			R_ReleaseShaders(st);
			return false;
		}

		sd.minFilter = MTLSamplerMinMagFilterLinear;
		sd.magFilter = MTLSamplerMinMagFilterLinear;
		sd.mipFilter = MTLSamplerMipFilterLinear;
		st->ui_sampler_linear = [st->device newSamplerStateWithDescriptor:sd];
		[sd release];	/* G1: both samplers built, descriptor released */
		if (st->ui_sampler_linear == nil)
		{
			Com_Printf("ref_mtl: ui linear sampler creation failed\n");
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* M2: the world-path sampling states (filtered world/lmap pair with
	   r_anisotropic, nearest variant for the r_nolerp_list). */
	if (!MTL_BuildWorldSamplers(st))
	{
		Com_Printf("ref_mtl: world sampler creation failed\n");
		R_ReleaseShaders(st);
		return false;
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
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"ui_tex_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"ui_tex_fragment"];

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

		st->pipeline_ui_tex = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_ui_tex == nil)
		{
			Com_Printf("ref_mtl: ui tex pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}


	}

	{
		/* tint path: same vertex function and quad, the fragment multiplies
		   by the UBO color after gamma. */
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"ui_tex_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"ui_tint_fragment"];

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

		st->pipeline_ui_tint = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		if (st->pipeline_ui_tint == nil)
		{
			Com_Printf("ref_mtl: ui tint pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}


	}

	{
		/* color path: the UBO color is output by the vertex stage and
		   returned raw by the fragment, standard alpha blend. No fragment
		   argument table (no resource bindings). */
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"ui_color_vertex"];

		pd.fragmentFunction = [st->library newFunctionWithName:@"ui_color_fragment"];

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(uicolorvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pd.colorAttachments[0].blendingEnabled = YES;
		pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

		st->pipeline_ui_color = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_ui_color == nil)
		{
			Com_Printf("ref_mtl: ui color pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
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
		st->beam_vertex_buffer[i] = [st->device newBufferWithLength:BEAM_VERTEX_RING_BYTES options:MTLResourceStorageModeShared];
		st->showtris_vertex_buffer[i] = [st->device newBufferWithLength:SHOWTRIS_VERTEX_RING_BYTES options:MTLResourceStorageModeShared];
		st->alias_vertex_buffer[i] = [st->device newBufferWithLength:ALIAS_VERTEX_RING_BYTES options:MTLResourceStorageModeShared];

		if (st->world_vertex_buffer[i] == nil ||
		    st->world_lmap_vertex_buffer[i] == nil ||
		    st->world_ubo[i] == nil ||
		    st->dlight_vertex_buffer[i] == nil ||
		    st->beam_vertex_buffer[i] == nil ||
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
			[dsd release];	/* G1: manual RC, dsd is +1 and not kept */
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
			[dsd release];	/* G1: manual RC, dsd is +1 and not kept */
			Com_Printf("ref_mtl: failed to create no-write depth stencil state\n");
			R_ReleaseShaders(st);
			return false;
		}

		/* The flash is drawn last in the world pass, full-screen, and must
		   never test or write depth. */
		dsd.depthCompareFunction = MTLCompareFunctionAlways;
		st->depth_state_none = [st->device newDepthStencilStateWithDescriptor:dsd];
		[dsd release];	/* G1: manual RC, all three states built */
		if (st->depth_state_none == nil)
		{
			Com_Printf("ref_mtl: failed to create no-compare depth stencil state\n");
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W6: present pass pipeline (classic descriptor). Samples the
	   offscreen scene texture and draws it to the drawable as a single
	   full-screen quad over the static ui_color corners. No blending:
	   the quad covers the whole drawable. */
	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"present_vertex"];
		pd.fragmentFunction = [st->library newFunctionWithName:@"present_fragment"];

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(uicolorvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		st->pipeline_present = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_present == nil)
		{
			Com_Printf("ref_mtl: present pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
	}

	/* W6b: underwater world-warp pipeline (ref_vk world_warp parity).
	   Same full-screen ui_colorvert corners as the present pass; samples
	   the world color texture and writes the warped copy to warp_texture
	   between the world and UI passes. Plus its 64-byte fragment UBO. */
	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"warp_vertex"];
		pd.fragmentFunction = [st->library newFunctionWithName:@"warp_fragment"];

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(uicolorvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		st->pipeline_warp = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_warp == nil)
		{
			Com_Printf("ref_mtl: warp pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
		/* G3: warp parameters now travel as inline setFragmentBytes
		   data; the single shared warp_ubo it used to bind raced with
		   in-flight command buffers, so it is gone. */
	}

	/* W6c: world postprocess pipeline (ref_vk postprocess.frag parity).
	   Reuses the warp pass full-screen corners (warp_vertex); samples the
	   warp stage output and writes post_texture. Plus its 64-byte
	   fragment UBO. */
	{
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];

		pd.vertexFunction = [st->library newFunctionWithName:@"warp_vertex"];
		pd.fragmentFunction = [st->library newFunctionWithName:@"postprocess_fragment"];

		MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
		vd.attributes[0].format = MTLVertexFormatFloat2;
		vd.attributes[0].offset = 0;
		vd.attributes[0].bufferIndex = 0;
		vd.layouts[0].stride = sizeof(uicolorvert_t);
		pd.vertexDescriptor = vd;

		pd.rasterSampleCount = 1;
		pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		st->pipeline_postprocess = [st->device newRenderPipelineStateWithDescriptor:pd error:&err];
		[pd.vertexFunction release];
		[pd.fragmentFunction release];
		[pd release];
		[vd release];	/* G1: manual RC, none kept by the pipeline state */
		if (st->pipeline_postprocess == nil)
		{
			Com_Printf("ref_mtl: postprocess pipeline creation failed: %s\n", err.localizedDescription.UTF8String);
			R_ReleaseShaders(st);
			return false;
		}
		/* G3: see the warp pass, the postprocess UBO is inline too */
	}

	Com_DPrintf("ref_mtl: shaders compiled (see 'mtl_strings' for the pipeline list)\n");

	return true;
}

/*
==============
RE_InitContext

Called after the window was created. Creates the SDL Metal view and
CAMetalLayer for this window, and (the first time) the Metal 4 device,
command queue and render pass descriptors.
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

		/* M4: the OS check above only proves the MTL4 *APIs* exist;
		   the GPU itself must belong to the Metal 4 family. Without
		   this test the failure surfaced much later as a cryptic
		   MTL4Compiler pipeline error instead of a clean fallback to
		   the next renderer. */
		if (![device supportsFamily:MTLGPUFamilyMetal4])
		{
			Com_Printf("ref_mtl: default Metal device '%s' does not support "
			           "the Metal 4 GPU family. Not initializing.\n",
			           device.name.UTF8String);
			[device release];	/* Create rule: +1, not stored */
			return false;
		}

		/* Classic (MTL3-era) command queue: drawing through an MTL4
		   queue with an app-created render target corrupts the
		   displayed image on M3 (Bug C, tools/bugc_repro/NOTES.md).
		   The pipelines are still MTL4Compiler-created and encode
		   unchanged on classic command buffers and encoders. */
		id<MTLCommandQueue> command_queue = [device newCommandQueue];

		if (command_queue == nil)
		{
			Com_Printf("ref_mtl: failed to create Metal command queue\n");
			[device release];	/* same Create-rule release as above */
			return false;
		}

		st->device = device;
		st->command_queue = command_queue;

		st->pass_descriptor = [MTLRenderPassDescriptor new];

		/* W5d: the 2D UI pass renders into the offscreen scene target
		   but has no depth attachment; it is opened lazily on the
		   first RE_Draw_* call of a frame. */
		st->ui_pass_descriptor = [MTLRenderPassDescriptor new];

		/* W6: final present pass, scene texture to drawable. */
		st->present_pass_descriptor = [MTLRenderPassDescriptor new];
	}

	/* W3: runtime shader compilation and world rings. Guarded by the
	   plain pipeline so a failed first attempt is retried on mode changes. */
	if (st->pipeline_plain == nil && !R_InitShaders())
	{
		return false;
	}

	/* The SDL Metal view owns the CAMetalLayer we render into. M4: the
	   view is checked before its layer is asked for, and a layer that
	   still comes back NULL destroys the view again - returning with
	   the view alive leaked it (st->metal_view is only assigned after
	   both exist). */
	SDL_MetalView metal_view = SDL_Metal_CreateView(window);

	if (metal_view == NULL)
	{
		Com_Printf("ref_mtl: failed to create SDL Metal view: %s\n", SDL_GetError());
		return false;
	}

	CAMetalLayer *layer = (CAMetalLayer *)SDL_Metal_GetLayer(metal_view);

	if (layer == NULL)
	{
		Com_Printf("ref_mtl: SDL Metal view has no CAMetalLayer: %s\n", SDL_GetError());
		SDL_Metal_DestroyView(metal_view);
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
	/* W6 + Bug C mitigation: the scene is rendered into an offscreen
	   texture and copied to the drawable by a single final present
	   pass, so each drawable is the render target of exactly one pass
	   and is never sampled or read back - the shape framebufferOnly =
	   YES is designed for. Classic command encoding (see the
	   mtlstate_t comment and tools/bugc_repro/NOTES.md) is what makes
	   this display cleanly: MTL4 queues with an app-created render
	   target poison the displayed image with a constant magenta. */
	layer.framebufferOnly = YES;
	layer.maximumDrawableCount = 3;
	/* M1: r_vsync was only reflected in RE_IsVSyncActive's return
	   value; the layer kept its default displaySyncEnabled = YES, so
	   every frame was display-synced regardless of the cvar (and the
	   host double-paced, see RE_IsVSyncActive below). vk applies the
	   cvar through the present mode (vk_swapchain.c:174); the CAMetal
	   equivalent is displaySyncEnabled. maximumDrawableCount stays 3:
	   with sync off the RE_BeginFrame slot gate is what bounds
	   latency. */
	layer.displaySyncEnabled = (r_vsync->value != 0);

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

	st->metal_view = metal_view;
	st->layer = layer;
	st->drawable = nil;
	st->frame_number = 0;
	st->frame_slot = 0;
	/* M4 (verify): resetting the slot_busy flags here is safe because
	   RE_ShutdownContext (L1, round 7B) drains every in-flight frame
	   before the old context dies, so no previous-context frame can
	   still be writing the shared rings at this point. */
	for (int si = 0; si < 3; si++)
	{
		atomic_store(&st->slot_busy[si], false);
	}
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

M1: report what the layer is actually doing (displaySyncEnabled),
not what r_vsync says: before the fix the layer ignored the cvar
and kept its default YES, so the host's own frame pacing
(common/frame.c, skips its wait when this returns true) ran on top
of the display sync and frame times jittered. No context -> not
vsynced (no present happens anyway).
==============
*/
static qboolean
RE_IsVSyncActive(void)
{
	if (mtl_state.layer == NULL)
	{
		return false;
	}

	return ((CAMetalLayer *)mtl_state.layer).displaySyncEnabled ? true : false;
}

/*
==============
R_CountPipelines

W9: number of runtime-compiled render pipelines currently live in the
renderer state (reported by Mtl_Strings_f).
==============
*/
static int
R_CountPipelines(void)
{
	mtlstate_t *st = &mtl_state;
	id<MTLRenderPipelineState> *p[] = {
		&st->pipeline_plain,
		&st->pipeline_lmap,
		&st->pipeline_sky,
		&st->pipeline_dlight,
		&st->pipeline_beam,
		&st->pipeline_flash,
		&st->pipeline_showtris,
		&st->pipeline_alias,
		&st->pipeline_alias_translucent,
		&st->pipeline_sprite,
		&st->pipeline_particle,
		&st->pipeline_point_particle,
		&st->pipeline_ui_tex,
		&st->pipeline_ui_tint,
		&st->pipeline_ui_color,
		&st->pipeline_warp,
		&st->pipeline_postprocess,
		&st->pipeline_present,
	};
	int n = 0;
	size_t i;

	for (i = 0; i < sizeof(p) / sizeof(p[0]); i++)
	{
		if (*p[i] != nil)
		{
			n++;
		}
	}

	return n;
}

/*
==============
Mtl_Strings_f

W9: dump Metal device / shader / swapchain information to the console,
ref_vk's Vk_Strings_f() parity. Printed once at startup and available
as the "mtl_strings" command.
==============
*/
void
Mtl_Strings_f(void)
{
	mtlstate_t *st = &mtl_state;

	if (st->device == nil)
	{
		Com_Printf("ref_mtl: no Metal device (renderer not initialized)\n");
		return;
	}

	@autoreleasepool {
		id<MTLDevice> dev = st->device;
		NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
		NSUInteger i;

		Com_Printf("------------------------------------\n");
		Com_Printf("Metal devices found:\n");
		for (i = 0; i < all.count; i++)
		{
			qboolean used = all[i].registryID == dev.registryID;

			Com_Printf("%s#%d: %s\n",
				all.count > 1 && used ? "*  " : "   ",
				(int)i, all[i].name.UTF8String);
		}
		[all release];

		Com_Printf("Using device:\n");
		Com_Printf("   name: %s\n", dev.name.UTF8String);
		Com_Printf("   registryID: 0x%lX\n", (unsigned long)dev.registryID);
		Com_Printf("   architecture: %s\n", dev.architecture.name.UTF8String);
		Com_Printf("   GPU families: Metal4 %s, Metal3 %s\n",
			[dev supportsFamily:MTLGPUFamilyMetal4] ? "yes" : "no",
			[dev supportsFamily:MTLGPUFamilyMetal3] ? "yes" : "no");
		Com_Printf("   unified memory: %s\n", dev.hasUnifiedMemory ? "yes" : "no");
		Com_Printf("   recommendedMaxWorkingSetSize: %llu MB\n",
			(unsigned long long)(dev.recommendedMaxWorkingSetSize / (1024 * 1024)));
		Com_Printf("   max threads per threadgroup: %llu\n",
			(unsigned long long)dev.maxThreadsPerThreadgroup.width);
		Com_Printf("   supported texture sample counts:");
		for (i = 1; i <= 8; i <<= 1)
		{
			if ([dev supportsTextureSampleCount:i])
			{
				Com_Printf(" %d", (int)i);
			}
		}
		Com_Printf("\n");
		Com_Printf("   allocated on device: %llu MB\n",
			(unsigned long long)(dev.currentAllocatedSize / (1024 * 1024)));

		Com_Printf("Shaders: MTL4Compiler runtime compilation, MSL language version %s\n",
			st->msl_version != NULL ? st->msl_version : "unknown");
		Com_Printf("   shader libraries: %d, render pipelines: %d\n",
			st->library != nil ? 1 : 0, R_CountPipelines());

		Com_Printf("Mode: %dx%d", vid.width, vid.height);
		if (st->msaa_sample_count > 1)
		{
			Com_Printf(" (MSAAx%d)", (int)st->msaa_sample_count);
		}
		Com_Printf("\n");
		Com_Printf("Present: CAMetalLayer, BGRA8, drawables: %d, vsync: %s\n",
			st->layer != NULL ?
			    (int)((CAMetalLayer *)st->layer).maximumDrawableCount : 0,
			RE_IsVSyncActive() ? "on" : "off");
	}
}

/*
==============
Mtl_Mem_f

W9: per-frame ring-buffer usage of the current frame slot plus the
device-wide allocation, ref_vk's Vk_Mem_f() parity. Command "mtl_mem".
==============
*/
static void
Mtl_RingStats(const char *name, size_t used, size_t max, size_t size)
{
	Com_Printf("%-12s : %u/%ukB (%.1f%% max: %ukB)\n", name,
		(unsigned)(used / 1024), (unsigned)(size / 1024),
		size ? 100.0 * (double)used / (double)size : 0.0,
		(unsigned)(max / 1024));
}

void
Mtl_Mem_f(void)
{
	mtlstate_t *st = &mtl_state;
	static const char *names[6] = {
		"World vertex", "World lmap", "Uniform",
		"Dlight", "Showtris", "Alias/sprite"
	};
	static const size_t sizes[6] = {
		WORLD_VERTEX_RING_BYTES, WORLD_LMAP_VERTEX_RING_BYTES,
		WORLD_UBO_RING_BYTES, DLIGHT_VERTEX_RING_BYTES,
		SHOWTRIS_VERTEX_RING_BYTES, ALIAS_VERTEX_RING_BYTES
	};
	size_t total = 0;
	int i;

	Com_Printf("\nDynamic ring buffer stats (last frame, 3 slots rotating):\n");
	for (i = 0; i < 6; i++)
	{
		Mtl_RingStats(names[i], st->ring_usage[i], st->ring_usage_max[i],
			sizes[i]);
		total += sizes[i];
	}

	Com_Printf("Rings resident: %.1f MB (3 slots x 6 rings)\n",
		(double)total * 3 / (1024.0 * 1024.0));

	/* G2: draws dropped by uniform-ring exhaustion, see MTL_UboRingDry */
	Com_Printf("Uniform ring drops: %u\n", st->ubo_exhausted);
	/* N1: chain draws skipped for nil textures/sampler states */
	Com_Printf("Dropped surface draws: %u\n", st->surfaces_dropped);

	if (st->device != nil)
	{
		Com_Printf("Allocated on device: %llu MB\n",
			(unsigned long long)(st->device.currentAllocatedSize / (1024 * 1024)));
	}
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

	if (st->command_queue == nil || st->layer == NULL)
	{
		return; // not initialized
	}

	/* M7B2: a mid-frame ERR_DROP (warp bad numverts, overlong clip
	   chains, bad world model, ...) longjmps out before RE_EndFrame,
	   leaving frame_active set, the frame's command buffer (and
	   possibly its encoders) open and its slot busy forever. The
	   drain at L1 only clears this at shutdown; without the call
	   here, the abandoned slot makes every third frame hit the CPU
	   gate's one-second timeout from then on. Must run before the
	   frame counter advance below so frame_slot still identifies the
	   abandoned frame. */
	MTL_AbandonOpenFrame();

	/* M1: r_vsync changed at runtime (video menu / console). The CAMetal
	   layer property applies live, no mode change needed, so handle the
	   flag here and clear it; R_SetMode also clears it as a belt for
	   the RE_InitContext apply, harmless if already false. */
	if (r_vsync->modified)
	{
		((CAMetalLayer *)st->layer).displaySyncEnabled =
		    (r_vsync->value != 0);
		r_vsync->modified = false;
	}

	/* M2: r_anisotropic changed at runtime (video menu / console). ref_vk
	   rebuilds all samplers on vk_aniso->modified in its R_BeginFrame
	   (vk_main.c:1396); the Metal equivalent is the world/lmap sampling
	   states. mtl_mip_nearfilter is deliberately not handled here: like
	   vk_mip_nearfilter (not in vk's rebuild list) it steers mipmap
	   generation, so existing images keep their mips until the next
	   reload. */
	if (r_anisotropic->modified)
	{
		r_anisotropic->modified = false;
		if (!MTL_BuildWorldSamplers(st))
		{
			Com_Printf("ref_mtl: world sampler rebuild failed, "
			           "keeping the previous sampling\n");
		}
	}

	st->frame_number++;
	st->frame_slot = (int)(st->frame_number % 3);

	/* CPU gate: don't reuse a slot's rings or overwrite an uncommitted
	   command buffer while its frame is still in flight. The completion
	   handler installed in RE_EndFrame clears the flag; wait at most
	   about one second, then skip the frame. */
	{
		int waited = 0;

		while (atomic_load_explicit(&st->slot_busy[st->frame_slot],
		                            memory_order_acquire))
		{
			if (++waited > 1000)
			{
				Com_DPrintf("ref_mtl: CPU gate timed out, skipping frame %llu\n",
				           (unsigned long long)st->frame_number);
				return;
			}
			SDL_Delay(1);
		}
	}

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
	st->beam_vertex_offset[st->frame_slot] = 0;
	st->showtris_vertex_offset[st->frame_slot] = 0;
	st->alias_vertex_offset[st->frame_slot] = 0;

	// W6b: per-frame world-warp pass bookkeeping. ui_target stays nil
	// (consumers fall back to scene_texture) so it can never dangle when
	// the resize block below recreates the textures.
	st->world_rendered = false;
	st->warp_done = false;
	st->ui_target = nil;
	// H1: the pre-world tile save is re-decided every frame.
	st->tiles_saved = false;

	// W4: the depth texture is sized to the drawable and recreated when
	// the window (or its contentsScale) changes.
	if (st->depth_width != (int)drawable.texture.width ||
	    st->depth_height != (int)drawable.texture.height)
	{
		MTLTextureDescriptor *dd, *sd;

		if (st->depth_texture != nil)
		{
			[st->depth_texture release];
			st->depth_texture = nil;
		}
		if (st->scene_texture != nil)
		{
			[st->scene_texture release];
			st->scene_texture = nil;
		}
		/* M3: the tile-save copy is size-checked against scene_width and
		   recreated lazily (RE_GetTileTexture), so releasing the
		   now-wrong-size one here just returns the memory immediately
		   instead of holding it until the next save. */
		if (st->border_save_texture != nil)
		{
			[st->border_save_texture release];
			st->border_save_texture = nil;
		}

		dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
		        MTLPixelFormatDepth32Float
		        width:drawable.texture.width
		        height:drawable.texture.height
		        mipmapped:NO];
		dd.usage = MTLTextureUsageRenderTarget;
		/* F5: depth is never read back by the CPU; Private also lets
		   Apple GPUs use compressed depth formats for the MSAA pass. */
		dd.storageMode = MTLStorageModePrivate;
		st->depth_texture = [st->device newTextureWithDescriptor:dd];

		/* W6: offscreen color target (default/Private storage: the CPU
		   never reads it back, the GPU writes and samples it). */
		sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
		        MTLPixelFormatBGRA8Unorm
		        width:drawable.texture.width
		        height:drawable.texture.height
		        mipmapped:NO];
		sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		/* G6: scene/warp/post are GPU-only (screenshots blit into their
		   own texture); state Private explicitly instead of relying on
		   the macOS default. */
		sd.storageMode = MTLStorageModePrivate;
		st->scene_texture = [st->device newTextureWithDescriptor:sd];

		/* W6b: the world-warp pass target (same format/usage); UI pass and
		   present follow it via ui_target when the pass ran. */
		if (st->warp_texture != nil)
		{
			[st->warp_texture release];
		}
		st->warp_texture = [st->device newTextureWithDescriptor:sd];

		/* W6c: the world postprocess pass target (same format/usage). */
		if (st->post_texture != nil)
		{
			[st->post_texture release];
		}
		st->post_texture = [st->device newTextureWithDescriptor:sd];

		/* M3: only publish the new dimensions when all four targets
		   actually exist. The old code published unconditionally: on
		   an allocation failure (memory pressure on a large drawable)
		   the size test at the top of this block saw matching
		   dimensions from the next frame on and never retried, so
		   scene_texture stayed nil for the rest of the session -
		   MTL_BeginUIPass returns early on a nil scene target and the
		   screen stayed black. Drop the partial set, zero the sizes so
		   the test keeps firing, and skip this frame; the next
		   RE_BeginFrame retries the whole block. Nothing below has run
		   yet (no command buffer, frame_active still false), so
		   RE_EndFrame's frame_active guard makes the skip safe, like
		   the command-buffer failure path below. */
		if (st->depth_texture == nil || st->scene_texture == nil ||
		    st->warp_texture == nil || st->post_texture == nil)
		{
			if (st->depth_texture != nil)
			{
				[st->depth_texture release];
				st->depth_texture = nil;
			}
			if (st->scene_texture != nil)
			{
				[st->scene_texture release];
				st->scene_texture = nil;
			}
			if (st->warp_texture != nil)
			{
				[st->warp_texture release];
				st->warp_texture = nil;
			}
			if (st->post_texture != nil)
			{
				[st->post_texture release];
				st->post_texture = nil;
			}
			st->depth_width = st->depth_height = 0;
			st->scene_width = st->scene_height = 0;
			Com_DPrintf("ref_mtl: resize allocations failed, skipping "
			            "frame %llu\n", (unsigned long long)st->frame_number);
			return;
		}

		/* F1: publish the new dimensions before the MSAA block below;
		   MTL_CreateMSAADrawBuffers sizes its attachments from
		   scene_width/height and depth_width/height and would otherwise
		   build them at the previous frame's size. */
		st->depth_width = (int)drawable.texture.width;
		st->depth_height = (int)drawable.texture.height;
		st->scene_width = (int)drawable.texture.width;
		st->scene_height = (int)drawable.texture.height;

		/* G6: a (re)created scene_texture has undefined content and both
		   the UI pass and the world pass LOAD it; the frame right after
		   a resize would otherwise show garbage wherever nothing opaque
		   covers the screen. Cleared once in R_BeginFrame below. */
		st->scene_needs_clear = true;

		/* W7: the multisampled world attachments follow the same
		   resize; they're only live while MSAA is on. */
		if (st->msaa_sample_count > 1)
		{
			MTL_ReleaseMSAADrawBuffers(st);
			if (!MTL_CreateMSAADrawBuffers(st, st->msaa_sample_count))
			{
				/* F2d: pipelines are still at N samples here, but
				   MTL_UpdateMSAA runs below before this frame's
				   command buffer exists and brings them (or the
				   buffers) to a consistent count. */
				st->msaa_sample_count = 1;
			}
		}
	}

	/* W7: r_msaa_samples changes rebuild the world pipelines and the
	   multisampled attachments. Runs after the resize block above so
	   the scene/depth dimensions are valid, and before this frame's
	   command buffer is created. */
	MTL_UpdateMSAA(st);

	/* One classic command buffer per frame, retained until EndFrame
	   commits and releases it. Mark the slot in flight; the completion
	   handler added in RE_EndFrame clears it. */
	st->command_buffer = [[st->command_queue commandBuffer] retain];
	if (st->command_buffer == nil)
	{
		Com_DPrintf("ref_mtl: failed to create command buffer, skipping frame\n");
		return;
	}
	atomic_store_explicit(&st->slot_busy[st->frame_slot], true,
	                      memory_order_relaxed);
	st->frame_active = true;

	/* G6: clear a freshly (re)allocated scene_texture once, before this
	   frame's UI/world passes LOAD it; see the resize block above. */
	if (st->scene_needs_clear && st->scene_texture != nil)
	{
		MTLRenderPassDescriptor *cd = [MTLRenderPassDescriptor renderPassDescriptor];
		id<MTLRenderCommandEncoder> cenc;

		st->scene_needs_clear = false;
		cd.colorAttachments[0].texture = st->scene_texture;
		cd.colorAttachments[0].loadAction = MTLLoadActionClear;
		cd.colorAttachments[0].storeAction = MTLStoreActionStore;
		cd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		cenc = [st->command_buffer renderCommandEncoderWithDescriptor:cd];
		if (cenc != nil)
		{
			[cenc endEncoding];
		}
	}
}

/*
 * ref_vk parity (vk_pixel_size): the world pass renders into a
 * proportionally smaller viewport of the scene texture and the warp
 * pass scales it back up. Values below 1 clamp to 1, exactly like the
 * `divisor` ternary in vk_main.c.
 */
static float
MTL_PixelDivisor(void)
{
	return mtl_pixel_size->value < 1.0f ? 1.0f : (float)mtl_pixel_size->value;
}

/*
==============
MTL_RunWarpPass

W6b: the between-passes world warp (ref_vk RP_WORLD_WARP parity). While
the view is submerged (RDF_UNDERWATER and mtl_underwater) the world view
rectangle is sine-distorted: sample scene_texture, write the warped copy
into warp_texture; the UI pass attaches and the present pass samples the
latter via st->ui_target.

Skipped when the world pass did not run (NOWORLDMODEL menus / culling
skip). The warp stage additionally skips when there is no warp work at
all (not submerged and mtl_pixel_size <= 1): the full pass would be a
pixel-identical copy, skipping it is a visual no-op. The postprocess
stage instead runs whenever the world produced content, like ref_vk.
==============
*/
static void
MTL_RunWarpPass(void)
{
	mtlstate_t *st = &mtl_state;
	float underwaterTime;
	float divisor;
	/* H1: the refdef rectangle the warp pass used (device pixels,
	   half-open), and whether the border around it has to be restored
	   from the pre-world tile save. */
	int brect[4];
	qboolean border_fix = false;

	if (st->warp_done)
	{
		return;
	}
	st->warp_done = true;

	// default: UI and present keep using the (unwarped) scene texture
	st->ui_target = st->scene_texture;

	if (!st->world_rendered)
	{
		return;
	}

	underwaterTime = (mtl_underwater->value > 0 &&
		(r_newrefdef.rdflags & RDF_UNDERWATER)) ? r_newrefdef.time : 0.f;

	divisor = MTL_PixelDivisor();

	/* Warp stage: only when there is distortion or upscale-restore work
	   (ref_vk runs it unconditionally; a skipped mtl stage is a no-op
	   only when the copy would be pixel-identical). */
	if ((underwaterTime > 0.f || divisor > 1.f) &&
	    st->frame_active && st->command_buffer != nil &&
	    st->scene_texture != nil && st->warp_texture != nil &&
	    st->pipeline_warp != nil &&
	    st->ui_color_vertex_buffer != nil)
	{
		/* G3: the pass parameters are copied into this command buffer
		   at encode time (setFragmentBytes), like ref_vk's push
		   constants. A single shared warp_ubo rewritten in place every
		   frame raced with the 1-2 older command buffers still in
		   flight (wrong underwater phase, one-frame viewsize /
		   pixel_size glitches). */
		mtl_warp_ubo_t ubo;
		/* refdef coordinates are in logical (vid.width/height) space; the
		   pass works in device pixels. */
		const float scaleX = (float)st->scene_width / (float)vid.width;
		const float scaleY = (float)st->scene_height / (float)vid.height;
		MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
		id<MTLRenderCommandEncoder> enc;

		ubo.time = underwaterTime;
		ubo.scale = viewsize->value / 100.0f;
		ubo.scrWidth = (float)st->scene_width;
		ubo.scrHeight = (float)st->scene_height;
		ubo.pixelSize = divisor;
		ubo.refdefX = (float)r_newrefdef.x * scaleX;
		ubo.refdefY = (float)r_newrefdef.y * scaleY;
		ubo.refdefW = (float)r_newrefdef.width * scaleX;
		ubo.refdefH = (float)r_newrefdef.height * scaleY;

		pd.colorAttachments[0].texture = st->warp_texture;
		pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		pd.colorAttachments[0].storeAction = MTLStoreActionStore;

		enc = [st->command_buffer renderCommandEncoderWithDescriptor:pd];
		if (enc == nil)
		{
			Com_DPrintf("ref_mtl: failed to open world-warp encoder\n");
			return;
		}

		[enc setViewport:(MTLViewport){0.0, 0.0,
		    (double)st->scene_width, (double)st->scene_height, 0.0, 1.0}];
		[enc setRenderPipelineState:st->pipeline_warp];
		[enc setVertexBuffer:st->ui_color_vertex_buffer offset:0 atIndex:0];
		[enc setFragmentBytes:&ubo length:sizeof(ubo) atIndex:0];
		[enc setFragmentTexture:st->scene_texture atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle
			vertexStart:0 vertexCount:6];
		[enc endEncoding];

		st->ui_target = st->warp_texture;

		/* H1: remember the refdef rect in the half-open form the warp
		   shader applies (fragCoord are pixel centers: pixel i is
		   inside refdef when i + 0.5 >= refdefX and < refdefX +
		   refdefW). Everything outside it in the warp output is the
		   1:1 scene passthrough, which at divisor > 1 contains the
		   raw down-scaled world texels of the scene bands
		   [vrect/p, vrect); restore those from the pre-world tile
		   save below. */
		brect[0] = (int)ceilf(ubo.refdefX - 0.5f);
		brect[1] = (int)ceilf(ubo.refdefY - 0.5f);
		brect[2] = (int)ceilf(ubo.refdefX + ubo.refdefW - 0.5f);
		brect[3] = (int)ceilf(ubo.refdefY + ubo.refdefH - 0.5f);
		border_fix = st->tiles_saved && divisor > 1.0f;
	}

	/* Postprocess stage (ref_vk postprocess.frag parity): samples the
	   warp stage's output (or the plain scene when the warp stage was
	   skipped) and writes post_texture with pow(rgb * 1.5,
	   2.1 - vid_gamma). This is the world gamma source for parity: the
	   lightmapped world fragment (world_lmap_fragment, like vk's
	   polygon_lmap.frag) applies no pow() itself, and ref_vk restores it
	   here, over the whole world image. The shaders that do pow
	   themselves (plain world, models, sprites, particles, UI) get the
	   same second pow on the world image in both renderers. */
	if (st->frame_active && st->command_buffer != nil &&
	    st->pipeline_postprocess != nil &&
	    st->post_texture != nil && st->ui_color_vertex_buffer != nil)
	{
		/* G3: see the warp pass above, same fix: the single shared
		   post_ubo let in-flight frames read the current frame's
		   gamma/postprocess values. */
		mtl_post_ubo_t ubo;
		MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
		id<MTLRenderCommandEncoder> enc;

		ubo.postprocess = mtl_postprocess->value > 0 ? 1.0f : 0.0f;
		ubo.gamma = 2.1f - vid_gamma->value;

		pd.colorAttachments[0].texture = st->post_texture;
		pd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		pd.colorAttachments[0].storeAction = MTLStoreActionStore;

		enc = [st->command_buffer renderCommandEncoderWithDescriptor:pd];
		if (enc == nil)
		{
			// H1: don't bail, the border restore below still applies
			// (ui_target is still the warp stage's output).
			Com_DPrintf("ref_mtl: failed to open postprocess encoder\n");
		}
		else
		{
			[enc setViewport:(MTLViewport){0.0, 0.0,
			    (double)st->scene_width, (double)st->scene_height, 0.0, 1.0}];
			[enc setRenderPipelineState:st->pipeline_postprocess];
			[enc setVertexBuffer:st->ui_color_vertex_buffer offset:0 atIndex:0];
			[enc setFragmentBytes:&ubo length:sizeof(ubo) atIndex:0];
			[enc setFragmentTexture:st->ui_target atIndex:0];
			[enc drawPrimitives:MTLPrimitiveTypeTriangle
				vertexStart:0 vertexCount:6];
			[enc endEncoding];

			st->ui_target = st->post_texture;
		}
	}

	/* H1: ref_vk draws its 2D border after the warp pass, which hides
	   the stretched remnant there; mtl encodes SCR_TileClear before the
	   world, so put the saved pre-world tiles back over everything
	   outside the warp's refdef rect in the final offscreen target
	   (post_texture when the postprocess stage ran, else warp_texture).
	   After the postprocess stage is deliberate: the 2D tiles must not
	   get the world gamma/intensity pow, matching ref_vk where the UI
	   is drawn after postprocessing. This also covers the scene bands
	   [vrect/p, vrect) that the MSAA resolve restore above does not
	   reach, so it is correct for the MSAA and non-MSAA paths alike. */
	if (border_fix && st->tiles_saved &&
	    st->border_save_texture != nil && st->ui_target != nil)
	{
		const NSUInteger w = (NSUInteger)st->scene_width;
		const NSUInteger h = (NSUInteger)st->scene_height;
		const NSUInteger x0 = (NSUInteger)MAX(0, MIN(brect[0], (int)w));
		const NSUInteger y0 = (NSUInteger)MAX(0, MIN(brect[1], (int)h));
		const NSUInteger x1 = (NSUInteger)MAX(0, MIN(brect[2], (int)w));
		const NSUInteger y1 = (NSUInteger)MAX(0, MIN(brect[3], (int)h));
		id<MTLBlitCommandEncoder> restore =
			[st->command_buffer blitCommandEncoder];

		/* top, bottom, left, right around the refdef rect (half-open,
		   empty pieces skipped) */
		if (y0 > 0)
		{
			[restore copyFromTexture:st->border_save_texture
				sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
				sourceSize:MTLSizeMake(w, y0, 1)
				toTexture:st->ui_target
				destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
		}
		if (y1 < h)
		{
			[restore copyFromTexture:st->border_save_texture
				sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, y1, 0)
				sourceSize:MTLSizeMake(w, h - y1, 1)
				toTexture:st->ui_target
				destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, y1, 0)];
		}
		if (x0 > 0)
		{
			[restore copyFromTexture:st->border_save_texture
				sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, y0, 0)
				sourceSize:MTLSizeMake(x0, y1 - y0, 1)
				toTexture:st->ui_target
				destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, y0, 0)];
		}
		if (x1 < w)
		{
			[restore copyFromTexture:st->border_save_texture
				sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x1, y0, 0)
				sourceSize:MTLSizeMake(w - x1, y1 - y0, 1)
				toTexture:st->ui_target
				destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x1, y0, 0)];
		}
		[restore endEncoding];
	}
}

/*
==============
RE_EndWorldRenderpass
==============
*/
static qboolean
RE_EndWorldRenderpass(void)
{
	/* W6b: the host calls this between world and 2D UI rendering, the
	   same spot where ref_vk runs its RP_WORLD_WARP pass. */
	MTL_RunWarpPass();
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

	/* W6: present pass. Draw the offscreen scene texture to the
	   drawable as one full-screen quad. The drawable is the render
	   target of exactly this pass; it is never sampled or loaded, the
	   shape framebufferOnly = YES is designed for. */
	if (st->drawable != nil && st->scene_texture != nil &&
	    st->pipeline_present != nil && st->ui_color_vertex_buffer != nil)
	{
		id<MTLRenderCommandEncoder> present_encoder;

		st->present_pass_descriptor.colorAttachments[0].texture =
			st->drawable.texture;
		st->present_pass_descriptor.colorAttachments[0].loadAction =
			MTLLoadActionDontCare;
		st->present_pass_descriptor.colorAttachments[0].storeAction =
			MTLStoreActionStore;

		present_encoder = [st->command_buffer renderCommandEncoderWithDescriptor:st->present_pass_descriptor];
		if (present_encoder != nil)
		{
			[present_encoder setViewport:(MTLViewport){0.0, 0.0,
			    (double)st->drawable.texture.width,
			    (double)st->drawable.texture.height, 0.0, 1.0}];
			[present_encoder setVertexBuffer:st->ui_color_vertex_buffer
				offset:0 atIndex:0];
			[present_encoder setFragmentTexture:st->ui_target != nil ?
			    st->ui_target : st->scene_texture atIndex:0];
			[present_encoder setRenderPipelineState:st->pipeline_present];
			[present_encoder drawPrimitives:MTLPrimitiveTypeTriangle
				vertexStart:0 vertexCount:6];
			[present_encoder endEncoding];
		}
	}

	/* Release this slot when the GPU is done with the frame's command
	   buffer; the CPU gate in RE_BeginFrame polls the flag before
	   reusing the slot three frames later. W9: report GPU-side command
	   buffer errors through Com_Printf so they reach the console and
	   the terminal log, like ref_vk's error paths. */
	{
		int slot = st->frame_slot;
		unsigned long long frame = (unsigned long long)st->frame_number;

		[st->command_buffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			@autoreleasepool {
				NSError *err = [cb error];

				if (err != nil)
				{
					Com_Printf("ref_mtl: GPU error in frame %llu command buffer: %s\n",
						frame, err.localizedDescription.UTF8String);
				}
				atomic_store_explicit(&mtl_state.slot_busy[slot], false,
				                      memory_order_release);
			}
		}];
	}

	/* Classic present-then-commit: the drawable goes to the compositor
	   when this command buffer's work for it completes. */
	if (st->drawable != nil)
	{
		[st->drawable present];
		st->drawable = nil;
	}

	/* W9: snapshot this frame's ring consumption before the next
	   RE_BeginFrame resets the slot offsets, so "mtl_mem" can report
	   real per-frame usage (ref_vk's vk_config.*_buffer_usage). */
	{
		size_t used[6] = {
			st->world_vertex_offset[st->frame_slot],
			st->world_lmap_vertex_offset[st->frame_slot],
			st->world_ubo_offset[st->frame_slot],
			st->dlight_vertex_offset[st->frame_slot],
			st->showtris_vertex_offset[st->frame_slot],
			st->alias_vertex_offset[st->frame_slot]
		};
		int i;

		for (i = 0; i < 6; i++)
		{
			st->ring_usage[i] = used[i];
			if (used[i] > st->ring_usage_max[i])
			{
				st->ring_usage_max[i] = used[i];
			}
		}
	}

	[st->command_buffer commit];
	[st->command_buffer release];
	st->command_buffer = nil;
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
	size_t slot, ubo_off;
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
		(void)MTL_UboRingDry();	/* ring exhausted, skip the flash */
		return;
	}

	ubo_off = st->world_ubo_offset[slot];
	ubo = (float *)((byte *)st->world_ubo[slot].contents + ubo_off);
	ubo[0] = v_blend[0];
	ubo[1] = v_blend[1];
	ubo[2] = v_blend[2];
	ubo[3] = v_blend[3];
	st->world_ubo_offset[slot] += sizeof(float) * 4;

	[st->encoder setDepthStencilState:st->depth_state_none];
	[st->encoder setRenderPipelineState:st->pipeline_flash];
	[st->encoder setVertexBuffer:st->flash_vertex_buffer offset:0 atIndex:0];
	[st->encoder setVertexBuffer:st->world_ubo[slot] offset:ubo_off atIndex:1];
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
 * returns its ring offset (SIZE_MAX when the ring is exhausted).
 */
static size_t
MTL_EmitParticlePointUbo(size_t slot)
{
	mtlstate_t *st = &mtl_state;
	particle_point_ubo_t *ubo;
	size_t ubo_off;

	if (st->world_ubo_offset[slot] + MTL_UBO_ALIGN(sizeof(particle_point_ubo_t)) > WORLD_UBO_RING_BYTES)
		return MTL_UboRingDry();

	ubo_off = st->world_ubo_offset[slot];
	ubo = (particle_point_ubo_t *)((byte *)st->world_ubo[slot].contents + ubo_off);
	memcpy(ubo->viewproj, r_viewproj_matrix, sizeof(r_viewproj_matrix));
	/* ref_vk parity (vk_main.c): particle point size scales down with
	   mtl_pixel_size so the warp-pass upscale puts it back at the size
	   the cvar asks for on screen. */
	ubo->pointSize = mtl_particle_size->value / MTL_PixelDivisor();
	ubo->pointScale = vid.width * viewsize->value / 102400;
	ubo->minPointSize = mtl_particle_min_size->value;
	ubo->maxPointSize = mtl_particle_max_size->value;
	ubo->att_a = mtl_particle_att_a->value;
	ubo->att_b = mtl_particle_att_b->value;
	ubo->att_c = mtl_particle_att_c->value;
	/* F4: advance keeps the next ring offset 16-byte aligned */
	st->world_ubo_offset[slot] += MTL_UBO_ALIGN(sizeof(particle_point_ubo_t));

	return ubo_off;
}

static void
R_DrawParticles(void)
{
	mtlstate_t *st = &mtl_state;
	size_t slot, vstart, ubo_off;

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

		ubo_off = MTL_EmitParticlePointUbo(slot);
		if (ubo_off == SIZE_MAX)
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

		[st->encoder setRenderPipelineState:st->pipeline_point_particle];
		[st->encoder setDepthStencilState:st->depth_state];
		[st->encoder setVertexBuffer:st->alias_vertex_buffer[slot] offset:vstart atIndex:0];
		[st->encoder setVertexBuffer:st->world_ubo[slot] offset:ubo_off atIndex:1];
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

		ubo_off = MTL_EmitSpriteUbo(slot);
		if (ubo_off == SIZE_MAX)
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

		[st->encoder setRenderPipelineState:st->pipeline_particle];
		[st->encoder setDepthStencilState:st->depth_state];
		[st->encoder setVertexBuffer:st->alias_vertex_buffer[slot] offset:vstart atIndex:0];
		[st->encoder setVertexBuffer:st->world_ubo[slot] offset:ubo_off atIndex:1];
		[st->encoder setFragmentTexture:skin->mtl_texture atIndex:0];
		/* M2: particle dot sampling, [[sampler(0)]] of
		   particle_fragment (see the alias skin bind for nolerp). */
		[st->encoder setFragmentSamplerState:(skin->nolerp
		                                      ? st->world_sampler_nearest
		                                      : st->world_sampler) atIndex:0];
		[st->encoder setFragmentBuffer:st->world_ubo[slot] offset:ubo_off atIndex:0];
		[st->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:r_newrefdef.num_particles * 3];
	}
}

/*
==============
RE_ScreenShot_f

`screenshot [tga|bmp|png|jpg] [quality]` - the ref_vk Vk_ScreenShot_f
equivalent. Metal render targets keep the topmost line at row 0 and the
host's stbi writers want top-down RGBA, so the BGRA8Unorm scene texture
(full drawable resolution) is byte-swapped to RGBA in place before it is
handed to ri.Vid_WriteScreenshot.
==============
*/
static void
RE_ScreenShot_f(void)
{
	mtlstate_t *st = &mtl_state;

	if (st->command_queue == nil || st->device == nil ||
	    st->scene_texture == nil || st->scene_width <= 0 ||
	    st->scene_height <= 0)
	{
		Com_Printf("%s: no scene rendered yet\n", __func__);
		return;
	}

	@autoreleasepool {
		const NSUInteger w = (NSUInteger)st->scene_width;
		const NSUInteger h = (NSUInteger)st->scene_height;
		const NSUInteger bytesPerRow = w * 4;
		id<MTLCommandBuffer> cb = [st->command_queue commandBuffer];
		id<MTLBuffer> staging = [st->device newBufferWithLength:
		    bytesPerRow * h options:MTLResourceStorageModeShared];

		if (cb == nil || staging == nil)
		{
			/* G1: manual RC, staging is +1; the autoreleasepool would
			   not reclaim it. */
			[staging release];
			Com_Printf("%s: failed to allocate readback staging buffer\n",
			    __func__);
			return;
		}

		/* Enqueued after the current frame's command buffer on the same
		   queue, so the blit runs once that frame has fully retired and
		   the scene texture holds the last presented image. */
		/* W6b: after a world-warp frame the composited image (warped
		   world + UI) lives in warp_texture; the blit follows ui_target. */
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		[blit copyFromTexture:st->ui_target != nil ?
		    st->ui_target : st->scene_texture
			sourceSlice:0
			sourceLevel:0
			sourceOrigin:MTLOriginMake(0, 0, 0)
			sourceSize:MTLSizeMake(w, h, 1)
			toBuffer:staging
			destinationOffset:0
			destinationBytesPerRow:bytesPerRow
			destinationBytesPerImage:bytesPerRow * h];
		[blit endEncoding];
		[cb commit];
		[cb waitUntilCompleted];

		if ([cb error] != nil)
		{
			[staging release];	/* G1: manual RC, see above */
			Com_Printf("%s: GPU readback failed: %s\n", __func__,
			    [[cb error] localizedDescription].UTF8String);
			return;
		}

		/* BGRA -> RGBA with opaque alpha (same conversion as the B-format
		   branch of Vk_ScreenShot_f). */
		byte *px = (byte *)[staging contents];
		for (NSUInteger i = 0; i < w * h * 4; i += 4)
		{
			byte tmp = px[i];
			px[i] = px[i + 2];
			px[i + 2] = tmp;
			px[i + 3] = 255;
		}

		ri.Vid_WriteScreenshot((int)w, (int)h, 4, px);

		/* G1: manual RC, staging is newBufferWithLength +1 and the
		   autoreleasepool would not reclaim it; px aliases its contents. */
		[staging release];
	}
}

/*
==============
MTL_SetPassDefaults

K2: the world pass's raster-state baseline, Clockwise front winding
with culling disabled - Metal's documented fresh-encoder defaults.
Metal pipelines carry no raster state (unlike ref_vk, which bakes
frontFace/cullMode into every pipeline, qvk.h's defaults macro being
CLOCKWISE + CULL_MODE_BACK with the lefthand/dlight pipelines on FRONT
and null/warp/showtris on NONE), so the encoder state *is* the pass
state for the groups that never touch it - world surfaces, sprites,
particles, poly chains, UI - and they must see culling disabled.
Anything that overrides winding or culling (the alias-model draws,
the beam tube, the dlight cubes, the left-hand weapon) restores this
baseline when it is done; see the groups' own comments for why their
override pair is what it is.
==============
*/
void
MTL_SetPassDefaults(id<MTLRenderCommandEncoder> encoder)
{
	[encoder setFrontFacingWinding:MTLWindingClockwise];
	[encoder setCullMode:MTLCullModeNone];
}

/*
==============
R_SetLightLevel

O2: ported from ref_vk (vk_main.c:1064). Samples the light grid at the
view origin and publishes r_lightlevel, which the client ships to the
server in every usercmd (cl_input.c, cmd->lightlevel). mtl only had the
weapon-model writer in R_DrawAliasModel (mtl_alias.m), which runs only
when the gun is actually drawn: with hand 2, no weapon, spectator or
chase cameras, or any frame without the weapon the value went stale.
vk keeps both writers; do the same.
==============
*/
static void
R_SetLightLevel(void)
{
	vec3_t	shadelight = {0};

	if (r_newrefdef.rdflags & RDF_NOWORLDMODEL)
	{
		return;
	}

	/* save off light value for server to look at */
	R_LightPoint(r_worldmodel->grid, r_newrefdef.vieworg, shadelight, NULL);

	/* pick the greatest component, which should be the
	 * same as the mono value returned by software */
	if (shadelight[0] > shadelight[1])
	{
		if (shadelight[0] > shadelight[2])
		{
			r_lightlevel->value = 150 * shadelight[0];
		}
		else
		{
			r_lightlevel->value = 150 * shadelight[2];
		}
	}
	else
	{
		if (shadelight[1] > shadelight[2])
		{
			r_lightlevel->value = 150 * shadelight[1];
		}
		else
		{
			r_lightlevel->value = 150 * shadelight[2];
		}
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

	if (!st->frame_active || st->command_buffer == nil ||
	    st->scene_texture == nil || st->pipeline_plain == nil)
	{
		return;
	}

	r_newrefdef = *fd;

	/* O3: ref_vk special-cases RDF_NOWORLDMODEL frames (the player-setup
	   menu renders its 3-D model through this entry point with no world):
	   R_SetupFrame first fills the refdef rectangle with a 0.3 grey
	   backdrop quad through the UI colour pass (vk_main.c:684), the model
	   viewport is never divided by vk_pixel_size, and R_SetVulkan2D skips
	   both the warp and the postprocess blit for such frames
	   (vk_main.c:1042, 1052) - the model and the menu UI reach the screen
	   raw, without the 1.5x-intensity world gamma pow. mtl treated them as
	   ordinary world frames: the pass cleared the whole scene texture to
	   black (no backdrop, and in a menu-only frame even the previous UI
	   content), the model rendered divisor-scaled expecting the warp to
	   upscale it back, and world_rendered = true made the following UI
	   draw run the warp/postprocess chain over everything drawn before it.
	   All three fixes are gated on the flag below. */
	qboolean noworld = ((r_newrefdef.rdflags & RDF_NOWORLDMODEL) != 0);
	if (noworld)
	{
		/* O3 (1): the grey backdrop, through the UI colour path - the
		   same quad RE_Draw_Fill draws, at the refdef rectangle with
		   colour .3,.3,.3,1 (vk clearArea array, vk_main.c:684). The UI
		   pass targets the very texture this frame's world pass then
		   loads, so the backdrop survives (non-MSAA) or is re-made the
		   pass clear colour (MSAA, see below); either way the model
		   lands on top of it. */
		if (st->ui_encoder == nil)
		{
			MTL_BeginUIPass();
		}

		if (st->ui_encoder != nil)
		{
			ui_ubo_t ubo;

			memset(&ubo, 0, sizeof(ubo));
			ubo.offset[0] = (float)r_newrefdef.x / vid.width;
			ubo.offset[1] = (float)r_newrefdef.y / vid.height;
			ubo.scale[0] = (float)r_newrefdef.width / vid.width;
			ubo.scale[1] = (float)r_newrefdef.height / vid.height;
			ubo.uv_scale[0] = 1.f;
			ubo.uv_scale[1] = 1.f;
			ubo.color[0] = 0.3f;
			ubo.color[1] = 0.3f;
			ubo.color[2] = 0.3f;
			ubo.color[3] = 1.f;
			ubo.gamma = 2.1f - vid_gamma->value;
			MTL_DrawUiColor(&ubo);
		}
	}

	/* W5d: if the 2D UI opened a pass before the world (SCR_TileClear runs
	   before V_RenderView when viewsize < 100), end it first so the two
	   passes do not overlap, and LOAD the color attachment so the tiles the
	   UI just drew survive outside the world region (the world pass is now
	   scissored to the vrect, matching ref_vk). Depth still clears. */
	qboolean ui_before_world = (st->ui_encoder != nil);
	if (ui_before_world)
	{
		MTL_EndUIPass();
	}

	/* W6: the world pass renders into the offscreen scene texture,
	   never into the drawable itself. W7: with MSAA (r_msaa_samples)
	   it renders into the multisampled attachments instead and the
	   pass resolves into scene_texture, ref_vk's vk_msaaColorbuffer +
	   multisampled vk_depthbuffer with pResolveAttachments into
	   vk_colorbuffer (vk_common.c). The resolve store action replaces
	   the whole resolve texture regardless of the scissor rect, so
	   the pre-world UI content (SCR_TileClear at viewsize < 100) is
	   saved and restored around the pass; ref_vk's resolve only
	   touches the render area and keeps vk_colorbuffer's tiles. */
	qboolean msaa = (st->msaa_sample_count > 1 &&
	                  st->msaa_color_texture != nil &&
	                  st->msaa_depth_texture != nil);

	/* W7: the resolve overwrites the whole scene texture, so keep the
	   pre-world tiles (drawn outside the world view at viewsize <
	   100) in a copy that is restored after the pass.
	   H1: the non-MSAA case needs the same copy when mtl_pixel_size > 1,
	   because the warp pass's 1:1 passthrough outside the refdef rect
	   would otherwise composite the raw down-scaled world texels of the
	   bands [vrect/p, vrect) into the 2D border; ref_vk hides them by
	   drawing its border after the warp. */
	qboolean save_tiles = ui_before_world &&
	                      (msaa || MTL_PixelDivisor() > 1.0f);
	if (save_tiles)
	{
		if (st->border_save_texture == nil ||
		    (int)st->border_save_texture.width != st->scene_width ||
		    (int)st->border_save_texture.height != st->scene_height)
		{
			MTLTextureDescriptor *sd = [MTLTextureDescriptor
			    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
			    width:(NSUInteger)st->scene_width
			    height:(NSUInteger)st->scene_height
			    mipmapped:NO];
			sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
			sd.storageMode = MTLStorageModePrivate;	/* G6, see scene_texture */

			[st->border_save_texture release];
			st->border_save_texture = [st->device newTextureWithDescriptor:sd];
		}

		if (st->border_save_texture == nil)
		{
			msaa = false;
			save_tiles = false;
		}
	}

	if (msaa)
	{
		st->pass_descriptor.colorAttachments[0].texture = st->msaa_color_texture;
		/* G6: with no pre-world UI content to keep, clear the multisample
		   attachment instead of DontCare: the resolve replaces the whole
		   scene texture, and the undefined texels outside the scissored
		   world rect would otherwise resolve into the view borders. With
		   pre-world tiles the save/restore blits below cover every texel
		   outside the world rect, so DontCare stays fine there.
		   O3: a NOWORLDMODEL frame is the exception - the grey backdrop
		   was drawn into the (single-sample) scene texture, and the
		   resolve would overwrite exactly the rectangle it covers. So
		   clear the multisample attachment to the same grey: inside the
		   world rect it resolves into the backdrop, outside the rect the
		   save/restore blits put the pre-world tiles back. */
		st->pass_descriptor.colorAttachments[0].loadAction =
			(ui_before_world && !noworld) ? MTLLoadActionDontCare : MTLLoadActionClear;
		st->pass_descriptor.colorAttachments[0].storeAction =
			MTLStoreActionMultisampleResolve;
		st->pass_descriptor.colorAttachments[0].clearColor = noworld ?
			MTLClearColorMake(0.3, 0.3, 0.3, 1.0) :
			MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		st->pass_descriptor.colorAttachments[0].resolveTexture = st->scene_texture;
		st->pass_descriptor.colorAttachments[0].resolveLevel = 0;
		st->pass_descriptor.colorAttachments[0].resolveSlice = 0;

		st->pass_descriptor.depthAttachment.texture = st->msaa_depth_texture;
	}
	else
	{
		/* O3: a NOWORLDMODEL frame composites straight into the live UI
		   target - the scene texture in a menu-only frame, or the
		   postprocess output when a real world pass already ran this
		   frame (exactly ref_vk, which draws the setup model in the UI
		   render pass, "draws directly to swapchain", vk_main.c:1052).
		   The backdrop quad went into that same target, so the load is
		   always Load: the model lands on top of it. */
		st->pass_descriptor.colorAttachments[0].texture =
			(noworld && st->ui_target != nil) ? st->ui_target : st->scene_texture;
		st->pass_descriptor.colorAttachments[0].loadAction =
			(noworld || ui_before_world) ? MTLLoadActionLoad : MTLLoadActionClear;
		st->pass_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
		st->pass_descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		st->pass_descriptor.colorAttachments[0].resolveTexture = nil;

		st->pass_descriptor.depthAttachment.texture = st->depth_texture;
	}
	st->pass_descriptor.depthAttachment.level = 0;
	st->pass_descriptor.depthAttachment.loadAction = MTLLoadActionClear;
	st->pass_descriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
	st->pass_descriptor.depthAttachment.clearDepth = 1.0;

	if (save_tiles)
	{
		id<MTLBlitCommandEncoder> save =
			[st->command_buffer blitCommandEncoder];
		[save copyFromTexture:st->scene_texture
			sourceSlice:0
			sourceLevel:0
			sourceOrigin:MTLOriginMake(0, 0, 0)
			sourceSize:MTLSizeMake((NSUInteger)st->scene_width,
			    (NSUInteger)st->scene_height, 1)
			toTexture:st->border_save_texture
			destinationSlice:0
			destinationLevel:0
			destinationOrigin:MTLOriginMake(0, 0, 0)];
		[save endEncoding];

		// H1: MTL_RunWarpPass restores the border from this copy.
		st->tiles_saved = true;
	}

	st->encoder = [st->command_buffer renderCommandEncoderWithDescriptor:st->pass_descriptor];
	if (st->encoder == nil)
	{
		Com_DPrintf("ref_mtl: failed to create render command encoder\n");
		return;
	}

	/* K2: state the raster baseline explicitly instead of trusting
	   that a fresh encoder still sits in it: groups that override
	   winding/culling restore exactly this state, and the groups
	   that never touch it (world surfaces, sprites, particles,
	   chains) only render unculled if the encoder really is
	   unculled. See MTL_SetPassDefaults. */
	MTL_SetPassDefaults(st->encoder);

	/* Classic encoders have no default viewport; set it explicitly.
	   ref_vk parity (R_SetupVulkan viewport + RE_RenderFrame scissor):
	   the world is anchored to the vrect (the r_newrefdef rectangle) of
	   the scene texture and scissor-clipped to it, so the SCR_TileClear
	   tiles the UI pass drew before the world survive outside the
	   world view. With mtl_pixel_size > 1 both are additionally divided
	   by the divisor - floor on the offsets, ceil on the extents, like
	   ref_vk - and the warp pass puts everything back at full size
	   (its uv /= pixelSize sampling addresses exactly this
	   refdef/divisor-anchored content). At viewsize 100 the vrect is
	   the full screen, which is the same rectangle the pass used
	   before. O3 (2): a NOWORLDMODEL frame never runs the warp chain
	   (see the world_rendered gate below), exactly like ref_vk's
	   R_SetVulkan2D skip, so the model renders at full resolution:
	   divisor 1. */
	{
		const double divisor = noworld ? 1.0 : (double)MTL_PixelDivisor();
		const double scX = (double)st->scene_width / (double)vid.width;
		const double scY = (double)st->scene_height / (double)vid.height;
		const double x0 = floor((double)r_newrefdef.x * scX);
		const double x1 = ceil((double)(r_newrefdef.x + r_newrefdef.width) * scX);
		const double y0 = floor((double)r_newrefdef.y * scY);
		const double y1 = ceil((double)(r_newrefdef.y + r_newrefdef.height) * scY);

		[st->encoder setViewport:(MTLViewport){x0 / divisor, y0 / divisor,
		    (x1 - x0) / divisor, (y1 - y0) / divisor, 0.0, 1.0}];
		[st->encoder setScissorRect:(MTLScissorRect){
		    (NSUInteger)floor(x0 / divisor), (NSUInteger)floor(y0 / divisor),
		    (NSUInteger)ceil((x1 - x0) / divisor), (NSUInteger)ceil((y1 - y0) / divisor)}];

		/* W7: the rectangle the world actually covers, in scene-texture
		   pixels (the scissor is always the whole rectangle: the
		   divisor only scales it, both edges round the same way). */
		st->world_vx = (int)floor(x0 / divisor);
		st->world_vy = (int)floor(y0 / divisor);
		st->world_vw = (int)ceil((x1 - x0) / divisor);
		st->world_vh = (int)ceil((y1 - y0) / divisor);
	}
	[st->encoder setDepthStencilState:st->depth_state];

	/* W4: mark the surfaces hit by dynamic lights before the framecount
	   advances in R_SetupFrame (matches the vk frame order). */
	R_PushDlights();

	R_SetupFrame();

	/* O1: mark the leaves/nodes in the current cluster's PVS before the
	   BSP walk, exactly where ref_vk calls it (vk_main.c:951, "done
	   here so we know if we're in water"). Without it r_visframecount
	   stayed 0, every visframe test passed, and the whole in-frustum
	   level was walked and drawn every frame (PVS culling, r_novis and
	   r_lockpvs were all dead). */
	R_MarkLeaves();

	R_DrawWorld();
	R_DrawEntitiesOnList();
	R_RenderDlights();
	R_DrawParticles();
	/* ref_vk parity (vk_main.c calls R_DrawAlphaSurfaces() at this point):
	   R_RecursiveWorldNode() only collects SURF_TRANS33/66 surfaces onto the
	   r_alpha_surfaces chain; the chain has to be unwound - back to front,
	   since the BSP walk was front to back - or every window and every
	   liquid (baseq2 water/slime/lava are WARP + TRANS33/66) is missing
	   from the frame. */
	R_DrawAlphaSurfaces();
	R_RenderFlash();

	/* O2: publish r_lightlevel for the client's usercmd after the view is
	   drawn, same place and order as ref_vk (vk_main.c:1111). */
	R_SetLightLevel();
	[st->encoder endEncoding];
	st->encoder = nil;

	/* W7: the MSAA resolve overwrote the whole scene texture; put the
	   pre-world tiles back everywhere the world pass did not draw
	   (the four rectangles around the world view). */
	if (msaa && ui_before_world)
	{
		const NSUInteger w = (NSUInteger)st->scene_width;
		const NSUInteger h = (NSUInteger)st->scene_height;
		const NSUInteger x0 = (NSUInteger)MAX(0, MIN(st->world_vx, (int)w));
		const NSUInteger y0 = (NSUInteger)MAX(0, MIN(st->world_vy, (int)h));
		const NSUInteger x1 = (NSUInteger)MAX(0, MIN(st->world_vx + st->world_vw, (int)w));
		const NSUInteger y1 = (NSUInteger)MAX(0, MIN(st->world_vy + st->world_vh, (int)h));
		id<MTLBlitCommandEncoder> restore =
			[st->command_buffer blitCommandEncoder];

		/* top, bottom, left, right (half-open, covers everything
		   outside the world rectangle exactly once) */
		[restore copyFromTexture:st->border_save_texture
			sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
			sourceSize:MTLSizeMake(w, y0, 1)
			toTexture:st->scene_texture
			destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
		[restore copyFromTexture:st->border_save_texture
			sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, y1, 0)
			sourceSize:MTLSizeMake(w, h - y1, 1)
			toTexture:st->scene_texture
			destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, y1, 0)];
		[restore copyFromTexture:st->border_save_texture
			sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, y0, 0)
			sourceSize:MTLSizeMake(x0, y1 - y0, 1)
			toTexture:st->scene_texture
			destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, y0, 0)];
		[restore copyFromTexture:st->border_save_texture
			sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x1, y0, 0)
			sourceSize:MTLSizeMake(w - x1, y1 - y0, 1)
			toTexture:st->scene_texture
			destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x1, y0, 0)];
		[restore endEncoding];
	}

	/* O3: MSAA NOWORLDMODEL frame in a mixed frame (a real world pass
	   already ran, so the UI/present chain follows ui_target): the world
	   pipelines can only run at the MSAA sample count, so the model
	   renders through the multisample attachments and resolves into the
	   scene texture as usual; copy just the model rectangle from there
	   onto the live UI target, the way the non-MSAA path draws into it
	   directly. The clear grey travelled with the resolve, so the model
	   keeps its backdrop. Menu-only frames need no copy: ui_target is
	   the scene texture there. */
	if (msaa && noworld && st->ui_target != nil &&
	    st->ui_target != st->scene_texture)
	{
		const NSUInteger w = (NSUInteger)st->scene_width;
		const NSUInteger h = (NSUInteger)st->scene_height;
		const NSUInteger x0 = (NSUInteger)MAX(0, MIN(st->world_vx, (int)w));
		const NSUInteger y0 = (NSUInteger)MAX(0, MIN(st->world_vy, (int)h));
		const NSUInteger x1 = (NSUInteger)MAX(0, MIN(st->world_vx + st->world_vw, (int)w));
		const NSUInteger y1 = (NSUInteger)MAX(0, MIN(st->world_vy + st->world_vh, (int)h));

		if (x1 > x0 && y1 > y0)
		{
			id<MTLBlitCommandEncoder> copy =
				[st->command_buffer blitCommandEncoder];

			[copy copyFromTexture:st->scene_texture
				sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x0, y0, 0)
				sourceSize:MTLSizeMake(x1 - x0, y1 - y0, 1)
				toTexture:st->ui_target
				destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x0, y0, 0)];
			[copy endEncoding];
		}
	}

	// W6b: the world pass produced content this frame; the warp pass
	// (RE_EndWorldRenderpass) becomes eligible. O3 (3): a NOWORLDMODEL
	// frame does not qualify - ref_vk skips the warp/postprocess chain
	// for it (R_SetVulkan2D, vk_main.c:1042, 1052), and here it keeps
	// ui_target on the plain scene texture so the backdrop, the model
	// and the menu UI after it are presented raw, without the world
	// gamma pow. (The flag is never lowered again: if a real world pass
	// already ran this frame its chain state stands, the way ref_vk's
	// "skip finishing RP_WORLD twice" guard keeps the first chain.)
	if (!noworld)
	{
		st->world_rendered = true;
	}
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

	if (!st->frame_active || st->command_buffer == nil ||
	    st->scene_texture == nil || st->pipeline_ui_tex == nil)
	{
		return;
	}

	/* W6b: run the between-passes world warp now, matching ref_vk, which
	   switches to the warp target from R_SetVulkan2D - the first 2D draw
	   of the frame. The host never calls RE_EndWorldRenderpass on normal
	   gameplay frames, so hooking only that entry point would leave the
	   warp unused. Once-per-frame logic inside (warp_done).

	   Only after the world actually rendered, though: SCR_TileClear's
	   tiles arrive here BEFORE the world pass when viewsize < 100
	   (ref_vk routes those draws into the RP_WORLD pipeline instead,
	   vk_mesh.c, and runs the warp chain later from
	   RE_EndWorldRenderpass). Running the chain here would burn
	   warp_done with world_rendered still false and leave the whole
	   frame without the warp/postprocess stages. */
	if (st->world_rendered)
	{
		MTL_RunWarpPass();
	}

	/* W6: the UI pass loads (not clears) the offscreen scene target the
	   world pass just stored to; no depth attachment. W6b: after the
	   world-warp pass ran, that target is the warped copy. */
	st->ui_pass_descriptor.colorAttachments[0].texture =
		st->ui_target != nil ? st->ui_target : st->scene_texture;
	st->ui_pass_descriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
	st->ui_pass_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

	st->ui_encoder = [st->command_buffer renderCommandEncoderWithDescriptor:st->ui_pass_descriptor];
	if (st->ui_encoder != nil)
	{
		[st->ui_encoder setViewport:(MTLViewport){0.0, 0.0,
		    (double)st->scene_width, (double)st->scene_height, 0.0, 1.0}];
	}
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
 * Writes one ui_ubo_t into the slot's world UBO ring and returns its
 * ring offset (SIZE_MAX when the ring is exhausted). The ring is a plain byte stream
 * shared with the world UBOs; the offset advances by sizeof(ui_ubo_t) like
 * every other emitter.
 */
static size_t
MTL_EmitUiUbo(size_t slot, const ui_ubo_t *ubo)
{
	mtlstate_t *st = &mtl_state;
	ui_ubo_t *dst;
	size_t ubo_off;

	if (st->world_ubo_offset[slot] + MTL_UBO_ALIGN(sizeof(ui_ubo_t)) > WORLD_UBO_RING_BYTES)
	{
		return MTL_UboRingDry();
	}

	ubo_off = st->world_ubo_offset[slot];
	dst = (ui_ubo_t *)((byte *)st->world_ubo[slot].contents + ubo_off);
	memcpy(dst, ubo, sizeof(ui_ubo_t));
	/* F4: advance keeps the next ring offset 16-byte aligned */
	st->world_ubo_offset[slot] += MTL_UBO_ALIGN(sizeof(ui_ubo_t));

	return ubo_off;
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
	size_t ubo_off;
	id<MTLRenderPipelineState> pipeline;

	if (image == NULL || image->mtl_texture == nil)
	{
		return;
	}

	ubo_off = MTL_EmitUiUbo(slot, ubo_in);
	if (ubo_off == SIZE_MAX)
	{
		return;		// ring exhausted
	}

	pipeline = tint ? st->pipeline_ui_tint : st->pipeline_ui_tex;

	[st->ui_encoder setRenderPipelineState:pipeline];
	[st->ui_encoder setVertexBuffer:st->ui_tex_vertex_buffer offset:0 atIndex:0];
	[st->ui_encoder setVertexBuffer:st->world_ubo[slot] offset:ubo_off atIndex:1];
	[st->ui_encoder setFragmentTexture:image->mtl_texture atIndex:0];
	[st->ui_encoder setFragmentSamplerState:(image->nolerp ? st->ui_sampler_nearest
	                                               : st->ui_sampler_linear) atIndex:0];
	[st->ui_encoder setFragmentBuffer:st->world_ubo[slot] offset:ubo_off atIndex:0];
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
	size_t ubo_off;

	ubo_off = MTL_EmitUiUbo(slot, ubo_in);
	if (ubo_off == SIZE_MAX)
	{
		return;		// ring exhausted
	}

	[st->ui_encoder setRenderPipelineState:st->pipeline_ui_color];
	[st->ui_encoder setVertexBuffer:st->ui_color_vertex_buffer offset:0 atIndex:0];
	[st->ui_encoder setVertexBuffer:st->world_ubo[slot] offset:ubo_off atIndex:1];
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
			/* L5: scale2x/scale3x write through the destination
			   pointer unconditionally, so a failed allocation here
			   was a NULL deref (ref_vk is unchecked the same way;
			   ours guards). On failure fall back to the unscaled
			   source: one frame of an unsmoothed video, no crash.
			   M7B1: L5's guard checked the malloc but left
			   image_scaled NULL on failure; the fallback now
			   actually points at the unscaled source, and the
			   free below skips it (the caller owns data). */
			byte *scaled = NULL;

			// triple scaling
			if (cols < (vid.width / 3) || rows < (vid.height / 3))
			{
				scaled = malloc((size_t)cols * rows * 9);
				if (scaled != NULL)
				{
					scale3x(data, scaled, cols, rows);
					cols = cols * 3;
					rows = rows * 3;
				}
			}
			else
			// double scaling
			{
				scaled = malloc((size_t)cols * rows * 4);
				if (scaled != NULL)
				{
					scale2x(data, scaled, cols, rows);
					cols = cols * 2;
					rows = rows * 2;
				}
			}

			if (scaled != NULL)
			{
				image_scaled = scaled;
			}
			else
			{
				/* M7B1: keep drawing the unscaled source; cols/rows
				   stay unscaled (the *3 / *2 bumps above only ran
				   on success), so every later size uses match the
				   source. */
				image_scaled = (byte *)data;
				if (!raw_scale_oom_warned)
				{
					raw_scale_oom_warned = 1;
					Com_Printf("RE_Draw_StretchRaw: retexturing "
							"allocation failed, drawing unscaled\n");
				}
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
			/* M7B1: on the OOM fallback image_scaled is the caller's
			   data (the early-return free above already guards this);
			   freeing it would corrupt the caller. */
			if (image_scaled != data)
			{
				free(image_scaled);
			}
			SmoothColorImage(raw_image32, scaled_size, (size_t)scaled_size >> 7);
		}
	}

	/* (Re)create the dynamic texture when this slot's size changes.
	   L3: indexed by frame slot so a replaceRegion can't touch a
	   texture an in-flight frame is still sampling. */
	{
		int slot = st->frame_slot;

		if (raw_textures[slot] != nil &&
		    (raw_textures_width[slot] != cols ||
		     raw_textures_height[slot] != rows))
		{
			[raw_textures[slot] release];
			raw_textures[slot] = nil;
		}

		if (raw_textures[slot] == nil)
		{
			MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
			        MTLPixelFormatRGBA8Unorm
			        width:(NSUInteger)cols
			        height:(NSUInteger)rows
			        mipmapped:NO];
			td.storageMode = MTLStorageModeShared;
			raw_textures[slot] = [st->device newTextureWithDescriptor:td];
			if (raw_textures[slot] == nil)
			{
				free(raw_image32);
				return;
			}
			raw_textures_width[slot] = cols;
			raw_textures_height[slot] = rows;
		}

		[raw_textures[slot] replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)cols, (NSUInteger)rows)
		        mipmapLevel:0 slice:0 withBytes:raw_image32
		        bytesPerRow:cols * 4 bytesPerImage:cols * rows * 4];

		free(raw_image32);
	}

	/* Draw the raw texture as a quad. */
	{
		struct image_s fake;

		memset(&fake, 0, sizeof(fake));
		fake.mtl_texture = raw_textures[st->frame_slot];
		/* L4: r_videos_unfiltered was registered but never read.
		   vk picks S_NEAREST for video when it is non-zero
		   (vk_draw.c:426); route the same choice through the fake
		   image's nolerp flag, which the UI pass sampler select
		   already keys on. */
		fake.nolerp = (r_videos_unfiltered->value != 0);

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
