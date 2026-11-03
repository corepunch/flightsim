#import "GameView.h"
#import <Carbon/Carbon.h>

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
    self.input.mouseCaptured = YES;
    [NSCursor hide];
    CGAssociateMouseAndMouseCursorPosition(false);
}

- (void)releaseMouse {
    if (!self.input.mouseCaptured) return;
    self.input.mouseCaptured = NO;
    [self.input setMouseFire:NO];
    CGAssociateMouseAndMouseCursorPosition(true);
    [NSCursor unhide];
}

- (void)keyDown:(NSEvent *)event {
    if (getenv("SF_SNAPSHOT")) return;  // debug snapshot runs ignore the keyboard
    if (event.keyCode == kVK_Escape) { [self releaseMouse]; return; }
    if (event.modifierFlags & NSEventModifierFlagCommand) { [super keyDown:event]; return; }
    [self.input keyDown:event];
}

- (void)keyUp:(NSEvent *)event { [self.input keyUp:event]; }
- (void)flagsChanged:(NSEvent *)event { [self.input flagsChanged:event]; }

- (void)mouseDown:(NSEvent *)event {
    if (!self.input.mouseCaptured) { [self captureMouse]; return; }
    [self.input setMouseFire:YES];
}
- (void)mouseUp:(NSEvent *)event { [self.input setMouseFire:NO]; }
- (void)rightMouseDown:(NSEvent *)event { [self.input recenterMouse]; }

- (void)mouseMoved:(NSEvent *)event { [self.input mouseMovedByX:event.deltaX y:event.deltaY]; }
- (void)mouseDragged:(NSEvent *)event { [self.input mouseMovedByX:event.deltaX y:event.deltaY]; }
- (void)rightMouseDragged:(NSEvent *)event { [self.input mouseMovedByX:event.deltaX y:event.deltaY]; }

@end
