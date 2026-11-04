#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#import "Input.h"
#import "Exhaust.h"
#import "Capital.h"

typedef NS_ENUM(NSInteger, ShipClass) {
    ShipClassExecutioner,   // player
    ShipClassSpitfire,
    ShipClassInsurgent,
};

@interface Ship : NSObject

+ (instancetype)shipWithClass:(ShipClass)shipClass smoke:(BOOL)smoke;
+ (SCNGeometry *)geometryForClass:(ShipClass)shipClass;   // shared, OBJ space (+Z nose)
+ (NSString *)nameForClass:(ShipClass)shipClass;

@property (nonatomic, readonly) SCNNode *node;     // forward is -Z
@property (nonatomic, readonly) SCNNode *model;
@property (nonatomic, readonly) Exhaust *exhaust;
@property (nonatomic, readonly) ShipClass shipClass;
@property (nonatomic, readonly) float radius;
@property (nonatomic) Team team;

@property (nonatomic) simd_float3 velocity;
@property (nonatomic) simd_float3 angularVelocity;  // local: pitch, -yaw, -roll (rad/s about X,Y,Z)
@property (nonatomic) float throttle;
/// YES while boost is actually firing this step (button held and energy available).
/// After the energy runs dry, boost stays off until it recharges to 15%
/// (hysteresis), so this doesn't flicker on and off at empty.
@property (nonatomic) BOOL boosting;
@property (nonatomic) float boostEnergy;            // 0..1; drains 0.28/s boosting, recharges 0.12/s
@property (nonatomic) float maxSpeed;
@property (nonatomic) float turnRate;               // multiplier
@property (nonatomic) float hull, shield;
@property (nonatomic) BOOL alive;
@property (nonatomic) double lastShot;
@property (nonatomic) NSUInteger gunIndex;
@property (nonatomic) double deathTime;

@property (nonatomic) simd_float3 position;
@property (nonatomic) simd_quatf orientation;
@property (nonatomic, readonly) simd_float3 forward;
@property (nonatomic, readonly) simd_float3 up;
@property (nonatomic, readonly) simd_float3 right;

- (void)stepWithControls:(ControlState)c dt:(float)dt;
- (simd_float3)nextGunWorldPosition;
- (BOOL)takeDamage:(float)amount;   // returns YES if the shield took the hit
@property (nonatomic, readonly) simd_float3 lastGunLocal;
- (void)resetAt:(simd_float3)position facing:(simd_quatf)orientation;

@end
