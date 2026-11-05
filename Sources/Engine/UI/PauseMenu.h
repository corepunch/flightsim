#import <SpriteKit/SpriteKit.h>
#import "InputAction.h"
#import "ScreenInput.h"

typedef NS_ENUM(NSInteger, PauseCommand) {
    PauseCommandNone, PauseCommandResume, PauseCommandCamera, PauseCommandSound,
    PauseCommandRestart, PauseCommandMissions
};

// The in-flight pause menu, laid out by Resources/UI/menus/pause.json. Its
// buttons' ids map to commands: resume, camera, sound, restart, missions;
// other ids do nothing. Flags for "when": "online" (a remote game, where the
// mission keeps running) and "cockpit" (the cockpit camera is on).
@interface PauseMenu : SKScene <ScreenInput>
- (void)showRemote:(BOOL)remote cockpit:(BOOL)cockpit;
- (PauseCommand)handle:(InputAction)actions;
@end
