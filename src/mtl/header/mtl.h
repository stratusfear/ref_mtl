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
	float position[2];
} flashvert_t;				// 8 bytes

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

#define MAX_LIGHTMAPS	256
#define DYNLIGHTMAP_OFFSET MAX_LIGHTMAPS

// W3: per-slot streaming rings. Vertex data and uniform blocks are
// written by the CPU into these shared buffers and consumed by the GPU
// within one frame; the offsets reset every frame in RE_BeginFrame.
// The dlight UBOs ride on the world UBO ring (it is a plain byte stream,
// consumed sequentially per frame).
#define WORLD_VERTEX_RING_BYTES		(4 * 1024 * 1024)
#define WORLD_LMAP_VERTEX_RING_BYTES	(4 * 1024 * 1024)
#define WORLD_UBO_RING_BYTES		(512 * 1024)
#define DLIGHT_VERTEX_RING_BYTES	(256 * 1024)
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
extern cvar_t	*r_lightmap;
extern cvar_t	*mtl_mip_nearfilter;
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
void Mat_Perspective(float *matrix, float *correction_matrix, float fovy, float aspect, float zNear, float zFar);
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
	float time, qboolean warp);
void MTL_DrawLightmappedChain (mtlpoly_t *p, id<MTLTexture> texture,
	id<MTLTexture> lmap, const float *model, const float *color, float scroll);
void MTL_DrawSkyQuad (id<MTLTexture> texture, const float *verts,
	const float *model, const float *color);
void MTL_FreeLightmaps (void);

/* Writes one viewproj-only UBO (dlight_ubo_t, 64 bytes) into the slot's
 * world UBO ring and returns its GPU address (0 when the ring is
 * exhausted). Shared by the dlight quads and the showtris outlines. */
MTLGPUAddress MTL_EmitViewProjUbo (size_t slot);

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
 * and returns its GPU address (0 when the ring is exhausted).
 */
void R_DrawEntitiesOnList (void);
MTLGPUAddress MTL_EmitAliasUbo (size_t slot, const float *model, float textured);
void R_DrawSpriteModel (entity_t *currententity, const model_t *currentmodel);

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
 * W3 world rendering uses one shared argument table per pipeline stage
 * (four total). They are updated before each draw and snapshotted at
 * draw-encode time (verified by probe11/probe12). Buffer and texture
 * index spaces are separate within one table.
 *
 * Vertex/UBO data is written into per-slot ring buffers indexed by
 * frame_slot; the CPU gate (slot_done) guarantees a slot is only reused
 * after the GPU has finished with it, so per-frame offset resets are
 * safe. UBO space within a slot is consumed sequentially per draw.
 */
typedef struct mtlstate_s
{
	// SDL
	SDL_Window	*window;
	void		*metal_view;	// SDL_MetalView*, non-NULL on SDL3 >= 3.2
	void		*layer;		// CAMetalLayer*

	// Metal 4 core objects (survive mode changes, freed in RE_Shutdown)
	id<MTLDevice>			device;
	id<MTL4CommandQueue>		queue;
	id<MTL4CommandBuffer>		command_buffer;	// long-lived, reused every frame
	id<MTL4CommandAllocator>	allocators[3];	// ring of command allocators
	id<MTLSharedEvent>		shared_event;	// CPU/GPU sync for the ring

	// render pass state (reused every frame)
	MTL4RenderPassDescriptor		*pass_descriptor;
	MTLRenderPassColorAttachmentDescriptor *color_attachment;

	// runtime-compiled shaders (survive mode changes, freed in RE_Shutdown)
	id<MTL4Compiler>			compiler;	// MTL4Compiler, compiles MSL at runtime
	id<MTLLibrary>			library;		// compiled quad.msl + world.msl
	id<MTLResidencySet>		residency_set;	// makes GPU resources visible

	// W3: world rendering pipelines and argument tables
	id<MTLRenderPipelineState>	pipeline_plain;	// world_plain_vertex + world_plain_fragment
	id<MTLRenderPipelineState>	pipeline_lmap;	// world_lmap_vertex + world_lmap_fragment
	id<MTLRenderPipelineState>	pipeline_sky;	// world_sky_vertex + world_plain_fragment
	id<MTL4ArgumentTable>		plain_vert_table;	// buf0 = stage_in verts, buf1 = UBO
	id<MTL4ArgumentTable>		plain_frag_table;	// tex0 = surface, buf0 = UBO
	id<MTL4ArgumentTable>		lmap_vert_table;	// buf0 = stage_in verts, buf1 = UBO
	id<MTL4ArgumentTable>		lmap_frag_table;	// tex0 = surface, tex1 = lightmap, buf0 = UBO

	// W4: dynamic light billboard quads (additive, no depth write).
	// The fragment stage has no resource bindings, so only the vertex
	// argument table exists.
	id<MTLRenderPipelineState>	pipeline_dlight;	// dlight_vertex + dlight_fragment
	id<MTL4ArgumentTable>		dlight_vert_table;	// buf0 = stage_in verts, buf1 = UBO

	// W4: view flash (R_PolyBlend): full-screen clip-space quad, uniform
	// color from v_blend, standard alpha blend, no depth test or write.
	// The six vertices are static; the color rides on the world UBO ring
	// (16 bytes per frame).
	id<MTLRenderPipelineState>	pipeline_flash;	// flash_vertex + flash_fragment
	id<MTL4ArgumentTable>		flash_vert_table;	// buf0 = stage_in verts, buf1 = color UBO
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
	id<MTL4ArgumentTable>		alias_vert_table;	// buf0 = stage_in verts, buf1 = UBO
	id<MTL4ArgumentTable>		alias_frag_table;	// tex0 = skin, buf0 = UBO

	// W5b: sprites (mod_sprite). Reuses the alias vertex ring (same 36B
	// pos3+uv2+color4 layout) and rides its UBO on the world UBO ring.
	// Blending is always on, depth writes stay enabled, and the fragment
	// discards alpha < 0.0666 (ref_vk basic.frag aTreshold).
	id<MTLRenderPipelineState>	pipeline_sprite;	// sprite_vertex + sprite_fragment
	id<MTL4ArgumentTable>		sprite_vert_table;	// buf0 = stage_in verts, buf1 = UBO
	id<MTL4ArgumentTable>		sprite_frag_table;	// tex0 = skin, buf0 = UBO

	// W3: per-slot vertex/UBO rings (one per allocator slot)
	id<MTLBuffer>			world_vertex_buffer[3];	// polyvert_t records (20B)
	id<MTLBuffer>			world_lmap_vertex_buffer[3];	// lmappolyvert_t records (28B)
	id<MTLBuffer>			world_ubo[3];		// world_ubo_t, consumed per draw
	size_t				world_vertex_offset[3];	// write offset, reset per frame
	size_t				world_lmap_vertex_offset[3];
	size_t				world_ubo_offset[3];

	// W4: per-slot dlight vertex ring (dlightvert_t records, 24B)
	id<MTLBuffer>			dlight_vertex_buffer[3];
	size_t				dlight_vertex_offset[3];

	// W4: per-slot showtris vertex ring (dlightvert_t records, 24B)
	id<MTLBuffer>			showtris_vertex_buffer[3];
	size_t				showtris_vertex_offset[3];

	// W5a: per-slot alias vertex ring (aliasvert_t records, 36B)
	id<MTLBuffer>			alias_vertex_buffer[3];
	size_t				alias_vertex_offset[3];

	// W3: lightmap textures (static [0..MAX_LIGHTMAPS-1] lazily
	// created, dynamic [DYNLIGHTMAP_OFFSET..MAX_LIGHTMAPS*2-1]
	// pre-created in MTL_BeginBuildingLightmaps)
	id<MTLTexture>			lightmap_textures[MAX_LIGHTMAPS*2];

	// W3: per-frame render command encoder (created in RE_RenderFrame,
	// ended there; world draw functions encode into it)
	id<MTL4RenderCommandEncoder>	encoder;

	// W3: depth buffer (recreated in RE_BeginFrame when the drawable
	// size changes) and its compare/write state
	id<MTLTexture>			depth_texture;
	id<MTLDepthStencilState>	depth_state;	// world pass: less-than, writes
	id<MTLDepthStencilState>	depth_state_nodwrite;	// dlights: less-than, no writes
	id<MTLDepthStencilState>	depth_state_none;	// flash: always, no writes
	int				depth_width;
	int				depth_height;

	// per-frame state
	id<CAMetalDrawable>		drawable;		// current frame's drawable
	uint64_t			frame_number;	// monotonically increasing
	int				frame_slot;		// current slot in the allocator ring
	uint64_t			slot_done[3];	// last signaled frame number per slot
	qboolean			frame_active;	// frame in flight (Begin..End)
	float			pixel_scale;	// layer contentsScale
	float			inverse_intensity;	// 1.0 / mtl_intensity, texture modulation
	float			camera_separation;	// RE_BeginFrame argument, stereo
} mtlstate_t;

extern mtlstate_t mtl_state;

// All renders should export such function
Q2_DLL_EXPORTED refexport_t GetRefAPI(refimport_t imp);

void RE_Shutdown(void);

#endif
