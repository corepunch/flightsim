#import <Cocoa/Cocoa.h>
#import "Input.h"
#import "GameView.h"
#import "HUD.h"
#import "Cvar.h"
#import <math.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); return EXIT_FAILURE; } } while (0)
#define NEAR(a, b) (fabsf((a) - (b)) < 0.0001f)

// Keep the checks independent of any controller attached to the test Mac.
@interface CheckInput : Input
@end
@implementation CheckInput
- (void)startHID {}
@end

@interface CheckEvent : NSEvent
@property CGFloat wheelDelta, movementX, movementY;
@property BOOL precise, inverted;
@property NSEventPhase inertia;
@property NSInteger button;
@end
@implementation CheckEvent
- (CGFloat)scrollingDeltaY { return _wheelDelta; }
- (CGFloat)deltaX { return _movementX; }
- (CGFloat)deltaY { return _movementY; }
- (BOOL)hasPreciseScrollingDeltas { return _precise; }
- (BOOL)isDirectionInvertedFromDevice { return _inverted; }
- (NSEventPhase)momentumPhase { return _inertia; }
- (NSInteger)buttonNumber { return _button; }
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [Cvar set:@"in_throttle" value:@"0.4"];
        Input *input = [CheckInput new];
        GameView *view = [[GameView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 720)];
        view.input = input;
        view.overlaySKScene = [[HUD alloc] initWithSize:CGSizeMake(1280, 720)];
        input.mouseCaptured = YES;
        CheckEvent *event = [CheckEvent new];

        [input mouseMovedByX:160 y:-80];
        ControlState c = [input poll:1.0f / 60];
        CHECK(c.yaw > 0 && c.pitch > 0 && c.roll == 0);
        float pitch = c.pitch;
        [view rightMouseDown:event];
        c = [input poll:1.0f / 60];
        CHECK(c.yaw == 0 && c.roll == 0 && NEAR(c.pitch, pitch));
        event.movementX = 160;
        [view rightMouseDragged:event];
        [view mouseDown:event]; // simultaneous guns + roll
        c = [input poll:1.0f / 60];
        CHECK(c.roll > 0 && c.yaw == 0 && c.fire && NEAR(c.pitch, pitch));
        CHECK(NEAR([input poll:1.0f / 30].roll, c.roll)); // holds without more motion
        [view mouseUp:event];
        [view rightMouseUp:event];
        c = [input poll:1.0f / 60];
        CHECK(c.roll == 0 && c.yaw == 0 && !c.fire && NEAR(c.pitch, pitch));
        [input mouseMovedByX:-160 y:0];
        CHECK([input poll:1.0f / 60].yaw < 0);
        [view rightMouseDown:event];
        event.movementX = -160;
        [view rightMouseDragged:event];
        CHECK([input poll:1.0f / 60].roll < 0);

        // Only the wheel button centres the stick; the held roll mode survives.
        event.button = 3;
        [view otherMouseDown:event];
        CHECK([input poll:1.0f / 60].roll < 0);
        event.button = 2;
        [view otherMouseDown:event];
        c = [input poll:1.0f / 60];
        CHECK(c.pitch == 0 && c.yaw == 0 && c.roll == 0);
        [view rightMouseDragged:event];
        CHECK([input poll:1.0f / 60].roll < 0);

        event.wheelDelta = 1;
        [view scrollWheel:event];
        CHECK(NEAR([input poll:0].throttle, 0.45f));
        event.wheelDelta = -1;
        event.inverted = YES;
        [view scrollWheel:event];
        CHECK(NEAR([input poll:0].throttle, 0.5f)); // same physical forward movement
        event.inverted = NO;
        [view scrollWheel:event];
        CHECK(NEAR([input poll:0].throttle, 0.45f));
        event.precise = YES;
        event.wheelDelta = 20;
        [view scrollWheel:event];
        CHECK(NEAR([input poll:0].throttle, 0.5f));
        event.inertia = NSEventPhaseChanged;
        [view scrollWheel:event];
        CHECK(NEAR([input poll:0].throttle, 0.5f));
        event.inertia = NSEventPhaseNone;
        event.wheelDelta = 10000;
        [view scrollWheel:event];
        CHECK([input poll:0].throttle == 1);
        event.wheelDelta = -10000;
        [view scrollWheel:event];
        CHECK([input poll:0].throttle == 0);
        [input adjustMouseThrottleBy:NAN];
        CHECK([input poll:0].throttle == 0);

        [input setMouseFire:YES];
        [view releaseMouse];
        c = [input poll:0];
        CHECK(!input.mouseCaptured && !c.fire && c.roll == 0 && c.yaw == 0 && c.pitch == 0);
        [view rightMouseDown:event];
        [view scrollWheel:event];
        [input mouseMovedByX:160 y:80];
        input.mouseCaptured = YES;
        c = [input poll:0];
        CHECK(c.throttle == 0 && c.roll == 0 && c.yaw == 0 && c.pitch == 0);
        [input mouseMovedByX:160 y:0];
        CHECK([input poll:0].yaw > 0); // no stuck roll modifier after release
        [view rightMouseDown:event];
        [input setMouseFire:YES];
        [input mouseMovedByX:160 y:80];
        [input releaseAllKeys];
        c = [input poll:0];
        CHECK(!c.fire && c.roll == 0 && c.yaw == 0 && c.pitch == 0);
        input.mouseCaptured = NO;
        puts("PASS: mouse flight routing, roll transitions, fire, recenter, wheel direction, bounds and release.");
    }
    return EXIT_SUCCESS;
}
