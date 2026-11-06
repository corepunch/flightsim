#import <Cocoa/Cocoa.h>
#import "Input.h"
#import "App.h"
#import "Refresh.h"
#import "UI.h"
#import "Common.h"
#import <math.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); return EXIT_FAILURE; } } while (0)
#define NEAR(a, b) (fabs((double)(a) - (double)(b)) < 0.0001)

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
@property NSPoint location;
@end
@implementation CheckEvent
- (CGFloat)scrollingDeltaY { return _wheelDelta; }
- (CGFloat)deltaX { return _movementX; }
- (CGFloat)deltaY { return _movementY; }
- (BOOL)hasPreciseScrollingDeltas { return _precise; }
- (BOOL)isDirectionInvertedFromDevice { return _inverted; }
- (NSEventPhase)momentumPhase { return _inertia; }
- (NSInteger)buttonNumber { return _button; }
- (NSPoint)locationInWindow { return _location; }
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

        FlightControls *settings = [FlightControls shared];
        [settings reset];
        [input mouseMovedByX:160 y:-80];
        ControlState c = [input poll:1.0f / 60];
        CHECK(c.yaw > 0 && c.pitch > 0 && c.roll == 0);
        float yaw = c.yaw, pitch = c.pitch;
        [view rightMouseDown:event];
        CHECK([input consumeActions] == InputActionSecondary);
        CHECK([input consumeActions] == 0); // a press launches once
        c = [input poll:0];
        CHECK(NEAR(c.yaw, yaw) && NEAR(c.pitch, pitch) && c.roll == 0);
        event.button = 2;
        [view otherMouseDown:event];
        CHECK([input consumeActions] == InputActionTarget);
        CHECK(NEAR([input poll:0].yaw, yaw)); // target selection never recentres
        event.button = 3;
        [view otherMouseDown:event];
        CHECK([input consumeActions] == 0);
        [view mouseDown:event];
        CHECK([input poll:0].fire);
        [view mouseUp:event];
        CHECK(![input poll:0].fire);

        settings.expert = YES;
        c = [input poll:0];
        CHECK(c.yaw == 0 && NEAR(c.roll, yaw) && NEAR(c.pitch, pitch));
        CHECK(NEAR([input poll:1.0f / 30].roll, c.roll));
        settings.horizontalSensitivity = 0.5;
        c = [input poll:0];
        CHECK(NEAR(c.roll, yaw * 0.5f) && NEAR(c.pitch, pitch));
        settings.verticalSensitivity = 1.5;
        CHECK(NEAR([input poll:0].pitch, pitch * 1.5f));
        settings.invertPitch = YES;
        CHECK(NEAR([input poll:0].pitch, -pitch * 1.5f));
        // Touch and controller use the same engine mapping, preserving their
        // separate roll stick, buttons, throttle and boost.
        ControlState stick = {.yaw=-0.4f, .pitch=0.3f, .roll=0.1f, .throttle=0.7f, .fire=YES, .boost=YES, .hat=-1};
        c = [settings applyTo:stick];
        CHECK(c.yaw == 0 && NEAR(c.roll, -0.1f) && NEAR(c.pitch, -0.45f));
        CHECK(c.throttle == stick.throttle && c.fire && c.boost && c.hat == -1);
        FlightControls *reloaded = [FlightControls new];
        CHECK(reloaded.expert && reloaded.invertPitch && NEAR(reloaded.horizontalSensitivity, 0.5f));
        CHECK([[NSUserDefaults.standardUserDefaults stringForKey:@"cvar.in_expert"] isEqualToString:@"1"]);
        settings.horizontalSensitivity = NAN;
        CHECK(settings.horizontalSensitivity == 1);
        settings.horizontalSensitivity = 100;
        settings.verticalSensitivity = -10;
        CHECK(settings.horizontalSensitivity == 2 && settings.verticalSensitivity == 0.25f);
        [settings reset];
        CHECK(!settings.expert && !settings.invertPitch && settings.horizontalSensitivity == 1 && settings.verticalSensitivity == 1);
        [view rightMouseDown:event];
        event.button = 2;
        [view otherMouseDown:event];
        CHECK([input consumeActions] == InputActionTarget);
        CHECK([input consumeActions] == InputActionSecondary);
        CHECK([input consumeActions] == 0);

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
        CHECK([input poll:0].yaw > 0); // steering resumes in Casual
        [view rightMouseDown:event];
        [input setMouseFire:YES];
        [input mouseMovedByX:160 y:80];
        [input releaseAllKeys];
        c = [input poll:0];
        CHECK(!c.fire && c.roll == 0 && c.yaw == 0 && c.pitch == 0);
        input.mouseCaptured = NO;

        // Front-end screens: the view only queues pointer events (ScreenInput, Input.h).
        [input.pointer drain];
        [view mouseDown:event];                       // the HUD takes no pointer events
        CHECK(input.pointer.drain.length == 0);
        view.overlaySKScene = [[PauseMenu alloc] initWithSize:CGSizeMake(1280, 720)];
        CheckEvent *at = [CheckEvent new];
        at.location = NSMakePoint(320, 360);
        [view mouseMoved:at];
        at.location = NSMakePoint(640, 180);
        [view mouseMoved:at];                          // successive hovers collapse
        [view mouseDown:at];
        at.wheelDelta = 3;
        [view scrollWheel:at];
        NSData *queued = input.pointer.drain;
        const PointerEvent *e = queued.bytes;
        CHECK(queued.length == 4 * sizeof(PointerEvent));
        CGFloat y = view.isFlipped ? 0.75 : 0.25;
        CHECK(e[0].kind == PointerEventHover && NEAR(e[0].at.x, 0.5) && NEAR(e[0].at.y, y));
        CHECK(e[1].kind == PointerEventDown && e[2].kind == PointerEventClick && NEAR(e[2].at.x, 0.5));
        CHECK(e[3].kind == PointerEventScroll && NEAR(e[3].delta, -36));
        CHECK(input.pointer.drain.length == 0);
        [view mouseDragged:at];
        [view mouseUp:at];
        queued = input.pointer.drain;
        e = queued.bytes;
        CHECK(queued.length == 3 * sizeof(PointerEvent));
        CHECK(e[0].kind == PointerEventDrag && e[1].kind == PointerEventHover && e[2].kind == PointerEventUp);
        puts("PASS: mouse flight modes, sensitivity, saved settings, weapons, wheel direction, bounds, release and screen pointer events.");
    }
    return EXIT_SUCCESS;
}
