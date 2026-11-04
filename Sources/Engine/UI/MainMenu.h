#import <SpriteKit/SpriteKit.h>
#import "InputAction.h"

#if TARGET_OS_IOS
typedef UIEdgeInsets MainMenuInsets;
#else
typedef NSEdgeInsets MainMenuInsets;
#endif

typedef NS_ENUM(NSInteger, MainMenuCommand) {
    MainMenuCommandNone,
    MainMenuCommandCampaign,
    MainMenuCommandMissions,
    MainMenuCommandMultiplayer,
    MainMenuCommandQuit,
};

@interface MainMenu : SKScene

// Insets are in scene points. When used as a SceneKit overlay, the host
// supplies its view's safe area. In a standalone SKView the scene reads it.
@property (atomic) MainMenuInsets contentInsets;

- (void)showMission:(NSUInteger)index title:(NSString *)title started:(BOOL)started completed:(BOOL)completed;
- (void)queueClickAtFraction:(CGPoint)point;
// Pointer position for button hover; (-1, -1) when it leaves the view.
- (void)hoverAtFraction:(CGPoint)point;
- (MainMenuCommand)handle:(InputAction)actions;
// Exit by switching off like a tube (for quitting). Returns its length.
- (NSTimeInterval)motionPowerDown;

@end
