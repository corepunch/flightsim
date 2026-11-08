#pragma once

#import <SceneKit/SceneKit.h>
#import <TargetConditionals.h>
#import "Input.h"

// MARK: - GameView

// SCNView that routes platform controls to Input and taps/clicks to the front end.
@interface GameView : SCNView
@property (nonatomic, strong) Input *input;
#if TARGET_OS_IOS
// SpriteKit owns the overlay's main-thread update and draw cycle separately
// from SceneKit's background rendering queue.
@property (nonatomic, readonly) SKView *overlayView;
@property (nonatomic, strong) SKScene *overlayScene;
- (UIImage *)snapshotWithOverlay;   // main thread: captures both rendering views
// Gives a front-end screen or the HUD this view's safe area. Main thread.
- (void)applySafeAreaTo:(SKScene *)scene;
#else
- (void)releaseMouse;
#endif
@end

// MARK: - Host

// The application loop: boots the renderer, runs the menus and loading
// screens, and in a mission drives the local server and client each frame
// (input -> server ticks -> interpolated draw).
@interface Host : NSObject <SCNSceneRendererDelegate>

- (instancetype)initWithView:(SCNView *)view input:(Input *)input;

@end

