#pragma once

#import <SceneKit/SceneKit.h>
#import <TargetConditionals.h>
#import "Input.h"

// MARK: - GameView

// SCNView that routes platform controls to Input and taps/clicks to the front end.
@interface GameView : SCNView
@property (nonatomic, strong) Input *input;
#if TARGET_OS_IOS
@property (nonatomic, readonly) UIView *flightControlsView;
- (void)setSecondaryLabel:(NSString *)label;   // the touch controls' secondary weapon button
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

#if TARGET_OS_IOS
- (void)displayLinkTick:(CADisplayLink *)link;
#endif

@end

// MARK: - TouchFlightControls

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#import <SpriteKit/SpriteKit.h>
#import "Input.h"

@interface TouchFlightControls : UIView
- (instancetype)initWithInput:(Input *)input;
- (void)showInHUD:(SKScene *)hud;
- (void)updateController;
- (void)cancelInput;
// The secondary weapon button's label, from the game's CS_SECONDARY_SHORT.
- (void)setSecondaryLabel:(NSString *)label;
@end
#endif
