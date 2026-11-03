#import <Cocoa/Cocoa.h>

typedef struct {
    float pitch;     // +1 nose up
    float yaw;       // +1 nose right
    float roll;      // +1 right wing down
    float throttle;  // 0..1
    BOOL boost;
    BOOL fire;
    int hat;         // -1 centred, 0..7 clockwise from up
} ControlState;

typedef NS_OPTIONS(NSUInteger, InputAction) {
    InputActionToggleCamera = 1 << 0,
    InputActionSwapAxes     = 1 << 1,
    InputActionInvertThrottle = 1 << 2,
    InputActionInvertMouse  = 1 << 3,
    InputActionRestart      = 1 << 4,
    InputActionToggleHelp   = 1 << 5,
};

// Merges a HID joystick (IOKit, so generic flight sticks work, not only
// GameController-compatible pads), the keyboard and a mouse "virtual stick".
// Event handlers run on the main thread, -poll: on the render thread.
@interface Input : NSObject

- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;
- (void)flagsChanged:(NSEvent *)event;
- (void)mouseMovedByX:(CGFloat)dx y:(CGFloat)dy;
- (void)setMouseFire:(BOOL)down;
- (void)recenterMouse;
- (void)releaseAllKeys;

- (ControlState)poll:(float)dt;
- (InputAction)consumeActions;

@property (nonatomic) BOOL mouseCaptured;
@property (atomic, readonly) CGPoint mouseStick;          // -1..1, for the HUD
@property (atomic, readonly, copy) NSString *joystickName; // nil if none
@property (atomic, readonly, copy) NSString *axisDescription;
@property (atomic, readonly) BOOL throttleFromJoystick;

@end
