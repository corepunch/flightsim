#import <SceneKit/SceneKit.h>
#import <Metal/Metal.h>

// Doom 3 style stencil shadow volumes for SceneKit, for omni lights.
//
// SceneKit draws every light in one shader, so there is no per-light pass to
// mask with the stencil the way Doom 3 (or scener) does it. Instead, before
// SceneKit renders a frame, this draws its own depth prepass of the
// receivers and, per light, the shadow volumes (z-fail, extruded just
// past its reach) into the stencil, and turns each light's stencil into a channel
// of a screen-sized mask: 1 lit, 0 in shadow. The lights themselves are not
// SCNLights: materials given -applyToMaterial: add them in a fragment shader
// modifier (GGX, inverse square windowed to the reach) scaled by their mask channel.
//
// Volumes are built once on the CPU for static casters and lights. Casters
// need not be sealed: a closed, consistently wound piece casts from its
// light-facing triangles, and an open one (a plate, an uncapped tube) from
// all of them, each turned to face the light. Either way the volume is a sum
// of closed prisms, so the stencil count is right.
@interface StencilShadows : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;

// Geometry under `node` (world space as it is now) that receives light, and
// that blocks it. Materials whose names start with a prefix in
// `skipPrefixes` are left out.
- (void)addReceiver:(SCNNode *)node skip:(NSArray<NSString *> *)skipPrefixes;
- (void)addCaster:(SCNNode *)node skip:(NSArray<NSString *> *)skipPrefixes;

// Up to 12 lights. `color` in sRGB; `intensity` as an SCNLight's (lumens);
// `reach` as its attenuationEndDistance (falloff exponent 2, from 0).
- (void)addLight:(simd_float3)position color:(NSColor *)color intensity:(float)intensity reach:(float)reach;
// A spot (Doom 3's lights mostly were): lights only within `cone` degrees
// (full angle) around `direction`, with a soft edge.
- (void)addLight:(simd_float3)position color:(NSColor *)color intensity:(float)intensity reach:(float)reach
       direction:(simd_float3)direction cone:(float)degrees;
@property (nonatomic, readonly) NSUInteger lightCount;

// Builds the volumes; call once after adding everything.
- (void)finish;

// Adds the lights to a physically based material. `tint` is its multiply
// colour, if any (SceneKit applies multiply after lighting).
- (void)applyToMaterial:(SCNMaterial *)material tint:(NSColor *)tint;

// Render thread, from -renderer:willRenderScene:atTime:.
- (void)renderWithRenderer:(id<SCNSceneRenderer>)renderer camera:(SCNNode *)camera;

// Debug: no masks (every light lit everywhere).
@property (nonatomic) BOOL disabled;

@end
