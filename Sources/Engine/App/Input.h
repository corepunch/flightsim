#import <TargetConditionals.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif
#import "InputAction.h"

typedef struct {
    float pitch;     // +1 nose up
    float yaw;       // +1 nose right
    float roll;      // +1 right wing down
    float throttle;  // 0..1
    BOOL boost;
    BOOL fire;
    int hat;         // -1 centred, 0..7 clockwise from up
} ControlState;

#if TARGET_OS_IOS
extern NSNotificationName const InputControllerDidChangeNotification;
#endif

// Desktop HID/keyboard/mouse or mobile touch/GameController. Events are
// received on the main thread and consumed on the render thread.
@interface Input : NSObject

#if TARGET_OS_IOS
- (void)setTouchStick:(CGPoint)stick; // +x yaw right, +y nose up
- (void)setTouchThrottle:(float)value;
- (void)setTouchFire:(BOOL)down;
- (void)queueTouchAction:(InputAction)action;
- (void)cancelTouchInput;            // releases spring controls and pending actions
- (void)setFlightInputActive:(BOOL)active;
- (void)setApplicationActive:(BOOL)active;
@property (atomic, readonly) float currentThrottle;
#else
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;
- (void)flagsChanged:(NSEvent *)event;
- (void)mouseMovedByX:(CGFloat)dx y:(CGFloat)dy;
- (void)setMouseFire:(BOOL)down;
- (void)recenterMouse;
- (void)releaseAllKeys;
#endif

- (ControlState)poll:(float)dt;
- (InputAction)consumeActions;

#if TARGET_OS_IOS
@property (nonatomic, readonly) BOOL mouseCaptured;
#else
@property (nonatomic) BOOL mouseCaptured;
@property (atomic, readonly, copy) NSString *axisDescription;
@property (atomic, readonly) BOOL throttleFromJoystick;
#endif
@property (atomic, readonly) CGPoint mouseStick;          // -1..1, for the HUD
@property (atomic, readonly, copy) NSString *joystickName; // nil if none

@end
