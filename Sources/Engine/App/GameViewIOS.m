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
    UITouch *_briefingTouch;
    __weak Briefing *_touchBriefing;
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

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)updateFlightControls {
    BOOL flying = [self.overlaySKScene isKindOfClass:HUD.class];
    [_flightControls updateController];
    [_flightControls showInHUD:flying ? self.overlaySKScene : nil];
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

- (CGPoint)fractionForPoint:(CGPoint)point {
    CGRect bounds = self.bounds;
    return CGPointMake((point.x - CGRectGetMinX(bounds)) / CGRectGetWidth(bounds),
                       1 - (point.y - CGRectGetMinY(bounds)) / CGRectGetHeight(bounds));
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    SKScene *overlay = self.overlaySKScene;
    if (![overlay isKindOfClass:Briefing.class]) {
        [super touchesBegan:touches withEvent:event];
        return;
    }
    if (_briefingTouch) return;
    _briefingTouch = touches.anyObject;
    _touchBriefing = (Briefing *)overlay;
    _touchStart = _touchLast = [_briefingTouch locationInView:self];
    _touchDragged = NO;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_briefingTouch) {
        [super touchesMoved:touches withEvent:event];
        return;
    }
    if (![touches containsObject:_briefingTouch] || _touchBriefing != self.overlaySKScene) return;
    CGPoint point = [_briefingTouch locationInView:self];
    if (!_touchDragged && hypot(point.x - _touchStart.x, point.y - _touchStart.y) < 8) return;
    _touchDragged = YES;
    if (CGRectContainsPoint(self.bounds, _touchStart)) {
        [_touchBriefing queueScrollBy:_touchLast.y - point.y atFraction:[self fractionForPoint:_touchStart]];
    }
    _touchLast = point;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    SKScene *overlay = self.overlaySKScene;
    UITouch *touch = touches.anyObject;
    if (_briefingTouch) {
        if (![touches containsObject:_briefingTouch]) return;
        touch = _briefingTouch;
        _briefingTouch = nil;
        if (_touchDragged || _touchBriefing != overlay) return;
    }
    if (![overlay respondsToSelector:@selector(queueClickAtFraction:)]) return;
    CGPoint point = [touch locationInView:self];
    if (!CGRectContainsPoint(self.bounds, point)) return;
    [(id)overlay queueClickAtFraction:[self fractionForPoint:point]];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_briefingTouch && [touches containsObject:_briefingTouch]) _briefingTouch = nil;
    [super touchesCancelled:touches withEvent:event];
}
@end
#endif
