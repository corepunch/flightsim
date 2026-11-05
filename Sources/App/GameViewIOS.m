#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import "App.h"
#import "App.h"
#import "Refresh.h"
#import "UI.h"
#import "UI.h"

@implementation GameView {
    TouchFlightControls *_flightControls;
    // The one touch a front-end screen is following: a tap becomes a click,
    // a drag becomes scrolling.
    UITouch *_screenTouch;
    CGPoint _touchStart, _touchLast;
    BOOL _touchDragged;
}

- (void)setInput:(Input *)input {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_flightControls removeFromSuperview];
    _input = input;
    _flightControls = [[TouchFlightControls alloc] initWithInput:input];
    _flightControls.frame = self.bounds;
    _flightControls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(controllerChanged:) name:InputControllerDidChangeNotification object:input];
    [nc addObserver:self selector:@selector(resignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(becomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [input setApplicationActive:UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
    [self updateFlightControls];
}

@synthesize input = _input;

- (UIView *)flightControlsView { return _flightControls; }
- (void)setSecondaryLabel:(NSString *)label { [_flightControls setSecondaryLabel:label]; }

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)updateFlightControls {
    BOOL flying = [self.overlaySKScene isKindOfClass:HUD.class];
    [_flightControls updateController];
    [_flightControls showInHUD:flying ? self.overlaySKScene : nil];
    [_input setFlightInputActive:flying];
}

- (void)controllerChanged:(NSNotification *)note { [_flightControls updateController]; }

- (void)resignActive:(NSNotification *)note {
    _screenTouch = nil;
    [_input setApplicationActive:NO];
    [_flightControls cancelInput];
}

- (void)becomeActive:(NSNotification *)note {
    [_input setApplicationActive:YES];
    [_flightControls updateController];
}

- (void)setOverlaySKScene:(SKScene *)scene {
    _screenTouch = nil;
    [super setOverlaySKScene:scene];
    [self updateFlightControls];
    [self updateOverlayInsets];
}

- (void)updateOverlayInsets {
    SKScene *overlay = self.overlaySKScene;
    if ([overlay isKindOfClass:MainMenu.class]) ((MainMenu *)overlay).contentInsets = self.safeAreaInsets;
    if ([overlay isKindOfClass:HUD.class]) ((HUD *)overlay).contentInsets = self.safeAreaInsets;
    if ([overlay isKindOfClass:Briefing.class]) ((Briefing *)overlay).contentInsets = self.safeAreaInsets;
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self updateOverlayInsets];
    [_flightControls setNeedsLayout];
}

- (CGPoint)fractionForPoint:(CGPoint)point {
    CGRect bounds = self.bounds;
    return CGPointMake((point.x - CGRectGetMinX(bounds)) / CGRectGetWidth(bounds),
                       1 - (point.y - CGRectGetMinY(bounds)) / CGRectGetHeight(bounds));
}

- (BOOL)screenShown { return [self.overlaySKScene conformsToProtocol:@protocol(ScreenInput)]; }

- (void)push:(PointerEventKind)kind at:(CGPoint)point delta:(CGFloat)delta {
    [_input.pointer push:(PointerEvent){ kind, [self fractionForPoint:point], delta }];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (![self screenShown]) {
        [super touchesBegan:touches withEvent:event];
        return;
    }
    if (_screenTouch) return;
    _screenTouch = touches.anyObject;
    _touchStart = _touchLast = [_screenTouch locationInView:self];
    _touchDragged = NO;
    [self push:PointerEventDown at:_touchStart delta:0];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_screenTouch) {
        [super touchesMoved:touches withEvent:event];
        return;
    }
    if (![touches containsObject:_screenTouch]) return;
    CGPoint point = [_screenTouch locationInView:self];
    if (!_touchDragged && PointDistance(point, _touchStart) < 8) return;
    _touchDragged = YES;
    if (CGRectContainsPoint(self.bounds, _touchStart)) [self push:PointerEventScroll at:_touchStart delta:_touchLast.y - point.y];
    _touchLast = point;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_screenTouch || ![touches containsObject:_screenTouch]) {
        if (!_screenTouch) [super touchesEnded:touches withEvent:event];
        return;
    }
    UITouch *touch = _screenTouch;
    _screenTouch = nil;
    CGPoint point = [touch locationInView:self];
    if (_touchDragged || ![self screenShown] || !CGRectContainsPoint(self.bounds, point)) return;
    [self push:PointerEventClick at:point delta:0];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_screenTouch && [touches containsObject:_screenTouch]) _screenTouch = nil;
    [super touchesCancelled:touches withEvent:event];
}
@end
#endif
