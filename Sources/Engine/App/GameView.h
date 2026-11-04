#import <SceneKit/SceneKit.h>
#import "Input.h"

// SCNView that feeds keyboard and mouse into Input and captures the cursor
// (hidden + decoupled from the mouse) while flying with the mouse.
@interface GameView : SCNView
@property (nonatomic, strong) Input *input;
- (void)releaseMouse;
@end
