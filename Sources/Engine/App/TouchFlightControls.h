#pragma once
#import <TargetConditionals.h>
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
