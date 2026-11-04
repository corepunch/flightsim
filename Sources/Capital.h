#import <SceneKit/SceneKit.h>
#import <simd/simd.h>

typedef NS_ENUM(NSInteger, Team) { TeamFriend, TeamEnemy, TeamNeutral };

static inline BOOL TeamsHostile(Team a, Team b) {
    return (a == TeamFriend && b == TeamEnemy) || (a == TeamEnemy && b == TeamFriend);
}

typedef NS_ENUM(NSInteger, SubsystemKind) { SubsystemTurret, SubsystemEngine, SubsystemShield, SubsystemCore };

@interface Subsystem : NSObject
@property (nonatomic, strong) SCNNode *node;
@property (nonatomic) SubsystemKind kind;
@property (nonatomic) float hp, maxHp;
@property (nonatomic) BOOL alive;
@property (nonatomic) simd_float3 local;        // centre, capital space
@property (nonatomic) simd_float3 muzzle;       // turrets: barrel direction, capital space
@property (nonatomic) double lastShot;
+ (NSString *)nameForKind:(SubsystemKind)kind;
@end

// A capital ship, station or prop built by Art/build_capitals.py:
// Resources/Models/Capital/<asset>.obj plus the hull textures. It follows an
// optional path, carries destroyable subsystems and is hit-tested against
// its mesh rather than a sphere.
@interface Capital : NSObject

+ (instancetype)capitalWithAsset:(NSString *)asset style:(NSString *)style team:(Team)team;
+ (NSDictionary *)infoForAsset:(NSString *)asset;   // hp, display class name, default style
+ (void)updateSharedMaterials:(double)time;         // running lights blink, shields pulse

@property (nonatomic, copy) NSString *identifier, *name, *asset, *group;
@property (nonatomic, readonly) NSString *className;
@property (nonatomic, readonly) SCNNode *node;
@property (nonatomic, readonly) SCNNode *body;
@property (nonatomic) Team team;
@property (nonatomic) float hull, maxHull;   // absolute hit points
@property (nonatomic, readonly) float radius;
@property (nonatomic) BOOL alive;
@property (nonatomic) BOOL invulnerable;      // takes no damage at all
@property (nonatomic) BOOL noHullDamage;      // only subsystems can be hurt
@property (nonatomic) float stealthRange;     // > 0: only visible on sensors within this range
@property (nonatomic) BOOL isMine, isProp;    // props: small things that die in one blast
@property (nonatomic) BOOL collected;
@property (nonatomic, readonly) NSArray<Subsystem *> *subsystems;

@property (nonatomic) simd_float3 position;
@property (nonatomic) simd_quatf orientation;
@property (nonatomic, readonly) simd_float3 velocity;
@property (nonatomic, readonly) simd_float3 forward;
@property (nonatomic, copy) NSArray<NSValue *> *path;   // simd_float3 world waypoints
@property (nonatomic) float speed;
@property (nonatomic) BOOL loop;
@property (nonatomic, readonly) BOOL arrived;
@property (nonatomic) float spin;                       // deg/s about local up
@property (nonatomic) double deathTime;
@property (nonatomic) BOOL departed;          // jumped out through a gate: safe, gone

- (void)setUniformScale:(float)scale;     // asteroids come in sizes
- (void)update:(float)dt;
- (simd_float3)worldPoint:(simd_float3)local;
- (simd_float3)worldDirection:(simd_float3)local;
- (BOOL)shielded;                       // any shield generator still up
- (BOOL)enginesDead;                    // had engines and lost them all
- (NSUInteger)aliveCount:(SubsystemKind)kind;
- (NSUInteger)totalCount:(SubsystemKind)kind;

// Segment test against the mesh. Returns the world hit point and the
// subsystem struck (nil for the hull).
- (BOOL)hitSegmentFrom:(simd_float3)a to:(simd_float3)b point:(simd_float3 *)point
             subsystem:(Subsystem * __autoreleasing *)subsystem;
// Applies damage; returns YES if a shield absorbed it. Sets alive = NO when
// the hull (or core) is gone.
- (BOOL)damage:(float)amount subsystem:(Subsystem *)subsystem;

@end
