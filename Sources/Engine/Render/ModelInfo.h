#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#include "GameAPI.h"

// A capital asset as loaded from Resources/Models/Capital/<asset>.scn (baked from the .obj): its
// parts, bounding radius and subsystems (children named Turret_*, Engine_*,
// Shield_*, Core_*, in file order). Shared by the server, which traces
// against it, and the renderer, which dresses copies of its geometry.
// Thread-safe: the cache may be filled from any queue.
@interface ModelInfo : NSObject

+ (ModelInfo *)capitalAsset:(NSString *)asset;

@property (nonatomic, readonly) NSString *asset;
@property (nonatomic, readonly) NSArray<SCNNode *> *nodes;     // placeholder materials, named after the source materials
@property (nonatomic, readonly) float radius;
@property (nonatomic, readonly) const GameModelInfo *info;

// Subsystem kind of a part node by name, or -1 for hull parts.
+ (int)partKindForName:(NSString *)name;

// Segment test in model space. Ignores parts set in deadParts.
- (BOOL)traceFrom:(simd_float3)a to:(simd_float3)b deadParts:(uint64_t)deadParts
            point:(simd_float3 *)point part:(int *)part;

@end
