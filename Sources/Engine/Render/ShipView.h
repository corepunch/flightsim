#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#import "Exhaust.h"
#include "Protocol.h"

// What a fighter looks like: hull mesh, engine exhaust, shield bubble and
// damage fire/smoke. No physics: the game flies ships, this draws them.
@interface ShipView : NSObject

+ (instancetype)shipWithClass:(ShipClass)shipClass smoke:(BOOL)smoke;
+ (instancetype)viewWithModel:(NSString *)model;          // "ship:<mesh>"
+ (SCNGeometry *)geometryForClass:(ShipClass)shipClass;   // shared, OBJ space (+Z nose)

@property (nonatomic, readonly) SCNNode *node;     // forward is -Z
@property (nonatomic, readonly) SCNNode *model;
@property (nonatomic, readonly) Exhaust *exhaust;
@property (nonatomic, readonly) ShipClass shipClass;
@property (nonatomic, readonly) float radius;

- (void)updateThrottle:(float)throttle boost:(BOOL)boost hull:(float)hull alive:(BOOL)alive dt:(float)dt;
- (void)flashShield;
- (void)setAlive:(BOOL)alive;

@end
