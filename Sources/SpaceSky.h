#import <SceneKit/SceneKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

// Bakes the procedural skybox (see Resources/Shaders/SkyBake.metal) into an
// HDR cubemap and builds the camera-relative space dust.
@interface SpaceSky : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device faceSize:(NSUInteger)faceSize seed:(uint32_t)seed;

@property (nonatomic, readonly) id<MTLTexture> cubeTexture;
@property (nonatomic, readonly) simd_float3 sunDirection;    // toward the sun
@property (nonatomic, readonly) simd_float3 planetDirection;
@property (nonatomic, readonly) double bakeSeconds;

// Infinite field of dust streaks that wraps around the camera.
- (SCNNode *)makeDustNode;
- (void)updateDust:(SCNNode *)dust cameraPosition:(simd_float3)cameraPosition velocity:(simd_float3)velocity;

@end
