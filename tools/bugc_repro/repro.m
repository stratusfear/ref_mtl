/*
 * Copyright (C) 2026 ref_mtl port
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
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301, USA.
 */

// bugc_repro: standalone reproducer for the intermittent constant-magenta
// (234,51,247) display corruption seen with ref_mtl (Metal 4 API path) on
// macOS 27.x. Mirrors ref_mtl's W6 architecture: MTL4CommandQueue + reused
// MTL4CommandBuffer + 3 MTL4CommandAllocators, MTL4Compiler pipelines by
// function name, MTL4ArgumentTables bound via gpuAddress/gpuResourceID,
// residency sets (own + layer's) attached to the queue, offscreen scene
// RT (color+depth) rendered by a world pass + UI pass, then a fullscreen
// present pass sampling the scene into the drawable.
// waitForDrawable/commit/signalEvent/signalDrawable/present in ref_mtl's
// order. Window is animated (scrolling bands + UI atlas quads) so a
// frozen display is distinguishable from a live-but-poisoned one.
//
// Knobs (bisect helpers):
//   --classic        classic MTLCommandQueue + classic pipelines (control)
//   --classicpipe    MTL4 queue but classic-created pipelines
//   --hybrid         classic queue does ALL draws; MTL4 queue idle (control)
//   --hybscene       MTL4 scene passes offscreen; classic queue does the
//                    present-into-drawable pass (cross-queue event sync)
//   --empty4         MTL4 queue commits an EMPTY CB + signalEvent every
//                    frame; classic queue draws everything
//   --nodraw         MTL4 encoders open passes but issue no draws
//   --noresset       skip residency-set wiring entirely
//   --noattach     . build+commit the sets but never addResidencySet them
//   --drawres        grant each frame's drawable.texture residency in the
//                    app's own set before committing (manual-model fix test)
//   --worldonly      MTL4: skip UI+present passes
//   --uionly         MTL4: skip world pass
//   --newcb          fresh MTL4CommandBuffer each frame (reuse allocators)
//   --nosyncdraw     omit waitForDrawable:/signalDrawable: (only present)
//   --syncpresent    CPU waitUntilSignaledValue before present
//   --fullsync       CPU wait on previous frame every frame
//   --txn            CAMetalLayer presentsWithTransaction = YES
//   --yes            framebufferOnly = YES (default NO)
//   --maxdraw N      maximumDrawableCount (default 3)
//   --scan           getBytes strict scan of scene (+drawable when
//                    framebufferOnly=NO; NOTE: drawable getBytes can block
//                    in IOSurfaceClientLock once presents are latched)
//   --secs N         run duration (default 30)
//
// Build:
//   clang -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore \
//       repro.m -o repro

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <pthread.h>

static BOOL g_classic = NO, g_txn = NO, g_yes = NO, g_fullsync = NO;
static BOOL g_syncpresent = NO, g_scan = NO;
static BOOL g_classicpipe = NO, g_nosyncdraw = NO, g_newcb = NO;
static BOOL g_hybrid = NO, g_hybscene = NO, g_empty4 = NO, g_nodraw = NO;
static BOOL g_noresset = NO, g_worldonly = NO, g_uionly = NO;
static BOOL g_noattach = NO, g_drawres = NO;
static BOOL g_privscene = NO, g_privdepth = NO;
static BOOL g_direct = NO, g_clscene = NO;
static int g_maxdraw = 3;
static double g_secs = 30.0;

static const char *msl_src =
"using namespace metal;\n"
"struct UVS { float4 pos [[position]]; float2 uv; half4 color; };\n"
"struct Uni { float phase; float pad0; float2 pad1; };\n"
"vertex UVS quad_vs(const device float2 *v [[buffer(0)]], constant Uni &u [[buffer(1)]], uint vid [[vertex_id]])\n"
"{ UVS o; o.pos = float4(v[vid].x, v[vid].y, v[vid].y*0.5+0.5, 1.0); o.uv = float2(v[vid].x*0.5+0.5, 0.5-v[vid].y*0.5); o.color = half4(1.0h); return o; }\n"
"vertex UVS present_vs(const device float2 *v [[buffer(0)]], constant Uni &u [[buffer(1)]], uint vid [[vertex_id]])\n"
"{ UVS o; o.pos = float4(v[vid].x, v[vid].y, 0.0, 1.0); o.uv = float2(v[vid].x*0.5+0.5, 0.5-v[vid].y*0.5); o.color = half4(1.0h); return o; }\n"
"fragment half4 scene_fs(UVS in [[stage_in]], constant Uni &u [[buffer(0)]])\n"
"{ float s = fmod(in.uv.y*8.0 + u.phase, 1.0); float v = 0.10 + 0.45*in.uv.y + (s < 0.5 ? 0.06 : 0.0);\n"
"  float h = fmod(in.uv.x*6.0 - u.phase, 1.0); v += (h < 0.15 ? 0.04 : 0.0);\n"
"  return half4(float(v*0.85), float(v), float(v*0.92), 1.0h); }\n"
"fragment half4 ui_fs(UVS in [[stage_in]], constant Uni &u [[buffer(0)]], texture2d<float, access::sample> atlas [[texture(0)]])\n"
"{ constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge, mip_filter::none);\n"
"  float cx = fmod(u.phase*17.0, 8.0) * 0.125;\n"
"  float2 uv = float2(cx + fmod(in.uv.x, 0.125), fmod(in.uv.y, 0.125));\n"
"  float4 t = atlas.sample(s, uv);\n"
"  return half4(half3(t.rgb * 0.7f), t.a);\n"
"}\n"
"fragment half4 present_fs(UVS in [[stage_in]], texture2d<float, access::sample> scene [[texture(0)]])\n"
"{ constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge, mip_filter::none);\n"
"  return half4(scene.sample(s, in.uv)); }\n";

@interface AppView : NSView
@end
@implementation AppView
+ (BOOL)wantsUpdateLayer { return YES; }
- (void)drawLayer:(CALayer *)l inContext:(CGContextRef)ctx {}
@end

static id<MTLDevice> device;
static id<MTL4Compiler> compiler;
static id<MTLLibrary> library;
static id<MTL4CommandQueue> queue4;
static id<MTLCommandQueue> queuec;
static id<MTL4CommandBuffer> cb4;
static id<MTL4CommandAllocator> allocs[3];
static id<MTLSharedEvent> event;
static id<MTLResidencySet> rset_hold; static BOOL g_rset = NO;
static id<MTLTexture> scene_tex, depth_tex, atlas_tex;
static id<MTLBuffer> quad_vb, uni_buf;
static id<MTLRenderPipelineState> ps_scene, ps_ui, ps_present;
static id<MTL4ArgumentTable> vt_world, ft_world, vt_ui, ft_ui, vt_present, ft_present;
static CAMetalLayer *layer;
static NSWindow *window;

static uint64_t frame_no = 0;
static uint64_t slot_done[3];

static const float quad_verts[6][2] = {
	{ -1,-1 }, { 1,-1 }, { -1,1 }, { -1,1 }, { 1,-1 }, { 1,1 },
};

/* count strict-mask pixels via getBytes; fills hit with first offender */
static int
scan_tex(id<MTLTexture> tex, uint8_t *buf, char *hit, size_t hitcap)
{
	if (hit && hitcap) hit[0] = 0;
	MTLRegion region = MTLRegionMake2D(0, 0, tex.width, tex.height);
	[tex getBytes:buf bytesPerRow:tex.width * 4 fromRegion:region mipmapLevel:0];
	int count = 0;
	for (NSUInteger y = 0; y < tex.height; y++)
	for (NSUInteger x = 0; x < tex.width; x++)
	{
		uint8_t *p = buf + (y * tex.width + x) * 4;   /* BGRA8Unorm */
		int b = p[0], g = p[1], r = p[2];
		if (abs(r-234) <= 12 && abs(g-51) <= 12 && abs(b-247) <= 12)
		{
			if (count == 0 && hit && hitcap)
				snprintf(hit, hitcap, "scene @(%zu,%zu)=(r%d,g%d,b%d)", x, y, r, g, b);
			count++;
		}
	}
	return count;
}

static void
make_pipelines_mtl4(void)
{
	MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];
	MTL4LibraryFunctionDescriptor *fd;
	fd = [MTL4LibraryFunctionDescriptor new]; fd.name = @"quad_vs"; fd.library = library;
	pd.vertexFunctionDescriptor = fd;
	fd = [MTL4LibraryFunctionDescriptor new]; fd.name = @"scene_fs"; fd.library = library;
	pd.fragmentFunctionDescriptor = fd;
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	ps_scene = [compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:nil];

	pd = [MTL4RenderPipelineDescriptor new];
	fd = [MTL4LibraryFunctionDescriptor new]; fd.name = @"quad_vs"; fd.library = library;
	pd.vertexFunctionDescriptor = fd;
	fd = [MTL4LibraryFunctionDescriptor new]; fd.name = @"ui_fs"; fd.library = library;
	pd.fragmentFunctionDescriptor = fd;
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
	pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	ps_ui = [compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:nil];

	pd = [MTL4RenderPipelineDescriptor new];
	fd = [MTL4LibraryFunctionDescriptor new]; fd.name = @"present_vs"; fd.library = library;
	pd.vertexFunctionDescriptor = fd;
	fd = [MTL4LibraryFunctionDescriptor new]; fd.name = @"present_fs"; fd.library = library;
	pd.fragmentFunctionDescriptor = fd;
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	ps_present = [compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:nil];
}

static void
make_pipelines_classic(void)
{
	NSError *err = nil;
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [library newFunctionWithName:@"quad_vs"];
	pd.fragmentFunction = [library newFunctionWithName:@"scene_fs"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	ps_scene = [device newRenderPipelineStateWithDescriptor:pd error:&err];

	pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [library newFunctionWithName:@"quad_vs"];
	pd.fragmentFunction = [library newFunctionWithName:@"ui_fs"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = YES;
	pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
	pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	ps_ui = [device newRenderPipelineStateWithDescriptor:pd error:&err];

	pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [library newFunctionWithName:@"present_vs"];
	pd.fragmentFunction = [library newFunctionWithName:@"present_fs"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	ps_present = [device newRenderPipelineStateWithDescriptor:pd error:&err];
}

/* render loop runs on a worker thread; main thread runs NSApp */
static void *
render_thread(void *arg)
{
	(void)arg;
	id<MTLDepthStencilState> ds = [device newDepthStencilStateWithDescriptor:[MTLDepthStencilDescriptor new]];

	uint8_t *scanbuf = nil; size_t scancap = 0;
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:g_secs];

	while ([[NSDate date] compare:deadline] == NSOrderedAscending)
	{
		@autoreleasepool {

		frame_no++;
		int slot = (int)(frame_no % 3);

		if (event)
		{
			if (g_fullsync && frame_no > 1)
				[event waitUntilSignaledValue:frame_no - 1 timeoutMS:1000];
			else if (slot_done[slot] > 0)
				[event waitUntilSignaledValue:slot_done[slot] timeoutMS:1000];
		}

		/* clscene uses doubled event values: classic scene pass signals
		   2n, MTL4 present tail signals 2n+1 (values must increase). */
		uint64_t sig = g_clscene ? 2 * frame_no + 1 : frame_no;

		struct { float phase; float pad0; float pad1[2]; } *uni =
			(void *)uni_buf.contents;
		uni->phase = (float)(frame_no % 360) / 60.0f;

		id<CAMetalDrawable> drawable = [layer nextDrawable];
		if (!drawable) { usleep(16000); continue; }

		if (g_scan)
		{
			size_t need = (size_t)scene_tex.width * scene_tex.height * 4;
			if (scancap < need) { free(scanbuf); scanbuf = malloc(need); scancap = scanbuf ? need : 0; }
		}

		if (g_classic || g_hybrid || g_empty4)
		{
			/* classic queue draws everything (classic PPLs for --classic,
			   MTL4-created PPLs for --hybrid/--empty4) */
			id<MTLCommandBuffer> cmdbuf = [queuec commandBuffer];
			MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
			rpd.colorAttachments[0].texture = scene_tex;
			rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
			rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
			rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
			rpd.depthAttachment.texture = depth_tex;
			rpd.depthAttachment.loadAction = MTLLoadActionClear;
			rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
			rpd.depthAttachment.clearDepth = 1.0;
			id<MTLRenderCommandEncoder> enc = [cmdbuf renderCommandEncoderWithDescriptor:rpd];
			[enc setRenderPipelineState:ps_scene];
			[enc setDepthStencilState:ds];
			[enc setVertexBuffer:quad_vb offset:0 atIndex:0];
			[enc setVertexBuffer:uni_buf offset:0 atIndex:1];
			[enc setFragmentBuffer:uni_buf offset:0 atIndex:0];
			[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
			[enc endEncoding];

			rpd = [MTLRenderPassDescriptor renderPassDescriptor];
			rpd.colorAttachments[0].texture = scene_tex;
			rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
			rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
			enc = [cmdbuf renderCommandEncoderWithDescriptor:rpd];
			[enc setRenderPipelineState:ps_ui];
			[enc setVertexBuffer:quad_vb offset:0 atIndex:0];
			[enc setVertexBuffer:uni_buf offset:0 atIndex:1];
			[enc setFragmentBuffer:uni_buf offset:0 atIndex:0];
			[enc setFragmentTexture:atlas_tex atIndex:0];
			[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
			[enc endEncoding];

			rpd = [MTLRenderPassDescriptor renderPassDescriptor];
			rpd.colorAttachments[0].texture = drawable.texture;
			rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
			rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
			enc = [cmdbuf renderCommandEncoderWithDescriptor:rpd];
			[enc setRenderPipelineState:ps_present];
			[enc setVertexBuffer:quad_vb offset:0 atIndex:0];
			[enc setFragmentTexture:scene_tex atIndex:0];
			[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
			[enc endEncoding];

			[cmdbuf presentDrawable:drawable];
			[cmdbuf commit];
			if (g_empty4)
			{
				/* also commit an EMPTY MTL4 CB + event signal per frame */
				[cb4 beginCommandBufferWithAllocator:allocs[slot]];
				[cb4 endCommandBuffer];
				id<MTL4CommandBuffer> pcb = cb4;
				[queue4 commit:&pcb count:1];
				[queue4 signalEvent:event value:frame_no];
			}
			slot_done[slot] = frame_no;
		}
		else
		{
			if (g_clscene)
			{
				/* classic queue WRITES the offscreen scene; the MTL4
				   queue then samples it in the present pass below. */
				id<MTLCommandBuffer> ccb = [queuec commandBuffer];
				MTLRenderPassDescriptor *crpd = [MTLRenderPassDescriptor renderPassDescriptor];
				crpd.colorAttachments[0].texture = scene_tex;
				crpd.colorAttachments[0].loadAction = MTLLoadActionClear;
				crpd.colorAttachments[0].storeAction = MTLStoreActionStore;
				crpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
				crpd.depthAttachment.texture = depth_tex;
				crpd.depthAttachment.loadAction = MTLLoadActionClear;
				crpd.depthAttachment.storeAction = MTLStoreActionDontCare;
				crpd.depthAttachment.clearDepth = 1.0;
				id<MTLRenderCommandEncoder> cenc = [ccb renderCommandEncoderWithDescriptor:crpd];
				[cenc setRenderPipelineState:ps_scene];
				[cenc setDepthStencilState:ds];
				[cenc setVertexBuffer:quad_vb offset:0 atIndex:0];
				[cenc setVertexBuffer:uni_buf offset:0 atIndex:1];
				[cenc setFragmentBuffer:uni_buf offset:0 atIndex:0];
				[cenc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				[cenc endEncoding];

				crpd = [MTLRenderPassDescriptor renderPassDescriptor];
				crpd.colorAttachments[0].texture = scene_tex;
				crpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
				crpd.colorAttachments[0].storeAction = MTLStoreActionStore;
				cenc = [ccb renderCommandEncoderWithDescriptor:crpd];
				[cenc setRenderPipelineState:ps_ui];
				[cenc setVertexBuffer:quad_vb offset:0 atIndex:0];
				[cenc setVertexBuffer:uni_buf offset:0 atIndex:1];
				[cenc setFragmentBuffer:uni_buf offset:0 atIndex:0];
				[cenc setFragmentTexture:atlas_tex atIndex:0];
				[cenc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				[cenc endEncoding];

				[ccb encodeSignalEvent:event value:2 * frame_no];
				[ccb commit];
				[event waitUntilSignaledValue:2 * frame_no timeoutMS:3000];
			}

			id<MTL4CommandBuffer> cb = g_newcb ? [device newCommandBuffer] : cb4;
			[cb beginCommandBufferWithAllocator:allocs[slot]];

			MTL4RenderPassDescriptor *rpd;
			id<MTL4RenderCommandEncoder> enc;

			if (!g_uionly && !g_empty4 && !g_clscene)
			{
				rpd = [MTL4RenderPassDescriptor new];
				rpd.colorAttachments[0].texture = g_direct ? drawable.texture : scene_tex;
				rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
				rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
				rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
				rpd.depthAttachment.texture = depth_tex;
				rpd.depthAttachment.loadAction = MTLLoadActionClear;
				rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
				rpd.depthAttachment.clearDepth = 1.0;
				[vt_world setAddress:quad_vb.gpuAddress atIndex:0];
				[vt_world setAddress:uni_buf.gpuAddress atIndex:1];
				[ft_world setAddress:uni_buf.gpuAddress atIndex:0];
				enc = [cb renderCommandEncoderWithDescriptor:rpd];
				[enc setRenderPipelineState:ps_scene];
				[enc setDepthStencilState:ds];
				[enc setArgumentTable:vt_world atStages:MTLRenderStageVertex];
				[enc setArgumentTable:ft_world atStages:MTLRenderStageFragment];
				if (!g_nodraw)
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				[enc endEncoding];
			}

			if (!g_worldonly && !g_empty4 && !g_clscene)
			{
				rpd = [MTL4RenderPassDescriptor new];
				rpd.colorAttachments[0].texture = g_direct ? drawable.texture : scene_tex;
				rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
				rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
				[vt_ui setAddress:quad_vb.gpuAddress atIndex:0];
				[vt_ui setAddress:uni_buf.gpuAddress atIndex:1];
				[ft_ui setAddress:uni_buf.gpuAddress atIndex:0];
				[ft_ui setTexture:atlas_tex.gpuResourceID atIndex:0];
				enc = [cb renderCommandEncoderWithDescriptor:rpd];
				[enc setRenderPipelineState:ps_ui];
				[enc setArgumentTable:vt_ui atStages:MTLRenderStageVertex];
				[enc setArgumentTable:ft_ui atStages:MTLRenderStageFragment];
				if (!g_nodraw)
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				[enc endEncoding];
			}

			if (!g_hybscene && !g_empty4 && !g_worldonly && !g_direct)
			{
				rpd = [MTL4RenderPassDescriptor new];
				rpd.colorAttachments[0].texture = drawable.texture;
				rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
				rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
				[vt_present setAddress:quad_vb.gpuAddress atIndex:0];
				[ft_present setTexture:scene_tex.gpuResourceID atIndex:0];
				enc = [cb renderCommandEncoderWithDescriptor:rpd];
				[enc setRenderPipelineState:ps_present];
				[enc setArgumentTable:vt_present atStages:MTLRenderStageVertex];
				[enc setArgumentTable:ft_present atStages:MTLRenderStageFragment];
				if (!g_nodraw)
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				[enc endEncoding];
			}

			[cb endCommandBuffer];

			/* drawres: manual-residency fix candidate — grant the current
			   drawable residency in our own set before committing. */
			if (g_drawres && g_rset && drawable.texture)
			{
				[rset_hold addAllocation:drawable.texture];
				[rset_hold commit];
			}

			/* ref_mtl's exact end-of-frame sequence, with knobs */
			if (g_hybscene)
			{
				/* MTL4 queue draws the offscreen scene only; the present
				   pass into the drawable runs on the CLASSIC queue, gated
				   by the shared event. No MTL4 drawable sync ops. */
				id<MTL4CommandBuffer> pcb = cb;
				[queue4 commit:&pcb count:1];
				[queue4 signalEvent:event value:frame_no];
				id<MTLCommandBuffer> ccb = [queuec commandBuffer];
				[ccb encodeWaitForEvent:event value:frame_no];
				MTLRenderPassDescriptor *prpd = [MTLRenderPassDescriptor renderPassDescriptor];
				prpd.colorAttachments[0].texture = drawable.texture;
				prpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
				prpd.colorAttachments[0].storeAction = MTLStoreActionStore;
				id<MTLRenderCommandEncoder> penc = [ccb renderCommandEncoderWithDescriptor:prpd];
				[penc setRenderPipelineState:ps_present];
				[penc setVertexBuffer:quad_vb offset:0 atIndex:0];
				[penc setFragmentTexture:scene_tex atIndex:0];
				[penc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				[penc endEncoding];
				[ccb presentDrawable:drawable];
				[ccb commit];
			}
			else
			{
				if (!g_nosyncdraw)
					[queue4 waitForDrawable:drawable];
				id<MTL4CommandBuffer> pcb = cb;
				[queue4 commit:&pcb count:1];
				[queue4 signalEvent:event value:sig];
				if (g_syncpresent)
					[event waitUntilSignaledValue:sig timeoutMS:3000];
				if (!g_nosyncdraw)
					[queue4 signalDrawable:drawable];
				[drawable present];
			}
			slot_done[slot] = sig;
		}

		if (g_scan && !(g_classic || g_hybrid || g_empty4) && scanbuf)
		{
			char hit[64] = "";
			char hit2[64] = "";
			[event waitUntilSignaledValue:frame_no timeoutMS:3000];
			int sc = (g_privscene || g_direct) ? -1 : scan_tex(scene_tex, scanbuf, hit, sizeof hit);
			int dc = 0;
			if (!g_yes)
				dc = scan_tex(drawable.texture, scanbuf, hit2, sizeof hit2);
			printf("f%llu scene=%d draw=%d %s %s\n",
			       (unsigned long long)frame_no, sc, dc, hit, hit2);
			fflush(stdout);
		}

		}
	}
	fflush(stdout);
	exit(0);   /* deadline reached; tear down the whole app */
	return NULL;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return YES; }
@end

int
main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++)
	{
		if (!strcmp(argv[i], "--classic")) g_classic = YES;
		else if (!strcmp(argv[i], "--classicpipe")) g_classicpipe = YES;
		else if (!strcmp(argv[i], "--hybrid")) g_hybrid = YES;
		else if (!strcmp(argv[i], "--hybscene")) g_hybscene = YES;
		else if (!strcmp(argv[i], "--empty4")) g_empty4 = YES;
		else if (!strcmp(argv[i], "--nodraw")) g_nodraw = YES;
		else if (!strcmp(argv[i], "--noresset")) g_noresset = YES;
		else if (!strcmp(argv[i], "--noattach")) g_noattach = YES;
		else if (!strcmp(argv[i], "--drawres")) g_drawres = YES;
		else if (!strcmp(argv[i], "--privscene")) g_privscene = YES;
		else if (!strcmp(argv[i], "--privdepth")) g_privdepth = YES;
		else if (!strcmp(argv[i], "--direct")) g_direct = YES;
		else if (!strcmp(argv[i], "--clscene")) g_clscene = YES;
		else if (!strcmp(argv[i], "--worldonly")) g_worldonly = YES;
		else if (!strcmp(argv[i], "--uionly")) g_uionly = YES;
		else if (!strcmp(argv[i], "--newcb")) g_newcb = YES;
		else if (!strcmp(argv[i], "--nosyncdraw")) g_nosyncdraw = YES;
		else if (!strcmp(argv[i], "--syncpresent")) g_syncpresent = YES;
		else if (!strcmp(argv[i], "--fullsync")) g_fullsync = YES;
		else if (!strcmp(argv[i], "--txn")) g_txn = YES;
		else if (!strcmp(argv[i], "--yes")) g_yes = YES;
		else if (!strcmp(argv[i], "--scan")) g_scan = YES;
		else if (!strcmp(argv[i], "--secs") && i + 1 < argc) g_secs = atof(argv[++i]);
		else if (!strcmp(argv[i], "--maxdraw") && i + 1 < argc) g_maxdraw = atoi(argv[++i]);
	}

	@autoreleasepool {

	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	static AppDelegate *del = nil;
	del = [AppDelegate new];
	[NSApp setDelegate:del];

	NSError *err = nil;
	device = MTLCreateSystemDefaultDevice();
	if (!device) { fprintf(stderr, "no device\n"); return 1; }

	MTLCompileOptions *co = [MTLCompileOptions new];
	co.languageVersion = MTLLanguageVersion3_2;
	library = [device newLibraryWithSource:[NSString stringWithUTF8String:msl_src] options:co error:&err];
	if (!library) { fprintf(stderr, "compile: %s\n", err.localizedDescription.UTF8String); return 1; }

	MTL4CompilerDescriptor *cd = [MTL4CompilerDescriptor new];
	compiler = [device newCompilerWithDescriptor:cd error:&err];
	if (!compiler) { fprintf(stderr, "compiler: %s\n", err.localizedDescription.UTF8String); return 1; }

	NSRect fr = NSMakeRect(0, 0, 640, 512);
	window = [[NSWindow alloc] initWithContentRect:fr
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
		backing:NSBackingStoreBuffered defer:NO];
	[window setTitle:@"bugc_repro"];

	AppView *view = [AppView new];
	view.frame = NSMakeRect(0, 0, 640, 512);   /* MUST be (0,0), not content-rect origin */
	layer = [CAMetalLayer layer];
	view.layer = layer;
	view.wantsLayer = YES;
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.framebufferOnly = g_yes ? YES : NO;
	layer.presentsWithTransaction = g_txn ? YES : NO;
	layer.maximumDrawableCount = (NSUInteger)g_maxdraw;
	layer.contentsScale = 2.0;
	layer.drawableSize = CGSizeMake(1280, 1024);
	window.contentView = view;
	[window makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];

	scene_tex = nil; depth_tex = nil;
	{
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
			width:1280 height:1024 mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = g_privscene ? MTLStorageModePrivate : MTLStorageModeShared;
		scene_tex = [device newTextureWithDescriptor:td];

		td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
			width:1280 height:1024 mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget;
		td.storageMode = g_privdepth ? MTLStorageModePrivate : MTLStorageModeShared;
		depth_tex = [device newTextureWithDescriptor:td];
	}

	{
		/* atlas: 8x8 glyph cells, alternating patterned/blank */
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
			width:1024 height:1024 mipmapped:NO];
		td.usage = MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModeShared;
		atlas_tex = [device newTextureWithDescriptor:td];
		uint8_t *ab = malloc(1024*1024*4);
		for (int y = 0; y < 1024; y++)
		for (int x = 0; x < 1024; x++)
		{
			int cell = ((y/128)*8 + (x/128));
			uint8_t *p = ab + (y*1024 + x)*4;
			int fx = x % 128, fy = y % 128;
			int on = (cell % 3 != 2) && (fx > 8 && fx < 120 && fy > 8 && fy < 120 && ((fx/8 + fy/8) % 2 == 0));
			p[0] = 150; p[1] = 235; p[2] = 150; p[3] = on ? 255 : 0;
		}
		[atlas_tex replaceRegion:MTLRegionMake2D(0,0,1024,1024) mipmapLevel:0 slice:0
			withBytes:ab bytesPerRow:1024*4 bytesPerImage:1024*1024*4];
		free(ab);
	}

	quad_vb = [device newBufferWithBytes:quad_verts length:sizeof(quad_verts) options:MTLResourceStorageModeShared];
	uni_buf = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];

	if (g_classic)
		make_pipelines_classic();
	else if (g_classicpipe)
		make_pipelines_classic();
	else
		make_pipelines_mtl4();

	if (!ps_scene || !ps_ui || !ps_present) { fprintf(stderr, "pipelines failed\n"); return 1; }

	if (g_classic || g_hybrid || g_hybscene || g_empty4 || g_clscene)
	{
		queuec = [device newCommandQueue];
		if (!queuec) { fprintf(stderr, "command queue failed\n"); return 1; }
	}

	if (!g_classic)
	{
		queue4 = [device newMTL4CommandQueue];
		cb4 = [device newCommandBuffer];
		for (int i = 0; i < 3; i++)
			allocs[i] = [device newCommandAllocator];
		event = [device newSharedEvent];

		/* ref_mtl parity: residency sets. Layer's set covers drawables;
		   our own set makes scene/depth/atlas/buffers resident. */
		if (!g_noresset)
		{
			MTLResidencySetDescriptor *rsd = [MTLResidencySetDescriptor new];
			id<MTLResidencySet> rset = [device newResidencySetWithDescriptor:rsd error:&err];
			if (rset)
			{
				if (!g_noattach)
					[queue4 addResidencySet:rset];
				[rset addAllocation:scene_tex];
				[rset addAllocation:depth_tex];
				[rset addAllocation:atlas_tex];
				[rset addAllocation:quad_vb];
				[rset addAllocation:uni_buf];
				rset_hold = rset; g_rset = YES;
				[rset commit];
			}
			NSLog(@"DIAG layer.residencySet=%@ own_set=%@", layer.residencySet, rset);
			if (layer.residencySet != nil && !g_noattach)
				[queue4 addResidencySet:layer.residencySet];
		}

		MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new];
		atd.maxBufferBindCount = 4;
		atd.maxTextureBindCount = 2;
		atd.maxSamplerStateBindCount = 0;
		vt_world = [device newArgumentTableWithDescriptor:atd error:&err];
		ft_world = [device newArgumentTableWithDescriptor:atd error:&err];
		vt_ui = [device newArgumentTableWithDescriptor:atd error:&err];
		ft_ui = [device newArgumentTableWithDescriptor:atd error:&err];
		vt_present = [device newArgumentTableWithDescriptor:atd error:&err];
		ft_present = [device newArgumentTableWithDescriptor:atd error:&err];
		if (!vt_world || !ft_world || !vt_ui || !ft_ui || !vt_present || !ft_present)
		{ fprintf(stderr, "argument tables failed: %s\n", err.localizedDescription.UTF8String); return 1; }
	}

	pthread_t th;
	pthread_create(&th, NULL, render_thread, NULL);

	[NSApp run];   /* main thread: window composites via WindowServer */

	}

	return 0;
}
