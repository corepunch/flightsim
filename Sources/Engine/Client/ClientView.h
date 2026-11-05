#import <Foundation/Foundation.h>
#import "Input.h"
#import "HUD.h"
#import "Refresh.h"
#include "Protocol.h"

// What the client shows: it turns the current (interpolated) frame, the
// player state and events into renderer calls through <Refresh> (entities,
// the player's ship, bolts, effects, the camera) and fills the HUD and
// cockpit. It knows nothing about gameplay or the scene graph; it draws
// models at coordinates and dresses them by the flags the server sends.
@interface ClientView : NSObject

- (instancetype)initWithRefresh:(id<Refresh>)refresh input:(Input *)input;

@property (nonatomic, readonly) id<Refresh> refresh;
@property (nonatomic, readonly) HUD *hud;
@property (nonatomic) BOOL cockpit;
@property (atomic, copy) NSArray<NSString *> *configStrings;   // set on the render thread, read while precaching

// Load queue: registers the mission's sky and models, from configstrings.
// The caller uploads them with -[Refresh upload:].
- (void)loadMissionAssets:(void (^)(float fraction))progress;
// Render thread: swap in what -loadMissionAssets: registered.
- (void)attachMission;
// Render thread: drop every entity view, bolt and projectile.
- (void)clearMission;

- (void)menuFrame:(double)time;
- (void)drawEntities:(const EntityState *)entities count:(NSUInteger)count player:(const PlayerState *)ps
            controls:(ControlState)controls time:(double)time dt:(float)dt;
- (void)handleEvent:(const GameEvent *)event player:(const PlayerState *)ps;
#if TARGET_OS_IOS
- (void)weaponFired;
#endif
// Own ship under prediction: its bolts and muzzle flashes are drawn when the
// player fires, and the server's copies of them are matched up, not redrawn.
@property (nonatomic) uint16_t predictedEntity;
- (void)predictedShotFrom:(simd_float3)pos velocity:(simd_float3)velocity gun:(simd_float3)gunLocal life:(float)life;
- (void)serverCommand:(int)type a:(NSString *)a b:(NSString *)b c:(NSString *)c;

@end
