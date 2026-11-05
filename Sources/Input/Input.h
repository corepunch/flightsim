#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <TargetConditionals.h>

// MARK: - InputAction

typedef NS_OPTIONS(NSUInteger, InputAction) {
    InputActionToggleCamera = 1 << 0,
    InputActionSwapAxes     = 1 << 1,
    InputActionInvertThrottle = 1 << 2,
    InputActionInvertMouse  = 1 << 3,
    InputActionRestart      = 1 << 4,
    InputActionToggleHelp   = 1 << 5,
    InputActionUp           = 1 << 6,   // menus
    InputActionDown         = 1 << 7,
    InputActionLeft         = 1 << 8,
    InputActionRight        = 1 << 9,
    InputActionConfirm      = 1 << 10,  // Return / Enter / stick button 1
    InputActionBack         = 1 << 11,  // Esc (mouse free) / M / Backspace
    InputActionTarget       = 1 << 12,  // T / stick button 6: next target
    InputActionSecondary    = 1 << 13,  // G / stick button 5: launch the secondary weapon
    InputActionMultiplayer  = 1 << 14,  // N: the LAN game browser
};

// MARK: - ScreenInput

// Pointer input for front-end screens. The platform views (GameView,
// GameViewIOS) turn mouse and touch into these events and push them onto one
// queue, PointerQueue; the host drains it at the top of each frame and hands
// the events to the screen on show, on the frame's thread. Screens never see
// platform events and keep no queues or locks of their own.
//
// Positions are fractions of the view, origin bottom-left (the SpriteKit
// scene's space); (-1, -1) means the pointer left the view.
typedef NS_ENUM(int, PointerEventKind) {
    PointerEventHover,      // the pointer moved (mouse only)
    PointerEventDown,       // a press or touch began
    PointerEventClick,      // released where it went down, without dragging
    PointerEventScroll,     // wheel or a touch drag: `delta` points, + scrolls content up
};

typedef struct {
    PointerEventKind kind;
    CGPoint at;
    CGFloat delta;
} PointerEvent;

// What a screen implements to receive pointer events; every method is optional.
@protocol ScreenInput <NSObject>
@optional
- (void)pointerHover:(CGPoint)at;
- (void)pointerDown:(CGPoint)at;
- (void)pointerClick:(CGPoint)at;
- (void)pointerScroll:(CGFloat)delta at:(CGPoint)at;
@end

// Delivers one event to a screen, if it takes that kind.
static inline void ScreenInputDeliver(id screen, PointerEvent e) {
    if (![screen conformsToProtocol:@protocol(ScreenInput)]) return;
    id<ScreenInput> s = screen;
    switch (e.kind) {
        case PointerEventHover: if ([s respondsToSelector:@selector(pointerHover:)]) [s pointerHover:e.at]; break;
        case PointerEventDown: if ([s respondsToSelector:@selector(pointerDown:)]) [s pointerDown:e.at]; break;
        case PointerEventClick: if ([s respondsToSelector:@selector(pointerClick:)]) [s pointerClick:e.at]; break;
        case PointerEventScroll: if ([s respondsToSelector:@selector(pointerScroll:at:)]) [s pointerScroll:e.delta at:e.at]; break;
    }
}

// Many writers (the main thread's event handlers), one reader (the frame).
@interface PointerQueue : NSObject
- (void)push:(PointerEvent)event;
// Removes and returns everything queued, oldest first.
- (NSData *)drain;
@end

// MARK: - Input

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

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
- (void)setMouseRoll:(BOOL)down;     // hold to route horizontal mouse input to roll
- (void)adjustMouseThrottleBy:(float)delta;
- (void)recenterMouse;
- (void)releaseAllKeys;
#endif

- (ControlState)poll:(float)dt;
// Menu actions (keys, buttons) since the last call, as a set.
- (InputAction)consumeActions;

#if TARGET_OS_IOS
@property (nonatomic, readonly) BOOL mouseCaptured;
#else
@property (nonatomic) BOOL mouseCaptured;
@property (atomic, readonly, copy) NSString *axisDescription;
@property (atomic, readonly) BOOL throttleFromJoystick;
#endif
// Pointer events for front-end screens: the platform view pushes, the
// frame drains (see ScreenInput above).
@property (nonatomic, readonly) PointerQueue *pointer;
@property (atomic, readonly) CGPoint mouseStick;          // -1..1, for the HUD
@property (atomic, readonly, copy) NSString *joystickName; // nil if none

@end
