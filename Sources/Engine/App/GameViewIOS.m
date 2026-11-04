#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import "GameView.h"
#import "TouchFlightControls.h"
#import "HUD.h"
#import "MainMenu.h"
#import "Briefing.h"
#import "ServerBrowser.h"

@implementation GameView {
    TouchFlightControls *_flightControls;
}

- (void)setInput:(Input *)input {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_flightControls removeFromSuperview];
    _input = input;
    _flightControls = [[TouchFlightControls alloc] initWithInput:input];
    _flightControls.frame = self.bounds;
    _flightControls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.multipleTouchEnabled = YES;
    [self addSubview:_flightControls];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(controllerChanged:) name:InputControllerDidChangeNotification object:input];
    [nc addObserver:self selector:@selector(resignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(becomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [input setApplicationActive:UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
    [self updateFlightControls];
}

@synthesize input = _input;

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)updateFlightControls {
    BOOL flying = [self.overlaySKScene isKindOfClass:HUD.class];
    [_flightControls updateController];
    _flightControls.hidden = !flying;
    [_input setFlightInputActive:flying];
}

- (void)controllerChanged:(NSNotification *)note { [_flightControls updateController]; }

- (void)resignActive:(NSNotification *)note {
    [_input setApplicationActive:NO];
    [_flightControls cancelInput];
}

- (void)becomeActive:(NSNotification *)note {
    [_input setApplicationActive:YES];
    [_flightControls updateController];
}

- (void)setOverlaySKScene:(SKScene *)scene {
    [super setOverlaySKScene:scene];
    [self updateFlightControls];
    [self updateOverlayInsets];
}

- (void)updateOverlayInsets {
    SKScene *overlay = self.overlaySKScene;
    if ([overlay isKindOfClass:MainMenu.class]) ((MainMenu *)overlay).contentInsets = self.safeAreaInsets;
    if ([overlay isKindOfClass:HUD.class]) ((HUD *)overlay).contentInsets = self.safeAreaInsets;
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self updateOverlayInsets];
    [_flightControls setNeedsLayout];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    SKScene *overlay = self.overlaySKScene;
    if (![overlay respondsToSelector:@selector(queueClickAtFraction:)]) return;
    CGPoint point = [touches.anyObject locationInView:self];
    CGRect bounds = self.bounds;
    if (!CGRectContainsPoint(bounds, point)) return;
    CGPoint fraction = CGPointMake((point.x - CGRectGetMinX(bounds)) / CGRectGetWidth(bounds),
                                   1 - (point.y - CGRectGetMinY(bounds)) / CGRectGetHeight(bounds));
    [(id)overlay queueClickAtFraction:fraction];
}
@end
#endif
