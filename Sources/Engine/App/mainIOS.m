#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#import "GameView.h"
#import "Host.h"
#import "Cmd.h"
#import "GameLoader.h"

@interface FlightViewController : UIViewController
@end

@implementation FlightViewController
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@interface IOSSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) Host *host;
@property (nonatomic, strong) CADisplayLink *displayLink;
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
    // Keep raw flight touches separate from SceneKit gesture handling.
    [container addSubview:view.flightControlsView];
    FlightViewController *controller = [FlightViewController new];
    controller.view = container;
    self.window.rootViewController = controller;
    self.host = [[Host alloc] initWithView:view input:input];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self.host selector:@selector(displayLinkTick:)];
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    self.displayLink.paused = YES;
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self.window makeKeyAndVisible];
}

- (void)sceneDidBecomeActive:(UIScene *)scene { self.displayLink.paused = NO; }
- (void)sceneWillResignActive:(UIScene *)scene { self.displayLink.paused = YES; }
- (void)sceneDidDisconnect:(UIScene *)scene {
    [self.displayLink invalidate];
    self.displayLink = nil;
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
