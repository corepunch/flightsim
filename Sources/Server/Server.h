#pragma once

#import <Foundation/Foundation.h>
#include "Shared.h"
#import "Net.h"

// MARK: - GameLoader

// Picks the game and finds its module.
//
// fs_game names a folder in the bundle's Games/ (default: the Info.plist's
// FSDefaultGame, else the first folder). GameLoaderSelectGame registers the
// cvar and points the file system at that folder; call it once at boot,
// after the command line's +set. GameLoaderOpen returns the game's
// GetGameAPI: on macOS from Contents/PlugIns/<game>.dylib (or its base's,
// for a game with no module of its own), on iOS the one module linked into the app.
NSString *GameLoaderSelectGame(void);
GetGameAPIFunc GameLoaderOpen(void);

// MARK: - Server

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
@property (atomic) BOOL loading;                // set while -spawnLevel: runs; frame: does nothing
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly) int clientCount;
@property (nonatomic, readonly) NSArray<NSString *> *clientNames;
@property (nonatomic) BOOL publicHosting;       // only explicit LAN sessions accept remote players
@property (nonatomic, readonly) BOOL missionEnded;   // the game has sent its debrief

// Loads a mission. Slow; call off the render thread with `loading` set.
// Every connected client gets the new gamestate and must begin again.
- (void)spawnLevel:(NSString *)name;
- (void)stop;
// Closes a hosted session and tells every peer immediately.
- (void)closeSession;

// Reads packets, runs whole ticks for the elapsed real time, sends snapshots.
- (void)frame:(double)dt;
// Keep networking alive without advancing the mission while the host waits
// for the player to dismiss its mission loading screen.
- (void)frame:(double)dt paused:(BOOL)paused;

@end
