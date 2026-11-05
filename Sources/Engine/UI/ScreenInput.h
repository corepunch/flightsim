#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

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
