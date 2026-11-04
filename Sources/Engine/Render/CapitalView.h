#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#import "ModelInfo.h"
#include "Protocol.h"

// What a capital ship, station, prop or rock looks like: a clone of the
// asset's parts dressed in its style's hull materials. Destroyed subsystems
// are hidden by part index (EntityState.deadParts).
@interface CapitalView : NSObject

+ (instancetype)viewWithModel:(NSString *)model;       // "cap:<asset>:<style>"
+ (SCNNode *)prototypeForAsset:(NSString *)asset style:(NSString *)style;
+ (void)updateSharedMaterials:(double)time;             // running lights blink, shields pulse

@property (nonatomic, readonly) SCNNode *node;
@property (nonatomic, readonly) SCNNode *body;
@property (nonatomic, readonly) ModelInfo *info;
@property (nonatomic, readonly) NSArray<SCNNode *> *parts;
@property (nonatomic) uint64_t deadParts;

- (NSUInteger)countParts:(SubsystemKind)kind alive:(BOOL)aliveOnly;

@end
