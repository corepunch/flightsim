#import <Foundation/Foundation.h>
#import "NetTransport.h"
#include "GameAPI.h"

// Hosts the game module: implements its imports (configstrings, collision,
// events, commands), ticks it at TICK_RATE and sends every client in the
// game a delta-compressed snapshot per tick. Clients reach it through
// transports (loopback for the local player, UDP for others) and the same
// protocol either way.
@interface Server : NSObject

- (instancetype)initWithName:(NSString *)name;
- (void)addTransport:(id<NetTransport>)transport;

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) BOOL running;   // a mission is loaded
@property (atomic) BOOL loading;                // set while -spawnMission: runs; frame: does nothing
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly) int clientCount;
@property (nonatomic, readonly) BOOL missionEnded;   // the game has sent its debrief

// Loads a mission. Slow; call off the render thread with `loading` set.
// Every connected client gets the new gamestate and must begin again.
- (void)spawnMission:(int)missionIndex;
- (void)stop;

// Reads packets, runs whole ticks for the elapsed real time, sends snapshots.
- (void)frame:(double)dt;

@end
