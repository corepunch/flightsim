#import <Foundation/Foundation.h>
#import "NetTransport.h"
#import "ClientView.h"
#import "Input.h"

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
@property (nonatomic, readonly) NSArray<NSString *> *configStrings;
@property (nonatomic, readonly) int missionIndex;
@property (nonatomic, readonly) NetAddress *serverAddress;

// All called on the thread that calls -readPackets.
@property (nonatomic, copy) void (^gamestateHandler)(void);       // precache, then -begin
@property (nonatomic, copy) void (^missionEndHandler)(BOOL success, NSArray<NSString *> *results);
@property (nonatomic, copy) void (^disconnectHandler)(NSString *reason);

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
