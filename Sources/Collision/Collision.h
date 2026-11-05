#pragma once

#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#include "Shared.h"
#import "Shared.h"

// MARK: - ModelInfo

// Collision for the server: a capital asset as loaded from Models/Capital/<asset>.scn in
// the game folder (baked from the .obj): its
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

// MARK: - SceneAsset

// Loads a baked model, <subdirectory>/<name>.scn on the search path (Models/… in the game folder, (made from
// the .obj sources by build.sh / Tools/BakeModels.m), and returns its
// top-level nodes, detached so they can go straight into another scene.
// Empty if the file is missing or unreadable.
static inline NSArray<SCNNode *> *SceneAssetNodes(NSString *name, NSString *subdirectory) {
    NSURL *url = FSURL(subdirectory, name, @"scn");
    if (!url) return @[];
    NSError *error = nil;
    SCNScene *scene = [SCNScene sceneWithURL:url options:nil error:&error];
    if (!scene) {
        NSLog(@"SceneAsset: %@.scn unreadable: %@", name, error.localizedDescription);
        return @[];
    }
    NSArray<SCNNode *> *nodes = [scene.rootNode.childNodes copy];
    for (SCNNode *n in nodes) [n removeFromParentNode];
    return nodes;
}
