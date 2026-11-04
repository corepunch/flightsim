#pragma once
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#import "Input.h"

@interface TouchFlightControls : UIView
- (instancetype)initWithInput:(Input *)input;
- (void)updateController;
- (void)cancelInput;
@end
#endif
