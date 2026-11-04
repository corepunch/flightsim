#import <SpriteKit/SpriteKit.h>
#import "Input.h"

typedef NS_ENUM(NSInteger, BriefingCommand) {
    BriefingCommandNone,
    BriefingCommandLaunch,      // fly selectedIndex
    BriefingCommandMainMenu,
};

// Full-screen campaign UI drawn over the 3D view: the mission list, the
// briefing for one mission (story text, objectives, intel, and a tactical
// map that steps through the briefing captions) and the debriefing.
@interface Briefing : SKScene

@property (nonatomic, readonly) NSUInteger selectedIndex;

- (void)showListSelecting:(NSUInteger)index;
- (void)showBriefing:(NSUInteger)index;
// results: one line per objective, prefixed "+" done, "x" failed, "-" not done.
- (void)showDebrief:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results;
- (void)queueClickAtFraction:(CGPoint)point;
- (BriefingCommand)handle:(InputAction)actions;
- (void)tick:(double)time;

@end
