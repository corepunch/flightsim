#pragma once

#import <Foundation/Foundation.h>
#import "Input.h"
#import "Refresh.h"
#include "Shared.h"
#import "Net.h"

// MARK: - ClientView

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
- (void)predictedShotFrom:(simd_float3)pos velocity:(simd_float3)velocity gun:(simd_float3)gunLocal life:(float)life ion:(BOOL)ion;
- (void)serverCommand:(int)type a:(NSString *)a b:(NSString *)b c:(NSString *)c;

@end

// MARK: - Client

// One decoded server frame.
@interface Snapshot : NSObject
@property (nonatomic) uint32_t frame;
@property (nonatomic) double time;              // server time at the end of the tick
@property (nonatomic) PlayerState ps;
@property (nonatomic, copy) NSData *entities;   // EntityState[], sorted by number
@property (nonatomic, copy) NSData *events;     // GameEvent[] since the previous frame
@property (nonatomic, readonly) NSUInteger entityCount;
@property (nonatomic, readonly) const EntityState *entityStates;
@end

typedef NS_ENUM(NSInteger, ClientState) {
    ClientDisconnected,
    ClientConnecting,       // sending "connect" until the server answers
    ClientConnected,        // channel up; receiving or holding a gamestate
    ClientActive,           // begun: receiving snapshots
};

// The client side of a connection: keeps the configstrings, decodes
// snapshots and draws the world interpolated between them a little in the
// past, and turns input into user commands. Talks to the server only in
// packets, over loopback or the network.
@interface Client : NSObject

- (instancetype)initWithView:(ClientView *)view;

@property (nonatomic, readonly) ClientView *view;
@property (nonatomic, readonly) ClientState state;
@property (nonatomic) BOOL inputSuspended; // keep the connection alive without flight commands
@property (nonatomic, readonly) NSArray<NSString *> *configStrings;
@property (nonatomic, readonly) NSString *levelName;   // CS_LEVEL
@property (nonatomic, readonly) NetAddress *serverAddress;

// All called on the thread that calls -readPackets.
@property (nonatomic, copy) void (^gamestateHandler)(void);       // precache, then -begin
@property (nonatomic, copy) void (^missionEndHandler)(BOOL success, NSArray<NSString *> *results);
@property (nonatomic, copy) void (^disconnectHandler)(NSString *reason, BOOL remote);

- (void)connectTo:(NetAddress *)address transport:(id<NetTransport>)transport name:(NSString *)name;
- (void)disconnect;
- (void)begin;          // after precaching: ask the server for our ship
- (void)leaveGame;      // stop drawing snapshots (back at the menu); stay connected

// Per render frame: packets in, then input out (as a user command), then,
// after the local server (if any) has run, the interpolated world.
- (void)readPackets;
- (void)sendInput:(ControlState)controls actions:(InputAction)actions dt:(float)dt;
- (void)drawWithControls:(ControlState)controls time:(double)time dt:(float)dt;

@end
