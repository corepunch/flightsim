#import <SpriteKit/SpriteKit.h>
#import "InputAction.h"

@class NetAddress, LANServer, Loading;

// What the front end may ask of the engine. The host implements it; the
// front end never touches the server, client, renderer or view.
@protocol UIServices <NSObject>
// Flies a level of the local campaign on our own server.
- (void)startLevel:(NSUInteger)index;
// Joins someone else's game; the host reports progress with -setBrowserStatus:.
- (void)joinServer:(NetAddress *)address;
// Backs out of a join that has not reached the game yet.
- (void)cancelJoin;
// Shows a screen once the current one has played its exit animation.
- (void)present:(SKScene *)screen;
// Plays an exit of `seconds` (e.g. the main menu powering down), then quits.
- (void)quitAfter:(NSTimeInterval)seconds;
// The slow drift through the sky behind see-through screens.
- (void)drawMenuBackdrop;
// Whether a LAN listing is our own listen server (left off the list).
- (BOOL)isOwnServer:(LANServer *)server;
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly, copy) NSString *connectedServer;   // a remote host we are on, or nil
@end

// The front end: main menu, campaign (mission list, briefing, debrief),
// server browser, and the campaign record. It decides which screen shows and
// what each choice does; the host only says when the menus are up and
// reports level and connection events.
@interface FrontEnd : NSObject

- (instancetype)initWithSize:(CGSize)size services:(id<UIServices>)services;

// The screen the menus show now (for the host's reveal after loading).
@property (nonatomic, readonly) SKScene *currentScreen;
@property (nonatomic, readonly) NSUInteger levelCount;

// Menus are up: handle this frame's actions on the current screen.
- (void)frame:(InputAction)actions;

- (void)showMainMenu;
- (void)showMissionsSelecting:(NSUInteger)index;
- (void)showBriefing:(NSUInteger)index page:(NSUInteger)page;
- (void)showBrowser;
// Set up after boot, without presenting: the main menu, with the mission
// list ready behind it.
- (void)prepareAfterBoot;

// Level events from the host.
- (void)fillLoadingCard:(Loading *)card level:(NSUInteger)index;
- (NSString *)bannerForLevel:(NSUInteger)index;
- (void)levelStarted:(NSUInteger)index remote:(BOOL)remote;
- (void)levelEnded:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results remote:(BOOL)remote;
// The level was left (aborted, restarted elsewhere, disconnected): back to the list.
- (void)levelLeft:(NSUInteger)index;

// Server browser lines.
- (void)setBrowserStatus:(NSString *)status;
- (void)setHostLine:(NSString *)line;

@end
