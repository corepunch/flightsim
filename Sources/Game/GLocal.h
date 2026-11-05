// Game module internals. Nothing here is visible to the engine: it only sees
// GetGameAPI() and the GameExport table. Classes carry a G prefix so they
// never clash with engine classes when both live in one process.
#import <Foundation/Foundation.h>
#include "GameAPI.h"
#include "SharedMath.h"
#include "ShipMove.h"
#import "Assets.h"
#import "MissionRunner.h"

extern GameImport gi;

// Console variables the game registers in Init; read them at use.
static inline float GCvar(const char *name) { return gi.cvarValue(name); }
static inline NSString *GCvarString(const char *name) { return @(gi.cvarString(name) ?: ""); }

static inline float frand(void) { return (float)arc4random_uniform(1000000) / 1000000.0f; }
static inline float srand1(void) { return frand() * 2.0f - 1.0f; }
static inline simd_float3 randomUnit(void) {
    simd_float3 v;
    do { v = simd_make_float3(srand1(), srand1(), srand1()); } while (simd_length_squared(v) > 1 || simd_length_squared(v) < 0.01f);
    return simd_normalize(v);
}

void GPrint(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// This game's sides. The engine only knows team numbers and the relations
// the game publishes in CS_TEAMS (see GTeamRelations).
typedef enum { TeamFriend, TeamEnemy, TeamNeutral, TeamCount } Team;

static inline bool TeamsHostile(Team a, Team b) {
    return (a == TeamFriend && b == TeamEnemy) || (a == TeamEnemy && b == TeamFriend);
}

// The CS_TEAMS configstring for TeamsHostile: a team is friendly to itself,
// hostile where TeamsHostile says so, neutral otherwise.
static inline NSString *GTeamRelations(void) {
    char s[MAX_TEAMS * MAX_TEAMS + 1];
    for (int a = 0; a < MAX_TEAMS; a++)
        for (int b = 0; b < MAX_TEAMS; b++)
            s[a * MAX_TEAMS + b] = a == b ? '1' : (a < TeamCount && b < TeamCount && TeamsHostile((Team)a, (Team)b) ? '2' : '0');
    s[MAX_TEAMS * MAX_TEAMS] = 0;
    return @(s);
}

typedef NS_ENUM(NSInteger, AIMode) { AIModeAttack, AIModeEvade, AIModeReposition };


@class GClient;

#pragma mark - Fighter

// A ship flown by a player or the AI, built from a ship definition
// (Resources/Ships/<name>.json): flight params, guns and the primary weapon
// come from there, with the definition's AI variants for AI-flown ships.
@interface GFighter : NSObject {
@public
    ShipMoveState move;
    ShipParams params;
}
+ (instancetype)fighterWithShip:(NSString *)name ai:(BOOL)ai;   // nil if there is no such definition
@property (nonatomic) uint16_t number;
@property (nonatomic, readonly) const ShipDef *definition;
@property (nonatomic, readonly) ShipGun gun;      // the primary weapon as flown
@property (nonatomic, readonly) int model;
@property (nonatomic) int nameIndex;
@property (nonatomic, readonly) float radius;
@property (nonatomic) Team team;
@property (nonatomic) float hull, shield, laserEnergy;
@property (nonatomic) BOOL alive;
@property (nonatomic) double lastShot;
@property (nonatomic) double deathTime;
@property (nonatomic, weak) GClient *client;      // nil for AI ships
@property (nonatomic, readonly) simd_float3 lastGunLocal;

@property (nonatomic) simd_float3 position, velocity;
@property (nonatomic, readonly) simd_quatf orientation;
@property (nonatomic, readonly) simd_float3 forward, up, right;
@property (nonatomic, readonly) float boostEnergy;
@property (nonatomic, readonly) BOOL boosting;

- (void)resetAt:(simd_float3)position facing:(simd_quatf)orientation;
- (void)step:(ShipInput)input dt:(float)dt;
- (simd_float3)nextGunWorldPosition;
- (BOOL)takeDamage:(float)amount;   // YES if the shield took the hit
@end

#pragma mark - Capital

@interface GSubsystem : NSObject
@property (nonatomic) SubsystemKind kind;
@property (nonatomic) int part;                 // index in the model's parts
@property (nonatomic) float hp, maxHp;
@property (nonatomic) BOOL alive;
@property (nonatomic) simd_float3 local;        // centre, capital space
@property (nonatomic) simd_float3 muzzle;       // turrets: barrel direction, capital space
@property (nonatomic) double lastShot;
@end

// A capital ship, station, prop or rock. Follows an optional path, carries
// destroyable subsystems and is hit-tested against its mesh (gi.trace).
@interface GCapital : NSObject
+ (instancetype)capitalWithAsset:(NSString *)asset style:(NSString *)style team:(Team)team;
@property (nonatomic) uint16_t number;
@property (nonatomic, readonly) int model;
@property (nonatomic, copy) NSString *identifier, *asset, *group;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *cargo;
@property (nonatomic) BOOL scanned;
@property (nonatomic, readonly) NSString *className;
@property (nonatomic) Team team;
@property (nonatomic) float hull, maxHull;
@property (nonatomic, readonly) float radius;
@property (nonatomic, readonly) float scale;
@property (nonatomic) BOOL alive;
@property (nonatomic) BOOL hidden;              // not drawn (gone for good)
@property (nonatomic) BOOL invulnerable, noHullDamage;
@property (nonatomic) float stealthRange;
@property (nonatomic) BOOL isMine, isProp, isAsteroid, isBuoy;
@property (nonatomic) BOOL collected, departed;
@property (nonatomic, readonly) NSArray<GSubsystem *> *subsystems;
@property (nonatomic, readonly) uint64_t deadParts;

@property (nonatomic) simd_float3 position;
@property (nonatomic) simd_quatf orientation;
@property (nonatomic, readonly) simd_float3 velocity, forward;
@property (nonatomic, copy) NSArray<NSValue *> *path;
@property (nonatomic) float speed;
@property (nonatomic) BOOL loop;
@property (nonatomic, readonly) BOOL arrived;
@property (nonatomic) float spin;
@property (nonatomic) double deathTime;

- (void)setUniformScale:(float)scale;
- (void)update:(float)dt;
- (simd_float3)worldPoint:(simd_float3)local;
- (simd_float3)worldDirection:(simd_float3)local;
- (BOOL)shielded;
- (BOOL)enginesDead;
- (NSUInteger)aliveCount:(SubsystemKind)kind;
- (NSUInteger)totalCount:(SubsystemKind)kind;
- (BOOL)hitSegmentFrom:(simd_float3)a to:(simd_float3)b point:(simd_float3 *)point
             subsystem:(GSubsystem * __autoreleasing *)subsystem;
- (BOOL)damage:(float)amount subsystem:(GSubsystem *)subsystem;
@end

#pragma mark - Pilots, torpedoes, objectives, clients

// An AI-flown fighter: its ship, its team's orders, and its current target
// (a GFighter or a GCapital).
@interface GPilot : NSObject
@property (nonatomic, strong) GFighter *ship;
@property (nonatomic) AIMode mode;
@property (nonatomic) double modeUntil, retargetAt;
@property (nonatomic) simd_float3 evadePoint;
@property (nonatomic) float aimError;
@property (nonatomic, copy) NSString *order, *orderTarget, *wave, *callsign;
@property (nonatomic, weak) id target;
@end

@interface GTorpedo : NSObject
@property (nonatomic) uint16_t number;
@property (nonatomic) int model;                // "proj:<name>" configstring index
@property (nonatomic) simd_float3 position, velocity;
@property (nonatomic) float life;
@property (nonatomic) Team team;
@property (nonatomic, weak) GClient *owner;
@property (nonatomic, weak) id target;
@property (nonatomic, weak) GSubsystem *aim;
@end

@interface GClient : NSObject {
@public
    PlayerState ps;
}
@property (nonatomic) int index;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL inGame;
@property (nonatomic, strong) GFighter *ship;
@property (nonatomic) int kills, deaths, torpedoes;
@property (nonatomic, weak) id selected;
@property (nonatomic, weak) GSubsystem *aimSubsystem;
@property (nonatomic) double cmdTime, lastBump;     // seconds of commands run
@property (nonatomic, copy) NSString *status, *sentStatus;
@property (nonatomic, strong) GPilot *autopilot;    // g_autopilot
@end

#pragma mark - World

typedef struct {
    simd_float3 position, velocity;
    float life, damage, capDamage;
    Team team;
    __unsafe_unretained GClient *owner;  // cleared on disconnect; clients outlive bolts in practice
    uint16_t id;
    BOOL active;
} GBolt;

#define MAX_BOLTS 480

@interface GWorld : NSObject {
@public
    double _time;                       // game clock, advances TICK_DT per frame
    NSMutableArray<GClient *> *_clients;    // MAX_CLIENTS slots
    NSMutableArray<GPilot *> *_pilots;
    NSMutableArray<GCapital *> *_capitals;
    NSMutableArray<GTorpedo *> *_torpedoes;
    GBolt _bolts[MAX_BOLTS];
    uint16_t _nextBoltId;
    uint16_t _nextEntity;

    // Mission
    BOOL _running, _over;
    NSUInteger _missionIndex;
    NSDictionary *_mission;
    double _missionTime;
    MissionRunner *_runner;                 // objectives, events and rules (engine runtime)
    NSMutableDictionary<NSString *, NSDictionary *> *_held;   // "hold" entities and waves, by id, until spawned
    NSMutableDictionary<NSString *, NSValue *> *_navs;
    NSMutableDictionary<NSString *, NSString *> *_navNames;
    NSMutableArray<NSString *> *_navOrder;
    NSString *_currentNav;
    NSMutableArray *_explosionQueue;    // [time, GCapital, last] break-up sequences
    int _startTorpedoes;
    int _fighterClassNames[TeamCount];  // CS_STRINGS indices for "<faction> fighter"

    NSMutableData *_entityStates;
}
- (uint16_t)allocEntity;
- (NSArray<GFighter *> *)fighters;          // players' ships and AI ships
- (NSArray<GFighter *> *)playerShips;       // in-game clients' ships, alive or not
- (GFighter *)leadPlayer;                   // first in-game client's ship
- (void)buildEntityStates;
@end

extern GWorld *level;

@interface GWorld (Mission)
- (void)spawnMission:(NSUInteger)index;
- (void)clearWorld;
- (void)spawnPlayer:(GClient *)client;
- (void)updateMission:(float)dt;
- (NSArray *)unitsFor:(NSString *)name;      // by entity id, group, wave or callsign
- (simd_float3)navPosition:(NSString *)nav;
- (void)jumpFlashAt:(simd_float3)p scale:(float)scale;
@end

@interface GWorld (AI)
- (void)thinkPilot:(GPilot *)p dt:(float)dt;
- (void)fireTurrets:(GCapital *)c;
- (void)checkMine:(GCapital *)m;
@end

extern NSString *const GTorpedoProjectile;      // projectile definition the torpedo is drawn with

@interface GWorld (Weapons)
- (GBolt *)fireFrom:(simd_float3)pos velocity:(simd_float3)v direction:(simd_float3)dir speed:(float)speed life:(float)life
               team:(Team)team damage:(float)damage capDamage:(float)capDamage owner:(GClient *)owner;
- (void)muzzleFlash:(GFighter *)s;
- (void)damageShip:(GFighter *)s amount:(float)amount by:(GClient *)attacker shake:(float)shake;
- (void)updateBolts:(float)dt;
- (void)updateTorpedoes:(float)dt;
- (void)updateExplosions;
- (void)destroyCapital:(GCapital *)c;
- (void)collidePlayer:(GClient *)cl from:(simd_float3)before;
- (void)fireTorpedoFor:(GClient *)cl;
@end

@interface GWorld (Targeting)
- (void)cycleTargetFor:(GClient *)cl;
- (void)updateTargetingFor:(GClient *)cl;
- (BOOL)capital:(GCapital *)c visibleTo:(GFighter *)ship;
@end

// Generic accessors over the two kinds of things that fly.
static inline simd_float3 BodyPosition(id b) { return [b isKindOfClass:[GFighter class]] ? ((GFighter *)b).position : ((GCapital *)b).position; }
static inline simd_float3 BodyVelocity(id b) { return [b isKindOfClass:[GFighter class]] ? ((GFighter *)b).velocity : ((GCapital *)b).velocity; }
static inline float BodyRadius(id b) { return [b isKindOfClass:[GFighter class]] ? ((GFighter *)b).radius : ((GCapital *)b).radius; }
static inline BOOL BodyAlive(id b) {
    if (!b) return NO;
    if ([b isKindOfClass:[GFighter class]]) return ((GFighter *)b).alive;
    GCapital *c = b;
    return c.alive && !c.departed;
}
static inline Team BodyTeam(id b) { return [b isKindOfClass:[GFighter class]] ? ((GFighter *)b).team : ((GCapital *)b).team; }
static inline uint16_t BodyNumber(id b) { return [b isKindOfClass:[GFighter class]] ? ((GFighter *)b).number : ((GCapital *)b).number; }

static inline void GEvent(GameEvent e) { gi.event(&e); }
static inline void GCommand(GClient *to, int type, NSString *a, NSString *b, NSString *c) {
    gi.command(to ? to.index : -1, type, a.UTF8String ?: "", b.UTF8String ?: "", c.UTF8String ?: "");
}
