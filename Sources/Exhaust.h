#import <SceneKit/SceneKit.h>
#import <simd/simd.h>

// Engine exhaust for one ship: per nozzle a flame cone (shader-driven, with
// flicker and shock diamonds) plus particle "fumes": a hot plasma plume that
// stays attached to the nozzle and a smoke trail left behind in world space.
// Flame length, brightness and particle output all scale with throttle.
@interface Exhaust : NSObject

// nozzles: x,y,z = position in ship space (ship forward is -Z), w = radius.
- (instancetype)initWithNozzles:(const simd_float4 *)nozzles count:(NSUInteger)count
                          color:(simd_float3)color parent:(SCNNode *)parent smoke:(BOOL)smoke;

- (void)updateThrottle:(float)throttle boost:(BOOL)boost dt:(float)dt;
- (void)setEnabled:(BOOL)enabled;

@property (nonatomic, readonly) float level; // smoothed 0..~1.6

+ (NSImage *)softDotImage;
+ (NSImage *)streakImage;      // anamorphic streak, zero alpha on all edges
+ (NSImage *)particleTexture:(NSString *)name;  // Resources/Particles/<name>.png

@end
