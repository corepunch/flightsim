#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#include "GameAPI.h"
#import "CockpitFrame.h"

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

- (void)showBolt:(int)slot at:(simd_float3)position velocity:(simd_float3)velocity friendly:(BOOL)friendly;
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
// Mesh for the target hologram (OBJ space), or nil.
- (id)hologramForModel:(RefModel)model;
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
