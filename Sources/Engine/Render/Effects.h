#import <SceneKit/SceneKit.h>
#import <simd/simd.h>

// Film-style space combat effects, layered the way Star Wars games and films
// build them: blaster bolts with a white-hot core inside a coloured HDR glow
// (the bloom carries the colour), pooled muzzle flashes, and explosions made of
// a few shader-driven "hot spheres" (white-hot core, cooler outer fireball,
// one secondary blast), an anamorphic glint, a planar shockwave ring and a few
// glowing debris chunks. No particle clouds.
@interface Effects : NSObject

- (instancetype)initWithScene:(SCNScene *)scene;

// Bolt prototype: node whose children are a core and a glow capsule along +Y.
- (SCNNode *)makeBoltNode;
- (void)styleBolt:(SCNNode *)bolt player:(BOOL)player;

- (void)muzzleFlashOn:(SCNNode *)parent local:(simd_float3)local player:(BOOL)player;
- (void)impactAt:(simd_float3)p player:(BOOL)playerBolt shielded:(BOOL)shielded;
- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull;
- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull scale:(float)scale;

// Camera-facing horizontal lens streak (anamorphic flare look).
- (SCNNode *)streakWithColor:(SKColor *)color width:(float)width height:(float)height;

// Nodes using every effect material, for -[SCNView prepareObjects:].
- (NSArray<SCNNode *> *)warmupNodes;

+ (SCNMaterial *)additiveTextureMaterial:(NSString *)texture tint:(simd_float3)tint;

@end
