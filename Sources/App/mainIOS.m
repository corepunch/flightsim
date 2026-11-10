#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#import "App.h"
#import "Common.h"
#import "Server.h"

@interface FlightViewController : UIViewController
@end

@implementation FlightViewController
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@interface IOSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) Host *host;
@property (nonatomic, strong) GameView *gameView;
@end

@implementation IOSSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    Input *input = [Input new];
    GameView *view = [[GameView alloc] initWithFrame:self.window.bounds
                                           options:@{SCNPreferredRenderingAPIKey: @(SCNRenderingAPIMetal)}];
    view.input = input;
    UIView *container = [[UIView alloc] initWithFrame:self.window.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:view];
    [container addSubview:view.overlayView];
    FlightViewController *controller = [FlightViewController new];
    controller.view = container;
    self.window.rootViewController = controller;
    self.host = [[Host alloc] initWithView:view input:input];
    self.gameView = view;
    [self.window makeKeyAndVisible];
}

// Both render loops (and the frame update riding on SceneKit's) stop while the
// app is inactive or backgrounded, so a forgotten simulator or device draws nothing.
- (void)setRendering:(BOOL)on {
    GameView *view = self.gameView;
    view.overlayView.paused = !on;
    view.rendersContinuously = on;
    view.playing = on;
}

- (void)sceneDidBecomeActive:(UIScene *)scene { [self setRendering:YES]; }
- (void)sceneWillResignActive:(UIScene *)scene { [self setRendering:NO]; }
- (void)sceneDidDisconnect:(UIScene *)scene {
    [self setRendering:NO];
    self.gameView.overlayView.delegate = nil;
}
@end

@interface IOSAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation IOSAppDelegate
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Console: +set <cvar> <value> ... +map 3 as scheme or simctl launch
        // arguments. Sets apply now; the rest once the game has booted.
        [Cmd setArguments:NSProcessInfo.processInfo.arguments];
        [Cmd executeEarlyCommands];
        GameLoaderSelectGame();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(IOSAppDelegate.class));
    }
}
#endif
