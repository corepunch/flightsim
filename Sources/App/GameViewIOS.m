#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import "App.h"
#import "Refresh.h"
#import "UI.h"

@implementation GameView {
    SKView *_overlayView;
    TouchFlightControls *_flightControls;
    // The one touch a front-end screen is following: a tap becomes a click,
    // a drag becomes scrolling.
    UITouch *_screenTouch;
    CGPoint _touchStart, _touchLast;
    BOOL _touchDragged;
}

- (SKView *)overlayView {
    if (!_overlayView) {
        _overlayView = [[SKView alloc] initWithFrame:self.bounds];
        _overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _overlayView.allowsTransparency = YES;
        _overlayView.backgroundColor = UIColor.clearColor;
        _overlayView.asynchronous = NO;
        _overlayView.userInteractionEnabled = NO; // GameView routes taps through Input.
        _overlayView.preferredFramesPerSecond = 60;
        _overlayView.paused = YES;
    }
    return _overlayView;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    Cvar *ratio = [Cvar get:@"r_pixelRatio" defaultValue:@"2" flags:CVAR_ARCHIVE
                      help:@"3D pixels per view point; 0 uses native resolution (HUD stays native)"];
    CGFloat native = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    CGFloat scale = ratio.value > 0 ? MIN(native, MAX(1, ratio.value)) : native;
    if (self.contentScaleFactor != scale) self.contentScaleFactor = scale;
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
    BOOL flying = [self.overlayScene isKindOfClass:HUD.class];
    [_flightControls updateController];
    [_flightControls showInHUD:flying ? self.overlayScene : nil];
    [_input setFlightInputActive:flying];
}

- (void)controllerChanged:(NSNotification *)note { [_flightControls updateController]; }

- (void)resignActive:(NSNotification *)note {
    if (_screenTouch) [_input.pointer push:(PointerEvent){ .kind = PointerEventCancel }];
    _screenTouch = nil;
    [_input setApplicationActive:NO];
    [_flightControls cancelInput];
}

- (void)becomeActive:(NSNotification *)note {
    [_input setApplicationActive:YES];
    [_flightControls updateController];
}

- (void)setOverlayScene:(SKScene *)scene {
    _screenTouch = nil;
    // SceneKit's overlay renderer walks SpriteKit nodes on its render queue,
    // outside the main-thread cycle that also owns touch and focus updates.
    [self.overlayView presentScene:scene];
    [self updateFlightControls];
    [self updateOverlayInsets];
    BOOL keepAwake=[scene isKindOfClass:HUD.class] || [scene isKindOfClass:LANGame.class] || [scene isKindOfClass:ServerBrowser.class];
    // Hosting and discovery need foreground frames even while nobody taps.
    dispatch_async(dispatch_get_main_queue(), ^{ UIApplication.sharedApplication.idleTimerDisabled=keepAwake; });
}

- (SKScene *)overlayScene { return _overlayView.scene; }

- (UIImage *)snapshotWithOverlay {
    UIImage *world = [super snapshot];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:self.bounds];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [world drawInRect:self.bounds];
        [self.overlayView drawViewHierarchyInRect:self.bounds afterScreenUpdates:YES];
    }];
}

- (void)updateOverlayInsets { [self applySafeAreaTo:self.overlayScene]; }

- (void)applySafeAreaTo:(SKScene *)scene {
    UIEdgeInsets safe = self.safeAreaInsets;
    if ([scene isKindOfClass:PauseMenu.class]) ((PauseMenu *)scene).contentInsets = safe;
    if ([scene isKindOfClass:MainMenu.class]) ((MainMenu *)scene).contentInsets = safe;
    if ([scene isKindOfClass:HUD.class]) ((HUD *)scene).contentInsets = safe;
    if ([scene isKindOfClass:Briefing.class]) ((Briefing *)scene).contentInsets = safe;
    if ([scene isKindOfClass:ServerBrowser.class]) ((ServerBrowser *)scene).contentInsets = safe;
    if ([scene isKindOfClass:LANGame.class]) ((LANGame *)scene).contentInsets = safe;
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

- (BOOL)screenShown { return [self.overlayScene conformsToProtocol:@protocol(ScreenInput)]; }

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
    [self push:PointerEventDrag at:point delta:0];
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
    [self push:PointerEventUp at:point delta:0];
    if (_touchDragged || ![self screenShown] || !CGRectContainsPoint(self.bounds, point)) return;
    [self push:PointerEventClick at:point delta:0];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_screenTouch && [touches containsObject:_screenTouch]) [_input.pointer push:(PointerEvent){ .kind = PointerEventCancel }];
    if (_screenTouch && [touches containsObject:_screenTouch]) _screenTouch = nil;
    [super touchesCancelled:touches withEvent:event];
}
@end
#endif
