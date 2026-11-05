#import <SceneKit/SceneKit.h>
#import "Input.h"

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
