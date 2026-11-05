#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import "GameView.h"
#import "Briefing.h"
#import "HUD.h"
// Carbon's legacy EventType name overlaps the game protocol's event enum.
#define EventType CarbonEventType
#import <Carbon/Carbon.h>
#undef EventType

@implementation GameView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.window.acceptsMouseMovedEvents = YES;
    [self.window makeFirstResponder:self];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowLostFocus:)
                                                 name:NSWindowDidResignKeyNotification object:self.window];
}

- (void)windowLostFocus:(NSNotification *)n {
    [self releaseMouse];
    [self.input releaseAllKeys];
}

- (void)captureMouse {
    if (self.input.mouseCaptured) return;
    [self.input recenterMouse];
    self.input.mouseCaptured = YES;
    [NSCursor hide];
    CGAssociateMouseAndMouseCursorPosition(false);
}

- (void)releaseMouse {
    if (!self.input.mouseCaptured) return;
    self.input.mouseCaptured = NO;
    [self.input setMouseFire:NO];
    [self.input setMouseRoll:NO];
    [self.input recenterMouse];
    CGAssociateMouseAndMouseCursorPosition(true);
    [NSCursor unhide];
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == kVK_Escape && self.input.mouseCaptured) { [self releaseMouse]; return; }
    if (event.modifierFlags & NSEventModifierFlagCommand) { [super keyDown:event]; return; }
    [self.input keyDown:event];
}

- (void)keyUp:(NSEvent *)event { [self.input keyUp:event]; }
- (void)flagsChanged:(NSEvent *)event { [self.input flagsChanged:event]; }

- (void)setOverlaySKScene:(SKScene *)scene {
    if (![scene isKindOfClass:HUD.class]) [self releaseMouse];
    [super setOverlaySKScene:scene];
    // A new screen learns where the pointer already rests.
    NSPoint p = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    [self reportHoverAt:NSPointInRect(p, self.bounds) ? p : NSMakePoint(-1, -1)];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
          owner:self userInfo:nil]];
}

// Front-end screens light buttons under the pointer. view is in view points;
// (-1, -1) means the pointer has left.
- (void)reportHoverAt:(NSPoint)p {
    SKScene *overlay = self.overlaySKScene;
    if (![overlay respondsToSelector:@selector(hoverAtFraction:)]) return;
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    CGPoint fraction = CGPointMake(-1, -1);
    if (p.x >= 0 && p.y >= 0) {
        CGFloat x = (p.x - CGRectGetMinX(bounds)) / bounds.size.width;
        CGFloat y = (p.y - CGRectGetMinY(bounds)) / bounds.size.height;
        fraction = CGPointMake(x, self.isFlipped ? 1 - y : y);
    }
    [(id)overlay hoverAtFraction:fraction];
}

- (void)reportHover:(NSEvent *)event {
    if (self.input.mouseCaptured) return;
    [self reportHoverAt:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseExited:(NSEvent *)event { [self reportHoverAt:NSMakePoint(-1, -1)]; }

- (void)scrollWheel:(NSEvent *)event {
    SKScene *overlay = self.overlaySKScene;
    if ([overlay isKindOfClass:HUD.class] && self.input.mouseCaptured) {
        // Physical wheel forward increases thrust regardless of macOS's
        // natural scrolling setting. Ignore inertial trackpad scrolling.
        if (event.momentumPhase != NSEventPhaseNone) return;
        CGFloat delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1);
        [self.input adjustMouseThrottleBy:delta * (event.hasPreciseScrollingDeltas ? 0.0025f : 0.05f)];
        return;
    }
    if (![overlay isKindOfClass:Briefing.class]) {
        [super scrollWheel:event];
        return;
    }
    CGRect bounds = self.bounds;
    CGPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!CGRectContainsPoint(bounds, point)) return;
    CGFloat x = (point.x - CGRectGetMinX(bounds)) / CGRectGetWidth(bounds);
    CGFloat y = (point.y - CGRectGetMinY(bounds)) / CGRectGetHeight(bounds);
    CGFloat delta = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12);
    [(Briefing *)overlay queueScrollBy:delta atFraction:CGPointMake(x, self.isFlipped ? 1 - y : y)];
}

- (void)mouseDown:(NSEvent *)event {
    SKScene *overlay = self.overlaySKScene;
    if ([overlay respondsToSelector:@selector(queueClickAtFraction:)]) {
        CGPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        CGRect bounds = self.bounds;
        if (bounds.size.width > 0 && bounds.size.height > 0) {
            CGFloat x = (p.x - CGRectGetMinX(bounds)) / bounds.size.width;
            CGFloat y = (p.y - CGRectGetMinY(bounds)) / bounds.size.height;
            [(id)overlay queueClickAtFraction:CGPointMake(x, self.isFlipped ? 1 - y : y)];
        }
        return;
    }
    if (![overlay isKindOfClass:HUD.class]) return;
    if (!self.input.mouseCaptured) { [self captureMouse]; return; }
    [self.input setMouseFire:YES];
}
- (void)mouseUp:(NSEvent *)event { [self.input setMouseFire:NO]; }
- (void)rightMouseDown:(NSEvent *)event { [self.input setMouseRoll:YES]; }
- (void)rightMouseUp:(NSEvent *)event { [self.input setMouseRoll:NO]; }
- (void)otherMouseDown:(NSEvent *)event {
    if (event.buttonNumber == 2 && self.input.mouseCaptured) [self.input recenterMouse];
}

- (void)mouseMoved:(NSEvent *)event {
    [self reportHover:event];
    [self.input mouseMovedByX:event.deltaX y:event.deltaY];
}
- (void)mouseDragged:(NSEvent *)event {
    [self reportHover:event];
    [self.input mouseMovedByX:event.deltaX y:event.deltaY];
}
- (void)rightMouseDragged:(NSEvent *)event { [self.input mouseMovedByX:event.deltaX y:event.deltaY]; }
- (void)otherMouseDragged:(NSEvent *)event { [self.input mouseMovedByX:event.deltaX y:event.deltaY]; }

@end

#endif
