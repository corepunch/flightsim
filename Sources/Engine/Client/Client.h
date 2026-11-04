#import <Foundation/Foundation.h>
#import "Server.h"
#import "ClientView.h"
#import "Input.h"

// The client side of a connection: keeps the configstrings, buffers
// snapshots and draws the world interpolated between them a little in the
// past, turns input into user commands and hands events and server commands
// to the view.
@interface Client : NSObject <ServerClient>

- (instancetype)initWithView:(ClientView *)view;

@property (nonatomic, readonly) ClientView *view;
@property (nonatomic, readonly) NSArray<NSString *> *configStrings;
@property (nonatomic, readonly) BOOL connected, inGame;
@property (nonatomic, readonly) int missionIndex;

// Called on the thread that delivered the gamestate (the server's flush).
@property (nonatomic, copy) void (^gamestateHandler)(void);
@property (nonatomic, copy) void (^missionEndHandler)(BOOL success, NSArray<NSString *> *results);

- (void)connectLocal:(Server *)server name:(NSString *)name;
- (void)disconnect;
- (void)begin;          // after precaching: ask the server for our ship

// Per render frame: first the input (as a user command), then, after the
// server has run, the interpolated world.
- (void)sendInput:(ControlState)controls actions:(InputAction)actions dt:(float)dt;
- (void)drawWithControls:(ControlState)controls time:(double)time dt:(float)dt;

@end
