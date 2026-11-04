#import <Cocoa/Cocoa.h>
#import "GameView.h"
#import "Host.h"
#import "FXRecorder.h"
#import "Server.h"
#import "UDPTransport.h"
#import "NetProtocol.h"
#import "Assets.h"
#import <QuartzCore/QuartzCore.h>

// Headless server: SpaceFight --dedicated [mission]. Flies the campaign from
// that mission on, moving to the next one ten seconds after each debrief.
static int RunDedicated(int mission) {
    Server *server = [[Server alloc] initWithName:[NSString stringWithFormat:@"%@ (dedicated)", NSHost.currentHost.localizedName ?: @"Server"]];
    UDPTransport *udp = [[UDPTransport alloc] initWithPort:PORT_SERVER attempts:4];
    if (!server || !udp) return 1;
    [server addTransport:udp];
    NSUInteger count = CampaignMissions().count;
    int index = MAX(0, MIN(mission, (int)count - 1));
    NSLog(@"Dedicated: mission %d, UDP port %d", index + 1, udp.port);
    [server spawnMission:index];
    double last = CACurrentMediaTime(), endedAt = 0;
    for (;;) {
        @autoreleasepool {
            double now = CACurrentMediaTime();
            [server frame:now - last];
            last = now;
            if (server.missionEnded && !endedAt) endedAt = now;
            if (endedAt && now - endedAt > 10) {
                endedAt = 0;
                index = (index + 1) % (int)count;
                NSLog(@"Dedicated: next mission %d", index + 1);
                [server spawnMission:index];
            }
            usleep(2000);
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
    [appMenu addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Kestrel Frontier" action:@selector(terminate:) keyEquivalent:@"q"];
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
    self.window.title = @"Kestrel Frontier";
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

    // Debug: SF_SNAPSHOT=/path/prefix saves a few frames and quits.
    const char *snap = getenv("SF_SNAPSHOT");
    if (snap) {
        NSString *prefix = @(snap);
        for (int i = 1; i <= 3; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((getenv("SF_SNAPGAP") ? atof(getenv("SF_SNAPGAP")) : 2.5) * i * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSImage *img = [view snapshot];
                CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [png writeToFile:[NSString stringWithFormat:@"%@%d.png", prefix, i] atomically:YES];
                if (i == 3) [NSApp terminate:nil];
            });
        }
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Offline effect preview: SpaceFight --record-fx <effect> <out.mp4> [seconds]
        if (argc >= 4 && !strcmp(argv[1], "--record-fx"))
            return [FXRecorder recordEffect:@(argv[2]) toFile:@(argv[3]) seconds:argc >= 5 ? atof(argv[4]) : 3.0];
        if (argc >= 2 && !strcmp(argv[1], "--dedicated"))
            return RunDedicated(argc >= 3 ? atoi(argv[2]) - 1 : 0);
        // SpaceFight --connect <host[:port]>: join that server after boot.
        if (argc >= 3 && !strcmp(argv[1], "--connect")) setenv("SF_CONNECT", argv[2], 1);

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
