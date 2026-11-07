#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import "App.h"
#import "Story.h"
#import "App.h"
#import "Render.h"
#import "Server.h"
#import "Net.h"
#import "Net.h"
#import "Shared.h"
#import "Common.h"
#import "Common.h"
#import "Server.h"
#import "Common.h"
#import <QuartzCore/QuartzCore.h>

// Headless server: KestrelFrontier --dedicated [mission]. Flies the campaign from
// that mission on, moving to the next one ten seconds after each debrief.
// +map <n> on the command line (or from a cfg) changes the mission.
static int RunDedicated(int mission) {
    Server *server = [[Server alloc] initWithName:L10nFormat(@"net.dedicated_name", NSHost.currentHost.localizedName ?: L10n(@"net.default_server"))];
    int port = [Cvar get:@"net_port" defaultValue:[NSString stringWithFormat:@"%d", PORT_SERVER] flags:CVAR_NOSET
                    help:@"UDP port the server listens on"].integer;
    UDPTransport *udp = [[UDPTransport alloc] initWithPort:port > 0 ? port : PORT_SERVER attempts:4];
    if (!server || !udp) return 1;
    [server addTransport:udp];
    server.publicHosting = YES;
    __attribute__((objc_precise_lifetime)) LANAdvertisement *advertisement = [[LANAdvertisement alloc] initWithName:server.name port:udp.port];
    (void)advertisement;
    // Rotate through the campaign's levels, or every level in the game
    // folder when the game has no campaign.
    NSMutableArray<NSString *> *rotation = [NSMutableArray array];
    for (CampaignMission *entry in CampaignMissions()) [rotation addObject:entry.levelName];
    if (!rotation.count) [rotation addObjectsFromArray:LevelNames()];
    if (!rotation.count) { NSLog(@"Dedicated: game %@ has no levels", FSGame()); return 1; }
    NSUInteger count = rotation.count;
    __block NSUInteger index = (NSUInteger)MAX(0, MIN(mission, (int)count - 1));
    __block double endedAt = 0;
    [Cmd add:@"map" help:@"map <number or level name>: runs that level" handler:^(NSArray<NSString *> *a) {
        NSString *arg = a.count > 1 ? a[1] : @"";
        NSUInteger found = [rotation indexOfObject:arg];
        if (found == NSNotFound && arg.intValue >= 1 && (NSUInteger)arg.intValue <= count) found = (NSUInteger)arg.intValue - 1;
        if (found == NSNotFound) { NSLog(@"usage: map <1..%lu | level name>", (unsigned long)count); return; }
        index = found;
        endedAt = 0;
        NSLog(@"Dedicated: level %@", rotation[index]);
        [server spawnLevel:rotation[index]];
    }];
    [Cmd add:@"quit" help:@"Exits" handler:^(NSArray<NSString *> *a) { exit(0); }];
    NSLog(@"Dedicated: level %@, UDP port %d", rotation[index], udp.port);
    [server spawnLevel:rotation[index]];
    [Cmd executeLateCommands];
    double last = CACurrentMediaTime();
    for (;;) {
        @autoreleasepool {
            double now = CACurrentMediaTime();
            [Cmd executeBuffer];
            [server frame:now - last];
            last = now;
            if (server.missionEnded && !endedAt) endedAt = now;
            if (endedAt && now - endedAt > 10) {
                endedAt = 0;
                index = (index + 1) % count;
                NSLog(@"Dedicated: next level %@", rotation[index]);
                [server spawnLevel:rotation[index]];
            }
            usleep(2000);
            [NSRunLoop.currentRunLoop runUntilDate:NSDate.date];
        }
    }
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) Host *host;
@property (nonatomic, strong) Input *input;
@end

@implementation AppDelegate

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:L10n(@"app.full_screen") action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:L10nFormat(@"app.quit", L10n(@"game.title")) action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = bar;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self buildMenu];
    NSRect frame = NSMakeRect(0, 0, 1600, 900);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = L10n(@"game.title");
    self.window.contentMinSize = NSMakeSize(640, 360);
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    [self.window center];

    self.input = [Input new];
    GameView *view = [[GameView alloc] initWithFrame:frame options:@{ SCNPreferredRenderingAPIKey : @(SCNRenderingAPIMetal) }];
    view.input = self.input;
    self.window.contentView = view;
    self.host = [[Host alloc] initWithView:view input:self.input];

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Console: KestrelFrontier +set <cvar> <value> ... +map 3 / +connect host / +exec file.cfg.
        // Sets apply now, before any module registers its cvars; the rest
        // once the game has booted.
        [Cmd setArguments:NSProcessInfo.processInfo.arguments];
        [Cmd executeEarlyCommands];
        GameLoaderSelectGame();
        // Offline effect preview: KestrelFrontier --record-fx <effect> <out.mp4> [seconds]
        if (argc >= 4 && !strcmp(argv[1], "--record-fx"))
            return [FXRecorder recordEffect:@(argv[2]) toFile:@(argv[3]) seconds:argc >= 5 ? atof(argv[4]) : 3.0];
        if (argc >= 2 && !strcmp(argv[1], "--dedicated"))
            return RunDedicated(argc >= 3 && argv[2][0] != '+' ? atoi(argv[2]) - 1 : 0);

        // AppKit can abort during startup if the launcher cannot reach WindowServer.
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();
        if (!session) {
            fprintf(stderr, "%s\n", L10nFormat(@"app.needs_desktop", L10n(@"game.title")).UTF8String);
            return EXIT_FAILURE;
        }
        CFRelease(session);
        // One ship in a window: KestrelFrontier --preview-ship <ship> [game]
        if (argc >= 3 && !strcmp(argv[1], "--preview-ship"))
            return [ShipPreview runWithShip:@(argv[2]) game:argc >= 4 && argv[3][0] != '+' ? @(argv[3]) : nil];

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}

#endif
