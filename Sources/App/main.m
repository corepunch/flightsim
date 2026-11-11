#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import "App.h"
#import "Story.h"
#import "UI.h"
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
    view.antialiasingMode = SCNAntialiasingModeNone;
    view.input = self.input;
    self.window.contentView = view;
    self.host = [[Host alloc] initWithView:view input:self.input];

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

@end

// Runs the production views on sample data in a resizable SpriteKit window,
// without a game session: KestrelFrontier --preview-ui [debrief|failed|end|match|pause|online]
@interface UIPreviewScene : SKScene
@property (nonatomic, copy) NSString *sample;
@end

@implementation UIPreviewScene {
    SKNode *_controls;
}

// Sample data only: the views are the ones the screens use.
static ReportModel *PreviewReport(NSString *sample) {
    if ([sample isEqualToString:@"end"]) return CampaignEndReport(31, 36, 2480);
    if ([sample isEqualToString:@"match"]) {
        LANMatchResult result = { .pilots = @[@"Wren", @"Halcyon", @"Tobin", @"A pilot with a very long callsign"],
                                  .scores = { {12, 3}, {9, 5}, {9, 5}, {2, 11} }, .localIndex = 1 };
        return MatchReport(result, 1240, LANMatchPilotPoints(result));
    }
    BOOL success = ![sample isEqualToString:@"failed"];
    return DebriefReport((DebriefFacts){
        .success = success, .stars = 2, .total = 1240, .earned = 100,
        .summary = success ? @"Both freighters reached Halden Gate. The bombers broke off before the corridor closed."
                           : @"The convoy was lost before it reached Halden Gate.",
        .results = MissionResultReadouts(@[
            @"+ Keep Mira and Tobin intact",
            @"- Escort both freighters to Halden Gate and stay within scanner range until the convoy clears the corridor.",
            @"x Destroy the Talon bombers (optional)",
        ]),
    });
}

- (void)didMoveToView:(SKView *)view {
    self.backgroundColor = UIColorWithOpacity(UIBackground, 1);
    [self layoutControls];
}

- (void)didChangeSize:(CGSize)oldSize { [self layoutControls]; }

- (void)layoutControls {
    if (!self.view) return;
    const CGFloat margin = 24;
    [_controls removeFromParent];
    _controls = [[UIReportView alloc] initWithReport:PreviewReport(_sample) width:MAX(1, self.size.width - 2 * margin)
                                             compact:self.size.width < 500];
    _controls.position = CGPointMake(margin, self.size.height - margin);
    [self addChild:_controls];
}
@end

@interface UIPreviewDelegate : NSObject <NSApplicationDelegate, SKSceneDelegate>
@property (nonatomic, copy) NSString *sample;
@end

@implementation UIPreviewDelegate {
    NSWindow *_window;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    CGRect rect = CGRectMake(0, 0, 560, 450);
    _window = [[NSWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Kestrel Frontier UI Preview";
    _window.contentMinSize = CGSizeMake(280, 300);
    SKView *view = [[SKView alloc] initWithFrame:rect];
    SKScene *scene;
    if ([@[@"pause", @"online"] containsObject:_sample ?: @""]) {
        PauseMenu *pause = [[PauseMenu alloc] initWithSize:rect.size];
        pause.backgroundColor = UIColorWithOpacity(UIBackground, 1);
        [pause showRemote:[_sample isEqualToString:@"online"] cockpit:NO];
        pause.delegate = self;
        scene = pause;
    } else {
        UIPreviewScene *report = [[UIPreviewScene alloc] initWithSize:rect.size];
        report.sample = _sample;
        scene = report;
    }
    scene.scaleMode = SKSceneScaleModeResizeFill;
    _window.contentView = view;
    [view presentScene:scene];
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
// The pause menu lays out again when its size changes, as it does under the host.
- (void)update:(NSTimeInterval)time forScene:(SKScene *)scene { [(PauseMenu *)scene handle:0]; }
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
        if (argc >= 4 && !strcmp(argv[1], "--render-scene"))
            return [SceneCapture renderFile:@(argv[2]) toFile:@(argv[3])
                                      size:argc >= 6 ? CGSizeMake(atoi(argv[4]), atoi(argv[5])) : CGSizeMake(2622, 1206)];
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
        id<NSApplicationDelegate> delegate = [AppDelegate new];
        if (argc >= 2 && !strcmp(argv[1], "--preview-ui")) {
            UIPreviewDelegate *preview = [UIPreviewDelegate new];
            if (argc >= 3 && argv[2][0] != '+') preview.sample = @(argv[2]);
            delegate = preview;
        }
        app.delegate = delegate;
        [app run];
    }
    return 0;
}

#endif
