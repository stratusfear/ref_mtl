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
 * Local header for the Metal 4 refresher.
 *
 * =======================================================================
 */

#ifndef __MTL_LOCAL_H__
#define __MTL_LOCAL_H__

#include <stdio.h>
#include <math.h>
#include <stdatomic.h>	// F3: slot_busy cross-thread flags

#ifdef USE_SDL3
#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>
#else
#if defined(__APPLE__)
#include <SDL.h>
#include <SDL_metal.h>
#else
#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>
#endif
#endif

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "../../common/header/ref_shared.h"

#define MTL_VERSION "1.0"

typedef enum
{
	rserr_ok,
	rserr_invalid_mode,
	rserr_unknown
} rserr_t;

extern viddef_t vid;

#define ROUNDUP(a, b) (((a) + ((b)-1)) & ~((b)-1))

//====================================================
// Texture management
//====================================================

typedef struct image_s
{
	char name[MAX_QPATH];               /* game path, including extension */
	imagetype_t type;
	int width, height;                  /* source image */
	int upload_width, upload_height;    /* after power of two and picmip */
	int registration_sequence;          /* 0 = free */
	struct msurface_s *texturechain;    /* for sort-by-texture world drawing */
	id<MTLTexture> mtl_texture;         /* Metal 4 texture (nil until uploaded) */
	qboolean nolerp;                    /* W8: sampled with the nearest UI
	                                       sampler, per r_nolerp_list /
	                                       r_lerp_list / r_2D_unfiltered
	                                       (mirrors vk_image.c) */
} image_t;

#define MAX_MTLTEXTURES	1024

#include "model.h"

#define BACKFACE_EPSILON	0.01

extern image_t mtltextures[MAX_MTLTEXTURES];
extern int		nummtltextures;

extern image_t	*r_notexture;
extern image_t	*r_particletexture;
extern image_t	*r_squaretexture;

//====================================================
// Vertex records (fan-expanded, no index buffers)
//====================================================

typedef struct
{
	float vertex[3];
	float texCoord[2];
} polyvert_t;					// 20 bytes

typedef struct
{
	float vertex[3];
	float texCoord[2];
	float texCoordLmap[2];
} lmappolyvert_t;				// 28 bytes

typedef struct
{
	float vertex[3];
	float color[3];
} dlightvert_t;				// 24 bytes

typedef struct
{
	float vertex[3];
	float color[4];
} beamvert_t;				// 28 bytes

typedef struct
{
	float position[2];
} flashvert_t;				// 8 bytes

// Static 2D UI quad vertices (CPU-expanded triangle list, no index
// buffers in Metal): ui_tex quads carry a uv per corner, the plain
// color quad only positions.
typedef struct
{
	float position[2];
	float uv[2];
} uitexvert_t;				// 16 bytes

typedef struct
{
	float position[2];
} uicolorvert_t;				// 8 bytes

/* W6b: fragment UBO for the underwater world-warp pass; mirrors
   warp_ubo_t in shaders/world.msl (padded to 64 bytes). */
typedef struct
{
	float time;				// @0, 0 = no warp
	float scale;				// @4, viewsize / 100
	float scrWidth;				// @8
	float scrHeight;				// @12
	float pixelSize;				// @16, >= 1 upscale restore
	float refdefX;				// @20, world-view rect, device px
	float refdefY;				// @24
	float refdefW;				// @28
	float refdefH;				// @32
	float pad[7];
} mtl_warp_ubo_t;				// 64 bytes

/* W6c: fragment UBO for the world postprocess pass; mirrors post_ubo_t
   in shaders/world.msl (padded to 64 bytes). */
typedef struct
{
	float postprocess;			// @0, mtl_postprocess flag, 0 = copy
	float gamma;				// @4, 2.1 - vid_gamma
	float pad[14];
} mtl_post_ubo_t;				// 64 bytes

typedef struct
{
	float position[3];
	float uv[2];
	float color[4];
} aliasvert_t;				// 36 bytes

// Per-draw uniform block. Must match the MSL WorldUbo layout exactly
// (float4x4 members are 64-byte aligned in both C and MSL).
typedef struct
{
	float viewproj[16];			// @0
	float model[16];				// @64
	float color[4];				// @128
	float gamma;					// @144
	float viewLightmaps;			// @148
} world_ubo_t;					// 152 bytes

// Per-draw uniform block for dynamic light billboards: only the
// view-projection matrix (matches the vk dlight pipeline, which uploads
// r_viewproj_matrix alone). Must match the MSL DlightUbo layout.
typedef struct
{
	float viewproj[16];			// @0
} dlight_ubo_t;					// 64 bytes

// Per-draw uniform block for alias models: the entity model matrix and
// the view-projection matrix, plus a texture on/off flag (shells draw
// untextured). Must match the MSL AliasUbo layout (float4x4 members are
// 64-byte aligned in both C and MSL).
typedef struct
{
	float viewproj[16];			// @0
	float model[16];				// @64
	float textured;				// @128
} alias_ubo_t;					// 132 bytes

// Per-draw uniform block for sprites: the view-projection matrix and
// the gamma exponent (2.1 - vid_gamma), matching ref_vk's sprite push
// constants. Must match the MSL SpriteUbo layout.
typedef struct
{
	float viewproj[16];			// @0
	float gamma;					// @64
} sprite_ubo_t;					// 72 bytes

// Per-draw uniform block for point particles: the view-projection
// matrix and the point size/attenuation parameters (ref_vk particleUbo).
// Must match the MSL ParticlePointUbo layout.
typedef struct
{
	float viewproj[16];			// @0
	float pointSize;				// @64
	float pointScale;
	float minPointSize;
	float maxPointSize;
	float att_a;
	float att_b;
	float att_c;
} particle_point_ubo_t;			// 92 bytes

// Per-draw uniform block for the 2D UI (RE_Draw_*): NDC offset/scale of
// the static full-screen quad, the uv transform (tex paths) and the
// tint/clear color plus gamma exponent (tint/tex paths). One layout
// serves all three UI pipelines. Must match the MSL UiUbo layout.
typedef struct
{
	float offset[2];			// @0
	float scale[2];			// @8
	float uv_offset[2];		// @16
	float uv_scale[2];		// @24
	float color[4];			// @32
	float gamma;				// @48
} ui_ubo_t;					// 56 bytes

#define MAX_LIGHTMAPS	256
#define DYNLIGHTMAP_OFFSET MAX_LIGHTMAPS

// W3: per-slot streaming rings. Vertex data and uniform blocks are
// written by the CPU into these shared buffers and consumed by the GPU
// within one frame; the offsets reset every frame in RE_BeginFrame.
// The dlight UBOs ride on the world UBO ring (it is a plain byte stream,
// consumed sequentially per frame).
#define WORLD_VERTEX_RING_BYTES		(4 * 1024 * 1024)
#define WORLD_LMAP_VERTEX_RING_BYTES	(4 * 1024 * 1024)
#define WORLD_UBO_RING_BYTES		(2 * 1024 * 1024)

/* F4: the offset given to set*Buffer:offset:atIndex: for a struct
   argument must be a multiple of 16 bytes; MTL_DEBUG_LAYER enforces
   this with a hard abort. The world UBO ring carries records of
   52-152 bytes, so every ring advance is rounded up with this macro to
   keep the next record's offset aligned. */
#define MTL_UBO_ALIGN(x)			((size_t)(((x) + 15u) & ~(size_t)15))
#define DLIGHT_VERTEX_RING_BYTES	(256 * 1024)
#define BEAM_VERTEX_RING_BYTES		(256 * 1024)
#define SHOWTRIS_VERTEX_RING_BYTES	(4 * 1024 * 1024)
#define ALIAS_VERTEX_RING_BYTES		(4 * 1024 * 1024)

//====================================================================

extern int		r_visframecount;
extern int		r_framecount;
extern cplane_t	frustum[4];
extern int		c_brush_polys, c_alias_polys;

//
// view origin
//
extern vec3_t	vup;
extern vec3_t	vpn;
extern vec3_t	vright;
extern vec3_t	r_origin;

//
// screen size info
//
extern refdef_t	r_newrefdef;
extern int		r_viewcluster, r_viewcluster2, r_oldviewcluster, r_oldviewcluster2;

extern cvar_t	*r_lefthand;
extern cvar_t	*r_drawworld;
extern cvar_t	*r_drawentities;
extern cvar_t	*r_novis;
extern cvar_t	*r_lerpmodels;
extern cvar_t	*r_lockpvs;
extern cvar_t	*r_modulate;
extern cvar_t	*r_vsync;
extern cvar_t	*r_clear;
extern cvar_t	*r_lightlevel;	// FIXME: This is a HACK to get the client's light level
extern cvar_t	*r_gunfov;
extern cvar_t	*r_farsee;

extern cvar_t	*mtl_overbrightbits;
extern cvar_t	*r_validation;
extern cvar_t	*r_cull;
extern cvar_t	*mtl_picmip;
extern cvar_t	*r_palettedtexture;
extern cvar_t	*mtl_flashblend;
extern cvar_t	*mtl_polyblend;
extern cvar_t	*mtl_dynamic;
extern cvar_t	*mtl_showtris;
extern cvar_t	*mtl_custom_particles;
extern cvar_t	*mtl_particle_size;
extern cvar_t	*mtl_particle_att_a;
extern cvar_t	*mtl_particle_att_b;
extern cvar_t	*mtl_particle_att_c;
extern cvar_t	*mtl_particle_min_size;
extern cvar_t	*mtl_particle_max_size;
extern cvar_t	*r_lightmap;
extern cvar_t	*mtl_mip_nearfilter;	/* M2: mip-generation filter, see
					   MTL_MipFilterLevel in mtl_image.m
					   (ref_vk parity: vk_image.c:172) */
extern cvar_t	*r_anisotropic;		/* M2: registered here for parity
					   with ref_vk (vk_main.c:1166); drives
					   world_sampler / lmap_sampler
					   maxAnisotropy */
extern cvar_t	*r_retexturing;
extern cvar_t	*r_scale8bittextures;
extern cvar_t	*r_nolerp_list;
extern cvar_t	*r_lerp_list;
extern cvar_t	*r_2D_unfiltered;
extern cvar_t	*r_videos_unfiltered;
extern cvar_t	*r_fixsurfsky;

extern cvar_t	*vid_fullscreen;
extern cvar_t	*vid_gamma;
extern cvar_t	*viewsize;

extern int		c_visible_lightmaps;
extern int		c_visible_textures;

extern float	r_view_matrix[16];
extern float	r_projection_matrix[16];
extern float	r_viewproj_matrix[16];

extern float *s_blocklights, *s_blocklights_max;
/* L2: free the blocklights scratch at renderer shutdown; ref_vk
   frees it in its RE_Shutdown (vk_main.c:1351-1357). */
void MTL_ShutdownLightScratch (void);

extern model_t	*r_worldmodel;

extern unsigned	d_8to24table[256];
extern unsigned	r_rawpalette[256];

extern vec3_t	lightspot;

extern int		registration_sequence;
extern int		r_dlightframecount;

void R_LightPoint (const bspxlightgrid_t *grid, vec3_t p, vec3_t color, entity_t *currententity);
void R_PushDlights (void);

//====================================================
// Matrix helpers (ported from ref_vk, row-major)
//====================================================

void Mat_Identity(float *matrix);
void Mat_Mul(float *m1, float *m2, float *res);
void Mat_Translate(float *matrix, float x, float y, float z);
void Mat_Rotate(float *matrix, float deg, float x, float y, float z);
void Mat_Scale(float *matrix, float x, float y, float z);
void Mat_Perspective(float *matrix, float fovy, float aspect, float zNear, float zFar);
void Mat_Ortho(float *matrix, float left, float right, float bottom, float top, float zNear, float zFar);

//====================================================
// World drawing
//====================================================

void R_SetupFrame (void);
void R_DrawWorld (void);
void R_RenderDlights (void);
void R_SetCacheState( msurface_t *surf );
void R_BuildLightMap (msurface_t *surf, byte *dest, int stride);
void R_DrawAlphaSurfaces (void);
void RE_InitParticleTexture (void);
void Draw_InitLocal (void);
void MTL_SubdivideSurface (msurface_t *fa, model_t *loadmodel);
void R_RotateForEntity (entity_t *e, float *mvMatrix);
void R_MarkLeaves (void);

/*
 * W4 draw helpers. MTL_DrawPolyChain fan-expands a mtlpoly_t chain into
 * the current frame slot's vertex ring and draws it with the plain-texture
 * pipeline (sky == false) or the sky pipeline (sky == true). `uvscale`/
 * `scroll` transform the texture coordinates: uv = verts[3..4] * uvscale
 * + scroll (s component only); when warp is set a per-vertex sine turbulence
 * is added on top (classic water/lava warp, evaluated per vertex so the GPU
 * interpolates it across each triangle): uv.s += sin(2*time + uv.t*3.28)*0.05,
 * uv.t += sin(2*time + uv.s*3.28)*0.05, with scroll applied to s after the
 * warp (matching the vk polygon_warp vertex shader). MTL_DrawLightmappedChain
 * does the same for lightmapped surfaces (28-byte vertices, scroll added to
 * the surface uv only). MTL_DrawSkyQuad draws a pre-built 6-vertex sky quad.
 */
void MTL_DrawPolyChain (mtlpoly_t *p, id<MTLTexture> texture, const float *model,
	const float *color, float uvscale, float scroll, qboolean sky,
	float time, qboolean warp, qboolean nolerp);
void MTL_DrawLightmappedChain (mtlpoly_t *p, id<MTLTexture> texture,
	id<MTLTexture> lmap, const float *model, const float *color, float scroll,
	qboolean nolerp);
void MTL_DrawSkyQuad (id<MTLTexture> texture, const float *verts,
	const float *model, const float *color);
void MTL_FreeLightmaps (void);

/* Writes one viewproj-only UBO (dlight_ubo_t, 64 bytes) into the slot's
 * world UBO ring and returns its byte offset within the ring buffer
 * (SIZE_MAX when exhausted). Shared by the dlight quads and the
 * showtris outlines. */
size_t MTL_EmitViewProjUbo (size_t slot);
/* G2: shared uniform-ring exhaustion path: counts the dropped draw in
   st->ubo_exhausted (one-shot Com_DPrintf on the first drop) and
   returns SIZE_MAX, the emitters' sentinel for "ring dry". */
size_t MTL_UboRingDry (void);

/* K2: the world pass's raster-state baseline: Clockwise front winding
 * and MTLCullModeNone - Metal's documented fresh-encoder defaults,
 * which most world-pass draws (world surfaces, sprites, particles,
 * chains, UI) rely on: Metal pipelines carry no raster state at all,
 * so those groups get culling disabled only while the encoder sits
 * in this state. ref_vk instead bakes culling into each pipeline
 * (qvk.h: frontFace CLOCKWISE, CULL_MODE_BACK default, FRONT for the
 * lefthand and dlight pipelines, NONE for null/showtris/warp).
 * mtl's clip space does not mirror winding against vk, so all three
 * groups that override the encoder state use the same Clockwise
 * front face as ref_vk and only pick a cull mode: the alias-model
 * draws back-cull (front when the viewproj is left-hand mirrored),
 * the beam tube back-culls, the dlight cubes front-cull - each
 * exactly the pair ref_vk bakes into the matching pipeline. The
 * alias winding is established against vk pixel captures (the
 * translucent glass.dm2 misc_blackhole needs *a* cull - unculled it
 * double-blends, funnel-window delta +24 - and the weapon view
 * model's open surfaces show the wrong faces if the sign is wrong:
 * CounterClockwise + back-carves front-face holes into the stock
 * where Clockwise + Back matches vk, and tightens the blackhole
 * funnel-window diff to vk from mean 1.27/max 78 to 0.90/43). See
 * the definition in mtl_main.m and the groups' comments. */
void MTL_SetPassDefaults (id<MTLRenderCommandEncoder> encoder);

void EmitWaterPolys (msurface_t *fa, image_t *texture,
				   const float *modelMatrix, const float *color,
				   qboolean solid_surface);
void R_AddSkySurface(msurface_t *fa);
void R_ClearSkyBox(void);
void R_DrawSkyBox(void);
void R_MarkSurfaceLights(dlight_t *light, int bit, mnode_t *node,
	int r_dlightframecount);

//====================================================
// Models / surfaces
//====================================================

void MTL_BuildPolygonFromSurface(msurface_t *fa, model_t *currentmodel);
void MTL_CreateSurfaceLightmap(msurface_t *surf);
void MTL_EndBuildingLightmaps(void);
void MTL_BeginBuildingLightmaps(model_t *m);

void R_DrawBrushModel (entity_t *currententity, const model_t *currentmodel);

/*
 * W5a: alias models. R_DrawEntitiesOnList walks the refdef entity list
 * (skipping the world at index 0) and dispatches by model type; mod_alias
 * is drawn by R_DrawAliasModel, mod_sprite by R_DrawSpriteModel.
 * MTL_EmitAliasUbo writes one alias_ubo_t into the slot's world UBO ring
 * and returns its byte offset within the ring buffer (SIZE_MAX when
 * exhausted).
 * MTL_BuildDepthHackViewproj (I2) builds the RF_DEPTHHACK /
 * RDF_NOWORLDMODEL projection variant (ref_vk r_vulkan_correction_dh):
 * gun near plane 4, depth compressed into the [0, 0.6] band so the view
 * model can't poke through world geometry.
 */
void R_DrawEntitiesOnList (void);
size_t MTL_EmitAliasUbo (size_t slot, const float *model, const float *viewproj, float textured);
/* L2: free the alias scratch buffers (s_lerped, s_cmdverts) at
   renderer shutdown; ref_vk's Mesh_Free parity. */
void MTL_ShutdownAliasScratch (void);
size_t MTL_EmitSpriteUbo (size_t slot);
void R_DrawSpriteModel (entity_t *currententity, const model_t *currentmodel);
void MTL_BuildDepthHackViewproj (const entity_t *e, float *out);

//====================================================
// Images
//====================================================

image_t *MTL_LoadPic(const char *name, byte *pic, int width, int realwidth,
		    int height, int realheight, size_t data_size, imagetype_t type,
		    int bits);
image_t	*MTL_FindImage (const char *name, imagetype_t type);
void MTL_InitImages (void);
void MTL_ShutdownImages (void);
void MTL_FreeUnusedImages (void);
qboolean MTL_ImageHasFreeSpace(void);
void MTL_ImageList_f (void);

//====================================================
// Console info (W9, ref_vk's Vk_Strings_f / Vk_Mem_f parity)
//====================================================

void Mtl_Strings_f (void);
void Mtl_Mem_f (void);

//====================================================
// Models
//====================================================

void Mod_Init (void);
void Mod_Modellist_f (void);

void RE_BeginRegistration (char *model);
model_t *RE_RegisterModel (char *name);
image_t *RE_RegisterSkin (const char *name);
void RE_EndRegistration (void);

//====================================================
// Sky
//====================================================

void RE_SetSky (const char *name, float rotate, vec3_t axis);

//====================================================
// Renderer state
//====================================================

/*
 * Renderer state. Populated in RE_InitContext (W1).
 *
 * metal_view and layer are kept as void* so this header stays usable
 * from both SDL2 and SDL3 builds; the concrete types are
 * SDL_MetalView* (SDL3 >= 3.2 only) and CAMetalLayer*.
 *
 * World/UI draws bind buffers and textures directly on the classic
 * MTLRenderCommandEncoder (setVertexBuffer:offset:atIndex: etc.), one
 * binding set per draw. UBO and vertex data live in per-slot ring
 * buffers indexed by frame_slot; the CPU gate (slot_busy, driven by
 * command-buffer completion handlers) guarantees a slot is only reused
 * after the GPU has finished with it, so per-frame offset resets are
 * safe. UBO space within a slot is consumed sequentially per draw.
 */
typedef struct mtlstate_s
{
	// SDL
	SDL_Window	*window;
	void		*metal_view;	// SDL_MetalView*, non-NULL on SDL3 >= 3.2
	void		*layer;		// CAMetalLayer*

	// Metal core objects (survive mode changes, freed in RE_Shutdown).
	// Command encoding uses the classic (MTL3-era) queue/encoder API:
	// drawing through MTL4 queues with an app-created render target
	// corrupts the displayed image on M3 (Bug C, see tools/bugc_repro).
	// Pipelines are still runtime-compiled with MTL4Compiler; those are
	// plain id<MTLRenderPipelineState> and encode unchanged.
	id<MTLDevice>			device;
	id<MTLCommandQueue>		command_queue;
	id<MTLCommandBuffer>		command_buffer;	// one per frame (retained)

	// render pass descriptors (reused every frame, attachments rebound)
	MTLRenderPassDescriptor		*pass_descriptor;

	// runtime-compiled shaders (survive mode changes, freed in RE_Shutdown)
	id<MTL4Compiler>			compiler;	// MTL4Compiler, compiles MSL at runtime
	id<MTLLibrary>			library;		// compiled quad.msl + world.msl
	const char			*msl_version;	// MSL language version compiled for

	// W3: world rendering pipelines. Bindings are set directly on the
	// classic encoder per draw (buffer 0 = stage_in verts, buffer 1 =
	// UBO; frag tex0 = surface, tex1 = lightmap, buffer 0 = UBO).
	id<MTLRenderPipelineState>	pipeline_plain;	// world_plain_vertex + world_plain_fragment
	id<MTLRenderPipelineState>	pipeline_lmap;	// world_lmap_vertex + world_lmap_fragment
	id<MTLRenderPipelineState>	pipeline_sky;	// world_sky_vertex + world_plain_fragment

	// W4: dynamic light billboard quads (additive, no depth write).
	// The fragment stage has no resource bindings.
	id<MTLRenderPipelineState>	pipeline_dlight;	// dlight_vertex + dlight_fragment

	// I1: RF_BEAM tubes (R_DrawBeam): 28-byte vertices (pos3 + color4),
	// standard alpha blend (vk beam pipeline's SRC_ALPHA /
	// ONE_MINUS_SRC_ALPHA), no depth write. The viewproj UBO is the
	// dlight one (dlight_ubo_t).
	id<MTLRenderPipelineState>	pipeline_beam;	// beam_vertex + beam_fragment

	// W4: view flash (R_PolyBlend): full-screen clip-space quad, uniform
	// color from v_blend, standard alpha blend, no depth test or write.
	// The six vertices are static; the color rides on the world UBO ring
	// (16 bytes per frame).
	id<MTLRenderPipelineState>	pipeline_flash;	// flash_vertex + flash_fragment
	id<MTLBuffer>			flash_vertex_buffer;	// static 6-vertex triangle list (8B each)

	// W4: showtris (R_DrawTriangleOutlines): white line-strip outlines of
	// every lightmapped triangle, drawn over the world with no depth test,
	// cull or blend. Reuses the dlight vertex/fragment functions and the
	// dlight vertex argument table (identical 24B pos+color layout).
	id<MTLRenderPipelineState>	pipeline_showtris;	// dlight_vertex + dlight_fragment

	// W5a: alias models (MD2/SP2). CPU-expanded triangle lists of 36-byte
	// vertices (pos3 + uv2 + color4); the per-draw UBO (alias_ubo_t, 132B)
	// rides on the world UBO ring. Opaque and translucent pipelines share
	// the alias_vertex/alias_fragment functions; only the blend/depth
	// encoder state differs.
	id<MTLRenderPipelineState>	pipeline_alias;		// alias_vertex + alias_fragment
	id<MTLRenderPipelineState>	pipeline_alias_translucent;

	// W5b: sprites (mod_sprite). Reuses the alias vertex ring (same 36B
	// pos3+uv2+color4 layout) and rides its UBO on the world UBO ring.
	// Blending is always on, depth writes stay enabled, and the fragment
	// discards alpha < 0.0666 (ref_vk basic.frag aTreshold).
	id<MTLRenderPipelineState>	pipeline_sprite;	// sprite_vertex + sprite_fragment

	// W5c: particles. Textured mode (mtl_custom_particles 0 or 2) draws
	// one triangle per particle (three 36B alias-ring vertices) with the
	// sprite vertex function and a 0.5 alpha-discard fragment; point mode
	// (1, default) draws one point per particle with a GPU-computed point
	// size. UBOs ride on the world UBO ring.
	id<MTLRenderPipelineState>	pipeline_particle;	// sprite_vertex + particle_fragment
	id<MTLRenderPipelineState>	pipeline_point_particle;	// particle_point_vertex + particle_point_fragment

	// W5d: 2D UI (RE_Draw_*). Three pipelines over one static full-screen
	// quad pair: the tex path samples a picture and applies gamma, the
	// tint path additionally multiplies by the UBO color, and the color
	// path outputs the UBO color with standard alpha blending. All three
	// share the 56-byte ui_ubo_t layout; the UBOs ride on the world UBO
	// ring (16-byte aligned, MTL_UBO_ALIGN, since F4). Drawn in a second,
	// color-only render pass
	// that loads (not clears) the scene target, except when the world pass
	// has not run (plaque/cinematic frames) or a UI quad was drawn before
	// it (TileClear with viewsize < 100), in which case the world pass
	// must not clear either.
	id<MTLRenderPipelineState>	pipeline_ui_tex;	// ui_tex_vertex + ui_tex_fragment
	id<MTLRenderPipelineState>	pipeline_ui_tint;	// ui_tex_vertex + ui_tint_fragment
	id<MTLRenderPipelineState>	pipeline_ui_color;	// ui_color_vertex + ui_color_fragment
	id<MTLBuffer>			ui_tex_vertex_buffer;	// static 6-vertex triangle list (16B each)
	id<MTLBuffer>			ui_color_vertex_buffer;	// static 6-vertex triangle list (8B each)

	// W8: per-draw UI sampling, mirroring ref_vk's per-texture sampler
	// choice (nolerp textures -> nearest, everything else -> linear with
	// mip). Bound onto the ui tex/tint shaders' [[sampler(0)]] argument;
	// the choice comes from image_t.nolerp, set at load time from
	// r_nolerp_list / r_lerp_list / r_2D_unfiltered.
	id<MTLSamplerState>		ui_sampler_nearest;
	id<MTLSamplerState>		ui_sampler_linear;

	// M2: world-path sampling, replacing the old constexpr
	// world_sampler / world_lmap_sampler in world.msl. Filtered
	// (min/mag/mip linear) with maxAnisotropy from r_anisotropic,
	// mirror of ref_vk's vk_current_sampler + lmap sampler
	// (vk_common.c:906); the nearest variant carries the
	// r_nolerp_list textures (vk's S_NEAREST), chosen per draw from
	// image_t.nolerp. world_sampler repeats (was address::repeat in
	// the shader), lmap_sampler clamps (was address::clamp_to_edge).
	// Rebuilt when r_anisotropic changes (RE_BeginFrame), like vk's
	// sampler rebuild in its R_BeginFrame.
	id<MTLSamplerState>		world_sampler;
	id<MTLSamplerState>		world_sampler_nearest;
	id<MTLSamplerState>		lmap_sampler;

	// W5d: UI render pass (color only, no depth), created in
	// RE_InitContext and reused every frame; the encoder is created
	// lazily on the first RE_Draw_* call of the frame.
	MTLRenderPassDescriptor		*ui_pass_descriptor;
	id<MTLRenderCommandEncoder>	ui_encoder;

	// W3: per-slot vertex/UBO rings (one per frame slot)
	id<MTLBuffer>			world_vertex_buffer[3];	// polyvert_t records (20B)
	id<MTLBuffer>			world_lmap_vertex_buffer[3];	// lmappolyvert_t records (28B)
	id<MTLBuffer>			world_ubo[3];		// world_ubo_t, consumed per draw
	size_t				world_vertex_offset[3];	// write offset, reset per frame
	size_t				world_lmap_vertex_offset[3];
	size_t				world_ubo_offset[3];

	// W4: per-slot dlight vertex ring (dlightvert_t records, 24B)
	id<MTLBuffer>			dlight_vertex_buffer[3];
	size_t				dlight_vertex_offset[3];

	// I1: per-slot beam vertex ring (beamvert_t records, 28B)
	id<MTLBuffer>			beam_vertex_buffer[3];
	size_t				beam_vertex_offset[3];

	// W4: per-slot showtris vertex ring (dlightvert_t records, 24B)
	id<MTLBuffer>			showtris_vertex_buffer[3];
	size_t				showtris_vertex_offset[3];

	// W5a: per-slot alias vertex ring (aliasvert_t records, 36B)
	id<MTLBuffer>			alias_vertex_buffer[3];
	size_t				alias_vertex_offset[3];

	// W3: lightmap textures (static [0..MAX_LIGHTMAPS-1] lazily
	// created; dynamic range G4: three per-frame-slot sets, block b of
	// slot s at DYNLIGHTMAP_OFFSET + s*MAX_LIGHTMAPS + b, also lazily
	// created. The per-slot dynamic sets keep this frame's replaceRegion
	// writes off the textures the 1-2 in-flight frames are still sampling.
	id<MTLTexture>			lightmap_textures[MAX_LIGHTMAPS*4];

	// W3: per-frame render command encoder (created in RE_RenderFrame,
	// ended there; world draw functions encode into it)
	id<MTLRenderCommandEncoder>	encoder;

	// W3: depth buffer (recreated in RE_BeginFrame when the drawable
	// size changes) and its compare/write state
	id<MTLTexture>			depth_texture;
	id<MTLDepthStencilState>	depth_state;	// world pass: less-than, writes
	id<MTLDepthStencilState>	depth_state_nodwrite;	// dlights: less-than, no writes
	id<MTLDepthStencilState>	depth_state_none;	// flash: always, no writes
	int				depth_width;
	int				depth_height;

	// W6: offscreen scene color texture. The world and UI passes render
	// into it; a single final present pass (RE_EndFrame) samples it and
	// draws it to the drawable as a full-screen quad. The drawable is
	// then only ever a render target of exactly one pass, the shape
	// framebufferOnly = YES expects. Recreated in RE_BeginFrame on
	// drawable-size changes, like depth_texture.
	id<MTLTexture>			scene_texture;
	int				scene_width;
	int				scene_height;

	/* W7: world-pass MSAA (r_msaa_samples, ref_vk's vk_msaa +
	   vk_msaaColorbuffer parity). msaa_sample_count is 1 when the
	   world pass renders straight into scene_texture / depth_texture;
	   > 1 adds a multisampled color + depth attachment and the world
	   pass resolves it into scene_texture
	   (MTLStoreActionMultisampleResolve, ref_vk's pResolveAttachments
	   from vk_msaaColorbuffer into vk_colorbuffer). The world
	   pipelines are rebuilt at the matching rasterSampleCount;
	   pipeline_sample_count tracks the count they were built for. The
	   UI / warp / postprocess / present side always runs at 1 sample
	   off the resolved texture, like ref_vk's single-sample
	   vk_colorbuffer / vk_ui_depthbuffer. border_save_texture holds
	   the pre-world scene (SCR_TileClear tiles at viewsize < 100)
	   across the resolve, which overwrites the whole resolve texture
	   regardless of the scissor rect; H1 reuses the same save to put
	   the tiles back around the warp pass, whose 1:1 passthrough
	   outside the refdef rect would otherwise composite the raw
	   down-scaled world texels of the bands [vrect/p, vrect) into the
	   2D border. tiles_saved marks the frames that have that copy.
	   world_vx/vy/vw/vh are the
	   device-pixel world viewport/scissor rectangle of the frame. */
	id<MTLTexture>			msaa_color_texture;
	id<MTLTexture>			msaa_depth_texture;
	id<MTLTexture>			border_save_texture;
	qboolean			tiles_saved;
	NSUInteger			msaa_sample_count;
	NSUInteger			pipeline_sample_count;
	/* F2: the r_msaa_samples request that last failed; MTL_UpdateMSAA
	   stays degraded at 1 sample until the cvar moves off this value
	   (one message, no per-frame rebuild loop). */
	NSUInteger			msaa_failed_want;
	int				world_vx;
	int				world_vy;
	int				world_vw;
	int				world_vh;

	// W6: present pass and pipeline (color only, no depth, no blend).
	MTLRenderPassDescriptor		*present_pass_descriptor;
	id<MTLRenderPipelineState>		pipeline_present;	// present_vertex + present_fragment

	/* W6b: underwater world-warp pass (ref_vk RP_WORLD_WARP/world_warp.frag
	   parity). Runs between the world and UI passes when the view is
	   submerged: samples scene_texture, writes the warped image into
	   warp_texture, and the UI pass + present switch their attachment /
	   source to it (ui_target). Skipped (ui_target stays scene_texture)
	   when there is no warp work to do, which is a visual no-op. */
	id<MTLTexture>			warp_texture;
	id<MTLRenderPipelineState>		pipeline_warp;	// warp_vertex + warp_fragment
	/* G3: the former warp_ubo / post_ubo single-slot buffers are gone;
	   the pass parameters travel inline via setFragmentBytes. */
	/* W6c: world postprocess pass (ref_vk postprocess.frag parity). Runs
	   after the warp stage, unconditionally while a world pass produced
	   content: samples ui_target (warped or plain scene), writes
	   post_texture; gamma + 1.5 intensity bump for the whole world image. */
	id<MTLTexture>			post_texture;
	id<MTLRenderPipelineState>		pipeline_postprocess;	// warp_vertex + postprocess_fragment
	id<MTLTexture>			ui_target;	// post/warp/scene texture (not owned)
	qboolean			world_rendered;	// world pass ran this frame
	qboolean			warp_done;		// warp pass decided this frame
	/* G6: scene_texture was (re)allocated, content not yet defined;
	   R_BeginFrame clears it once before the frame's passes load it. */
	qboolean			scene_needs_clear;

	// per-frame state
	id<CAMetalDrawable>		drawable;		// current frame's drawable
	uint64_t			frame_number;	// monotonically increasing
	int				frame_slot;		// current slot in the frame ring
	/* F3: written (release) by Metal's command-buffer completion
	   handler thread, polled (acquire) on the render thread; a plain
	   qboolean here is a data race. */
	_Atomic bool			slot_busy[3];	// slot has a frame in flight (completion handler clears it)
	qboolean			frame_active;	// frame in flight (Begin..End)
	/* W9: ring consumption of the last completed frame, plus lifetime
	   maxima, snapshotted in RE_EndFrame before RE_BeginFrame resets
	   the per-slot offsets; reported by the "mtl_mem" command (ring
	   order: world vertex, world lmap, UBO, dlight, showtris, alias). */
	size_t			ring_usage[6];
	size_t			ring_usage_max[6];
	/* G2: number of draws dropped by uniform-ring exhaustion across
	   the session; reported by "mtl_mem". */
	unsigned		ubo_exhausted;
	/* N1: world surface chain draws skipped for a nil texture or
	   sampler state; reported by "mtl_mem". */
	unsigned		surfaces_dropped;
	float			pixel_scale;	// layer contentsScale
	float			inverse_intensity;	// 1.0 / mtl_intensity, texture modulation
	float			camera_separation;	// RE_BeginFrame argument, stereo
} mtlstate_t;

extern mtlstate_t mtl_state;

// All renders should export such function
Q2_DLL_EXPORTED refexport_t GetRefAPI(refimport_t imp);

void RE_Shutdown(void);

#endif
