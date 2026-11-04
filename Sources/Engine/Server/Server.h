#import <Foundation/Foundation.h>
#include "GameAPI.h"

// One tick's worth of world, as one client sees it.
@interface Snapshot : NSObject
@property (nonatomic) uint32_t frame;
@property (nonatomic) double time;              // server time at the end of the tick
@property (nonatomic) PlayerState ps;
@property (nonatomic, copy) NSData *entities;   // EntityState[], sorted by number
@property (nonatomic, copy) NSData *events;     // GameEvent[] since the previous snapshot
@property (nonatomic, readonly) NSUInteger entityCount;
@property (nonatomic, readonly) const EntityState *entityStates;
@end

// The receiving end of a connection, as the server sees it. Calls arrive on
// whichever thread called -[Server flush].
@protocol ServerClient <NSObject>
- (void)serverGamestate:(NSArray<NSString *> *)configStrings;
- (void)serverConfigString:(int)index value:(NSString *)value;
- (void)serverCommand:(int)type a:(NSString *)a b:(NSString *)b c:(NSString *)c;
- (void)serverSnapshot:(Snapshot *)snapshot;
@end

// Hosts the game module: implements its imports (configstrings, collision,
// events, commands), ticks it at TICK_RATE and sends every connected client
// a snapshot per tick.
@interface Server : NSObject

- (instancetype)init;

@property (nonatomic, readonly) BOOL running;   // a mission is loaded
@property (nonatomic, readonly) double time;

// Loads a mission. Slow; call off the render thread while nothing ticks.
// Connected clients get a new gamestate and must begin again.
- (void)spawnMission:(int)missionIndex;
- (void)stop;

- (int)connect:(id<ServerClient>)client name:(NSString *)name;   // slot, or -1
- (void)begin:(int)slot;
- (void)drop:(int)slot;
- (void)slot:(int)slot command:(const UserCmd *)cmd;

// Advances by real time: runs whole ticks and sends their snapshots.
- (void)frame:(double)dt;
// Delivers queued messages to the clients (frame: does this too).
- (void)flush;

@end
