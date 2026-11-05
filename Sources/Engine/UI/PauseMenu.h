#import <SpriteKit/SpriteKit.h>
#import "InputAction.h"

typedef NS_ENUM(NSInteger, PauseCommand) {
    PauseCommandNone, PauseCommandResume, PauseCommandCamera, PauseCommandSound,
    PauseCommandRestart, PauseCommandMissions
};
@interface PauseMenu : SKScene
- (void)showRemote:(BOOL)remote cockpit:(BOOL)cockpit;
- (PauseCommand)handle:(InputAction)actions;
- (void)queueClickAtFraction:(CGPoint)point;
@end
