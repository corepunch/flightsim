#import <Cocoa/Cocoa.h>
#import "GameView.h"
#import "Game.h"
#import "FXRecorder.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) Game *game;
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
    [appMenu addItemWithTitle:@"Quit Space Fight" action:@selector(terminate:) keyEquivalent:@"q"];
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
    self.window.title = @"Space Fight";
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    [self.window center];

    self.input = [Input new];
    GameView *view = [[GameView alloc] initWithFrame:frame options:@{ SCNPreferredRenderingAPIKey : @(SCNRenderingAPIMetal) }];
    view.input = self.input;
    self.window.contentView = view;
    self.game = [[Game alloc] initWithView:view input:self.input];

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

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
