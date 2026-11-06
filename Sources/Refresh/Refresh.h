#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import <SpriteKit/SpriteKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#include "Shared.h"

// MARK: - CockpitFrame

// What the client tells the cockpit and the HUD instruments each frame. No
// renderer types: the target preview is an opaque handle from
// -[Refresh previewForModel:].
#define COCKPIT_MAX_CONTACTS 24

typedef struct CockpitContact {
    simd_float3 local;          // position in player ship space (-Z forward), metres
    simd_quatf orientation;     // relative to the player ship
    float hull, shield, systems; // systems: surviving fitted subsystems; -1 when not fitted
    TeamRelation relation;      // to the player's team
    BOOL capital;               // a big ship or station (bigger scanner blip)
    BOOL shielded;              // capital with its shield generators up
    BOOL attacking;             // in an attack run on the player
    BOOL disabled;              // a fighter drifting with its systems down
    __unsafe_unretained id preview;           // Refresh preview handle for the target readout
    __unsafe_unretained NSString *name, *className, *cargo, *component;
} CockpitContact;

typedef struct CockpitFrame {
    float throttle, speed, maxSpeed, boostEnergy, hull, shield;
    float weaponEnergy, weaponShotEnergy;   // primary weapon capacitor and what one shot costs, 0..1
    float weaponRecharge, shieldRecharge;   // the ship's, as fractions of full per second; 0 shield: it has none
    float damageFlash;          // 0..1, decays after a hit
    BOOL boosting, firing, alive;
    float pitch, yaw, roll;     // stick deflection, -1..1
    int kills, deaths;
    double time;
    simd_float3 sun;            // toward the sun, player ship space (lights the target preview)
    int target;                 // index into the contacts, -1 for none
    float closingSpeed;         // towards the target, m/s
    BOOL lock;                  // lead marker under the boresight
    BOOL six;                   // someone attacking from behind
    float nearest;              // distance to the closest hostile, metres
    int secondary;              // secondary weapon rounds left
    __unsafe_unretained NSString *secondaryName;  // short name from the game ("TORP")
    __unsafe_unretained NSString *objective;     // current objective, for the status display
} CockpitFrame;

// MARK: - HUD

typedef struct CockpitContact CockpitContact;
typedef struct CockpitFrame CockpitFrame;

typedef struct {
    CGPoint boresight;      // where the guns converge, view points
    BOOL boresightVisible;
    CGPoint mouseStick;     // -1..1
    BOOL mouseCaptured;
    float throttle, boostEnergy, speed;
    BOOL boosting;
    int kills, deaths;
    BOOL playerDead;
    BOOL respawning;        // deathmatch; campaign death ends the mission
    CGPoint sun;            // projected light source, HUD points
    float sunVisibility;    // 0..1
    float deltaTime;        // seconds, for the lens exposure response
    float damageFlash;      // 0..1
    BOOL cockpit;           // gauges are on the cockpit displays instead
    int secondary, secondaryCapacity;       // secondary weapon rounds left and carried
    __unsafe_unretained NSString *secondaryName;   // its name, from the game ("TORPEDO")
    BOOL aimVisible;        // subsystem aim marker on the selected capital
    CGPoint aim;
    __unsafe_unretained NSString *status;   // under the boresight, e.g. "SCANNING 40%"
} HUDFrame;

typedef NS_ENUM(int, HUDKind) { HUDKindEnemy, HUDKindFriend, HUDKindNeutral, HUDKindNav };

typedef struct {
    CGPoint point;          // projected position (clamped to edge if off-screen)
    BOOL onScreen;
    float angle;            // arrow direction when off-screen
    float distance;
    float size;             // bracket size, points
    BOOL hasLead;
    CGPoint lead;
    float health;
    HUDKind kind;
    BOOL capital, selected;
    __unsafe_unretained NSString *label;
} HUDTarget;

#if TARGET_OS_IOS
typedef UIEdgeInsets HUDInsets;
#else
typedef NSEdgeInsets HUDInsets;
#endif
@interface HUD : SKScene
@property (atomic) HUDInsets contentInsets;
@property (nonatomic) BOOL touchLayout;
// For checks: the condition rows on the right, bottom up (hull, shield,
// laser), then the secondary rack above them.
@property (nonatomic, readonly) NSArray<SKNode *> *conditionRows;
@property (nonatomic, readonly) SKLabelNode *scoreLabel;
@property (nonatomic, readonly) BOOL helpVisible;
@property (nonatomic, readonly) CGRect helpRect;

- (void)updateFrame:(HUDFrame)frame targets:(const HUDTarget *)targets count:(NSUInteger)count;
- (void)updateInstruments:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count cockpit:(BOOL)cockpit;
- (void)setInputText:(NSString *)text;
- (void)toggleHelp;
- (void)setHelpVisible:(BOOL)visible;
// Objective lines; state per line: 0 active, 1 complete, 2 failed, 3 optional.
- (void)setObjectives:(NSArray<NSString *> *)lines states:(NSArray<NSNumber *> *)states;
- (void)showMessage:(NSString *)text from:(NSString *)from;
- (void)showBanner:(NSString *)text color:(SKColor *)color;
- (void)clearMessages;

@end

// MARK: - Refresh

// The renderer as the client sees it, after Quake 2's refexport_t: models are
// registered by name while a level loads, then every frame the client
// describes what is in view (entities, the player's ship, the camera) and
// fires effects. The backend owns the scene graph; the client never sees
// one. SceneKitRefresh is the only backend.
//
// Threads: -buildWorld, -beginRegistration:, -registerModel: and -upload:
// run on the load queue while nothing is drawn; everything else runs on the
// render thread.

typedef uint32_t RefModel;          // 0: none
#define REF_MAX_BOLTS 480           // bolt slots, 0..REF_MAX_BOLTS-1

// The pilot's eye in ship space: where the cockpit is mounted and the
// interior camera sits.
static const simd_float3 RefCockpitEye = {0, 1.0f, -2.2f};

// One entity in this frame's view, keyed by entity number.
typedef struct {
    uint16_t key;
    uint8_t kind;                   // EntityKind: how to draw a model that fails to load
    RefModel model;
    simd_float3 origin;
    simd_quatf orientation;         // ignored for projectiles (camera-facing glows)
    float scale;                    // 0 means 1
    uint64_t hiddenParts;           // destroyed subsystems, by part index
    float throttle, hull;           // ships: exhaust and damage smoke
    BOOL boost;
} RefEntity;

typedef struct {
    simd_float3 origin;
    simd_quatf orientation;         // looks down -Z
    float fov, zNear;               // degrees, metres; fov 0 keeps the current one
    float motionBlur;               // 0..1
    simd_float3 focus;              // what the sun's shadow map centres on
    simd_float3 velocity;           // viewer velocity, for the dust streaks
} RefCamera;

@protocol Refresh <NSObject>

#pragma mark Registration (load queue)

// Once: the boot sky, lights, camera, the player's ship rig, the cockpit and
// effect pools.
- (void)buildWorld;
// Starts a level: bakes its sky and forgets nothing yet; the current level
// keeps drawing until -endRegistration.
- (void)beginRegistration:(uint32_t)skySeed;
// "ship:<definition>", "cap:<asset>:<style>" or "proj:<name>". Builds and
// caches a prototype so entities that appear later are already on the GPU.
// The same name always gives the same handle; unknown names log and still
// get one (drawn as an empty node).
- (RefModel)registerModel:(NSString *)name;
// Uploads everything built since the last call to the GPU, reporting 0..1.
// Returns how many objects it uploaded.
- (NSUInteger)upload:(void (^)(float fraction))progress;

#pragma mark Level (render thread)

// Swaps in the sky from -beginRegistration: and an empty world.
- (void)endRegistration;
// Drops every entity, bolt and the player's view of the world.
- (void)clearWorld;

#pragma mark Frame (render thread)

- (void)beginFrame:(double)time;
- (void)addEntity:(const RefEntity *)entity;
// The player's own ship, drawn from the player state rather than a snapshot
// entity. NULL hides it (menus, death). `interior` swaps the hull for the
// cockpit.
- (void)setPlayer:(const RefEntity *)player alive:(BOOL)alive interior:(BOOL)interior;
- (void)setCamera:(RefCamera)camera;
// Removes entities not added since -beginFrame:.
- (void)endFrame;

#pragma mark Effects (render thread)

- (void)showBolt:(int)slot at:(simd_float3)position velocity:(simd_float3)velocity friendly:(BOOL)friendly ion:(BOOL)ion;
- (void)moveBolt:(int)slot to:(simd_float3)position;
- (void)hideBolt:(int)slot;
// `local` is in the entity's space; the key may be the player's.
- (void)muzzleFlashOn:(uint16_t)key local:(simd_float3)local friendly:(BOOL)friendly;
- (void)impactAt:(simd_float3)position friendly:(BOOL)friendly shielded:(BOOL)shielded;
// Debris takes the hull material of `model` when it has one.
- (void)explosionAt:(simd_float3)position velocity:(simd_float3)velocity model:(RefModel)model scale:(float)scale;
- (void)jumpFlashAt:(simd_float3)position scale:(float)scale;
- (void)flashShieldOn:(uint16_t)key;

#pragma mark Queries (render thread)

@property (nonatomic, readonly) CGSize viewSize;            // view points
@property (nonatomic, readonly) simd_float3 sunDirection;   // toward the sun
// Bounding radius at scale 1: the definition's for ships, the model's for capitals.
- (float)radiusOfModel:(RefModel)model;
// Parts and subsystems of a capital model; NULL for anything else.
- (const GameModelInfo *)infoForModel:(RefModel)model;
// The model as the world draws it (textures, hull styles), in ship space with
// -Z forward, for the target preview. The same object for every call with
// one model; clone it before changing it. nil for models with no shape.
- (id)previewForModel:(RefModel)model;
// World point to view points, origin bottom-left (the HUD's space). NO when
// behind the camera.
- (BOOL)projectPoint:(simd_float3)world to:(CGPoint *)out;
// YES when opaque geometry lies on the segment. Additive effects, glass and
// the dust don't count.
- (BOOL)traceOpaqueFrom:(simd_float3)from to:(simd_float3)to;

#pragma mark Cockpit (render thread)

- (void)updateCockpit:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count;
// Renders the cockpit displays; call before the frame renders.
- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time;

@end
