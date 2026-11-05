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
#if TARGET_OS_IOS
typedef UIEdgeInsets BriefingInsets;
#else
typedef NSEdgeInsets BriefingInsets;
#endif
@interface Briefing : SKScene
@property (nonatomic) BriefingInsets contentInsets;

@property (nonatomic, readonly) NSUInteger selectedIndex;

- (void)showListSelecting:(NSUInteger)index;
- (void)showBriefing:(NSUInteger)index;
- (void)showBriefing:(NSUInteger)index page:(NSUInteger)page;   // opens on a later page
// results: one line per objective, prefixed "+" done, "x" failed, "-" not done.
- (void)showDebrief:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results;
- (void)queueClickAtFraction:(CGPoint)point;
// Positive delta reveals text farther down; point is the wheel or drag origin.
- (void)queueScrollBy:(CGFloat)delta atFraction:(CGPoint)point;
// Pointer position for button hover; (-1, -1) when it leaves the view.
- (void)hoverAtFraction:(CGPoint)point;
- (BriefingCommand)handle:(InputAction)actions;
- (void)tick:(double)time;

@end
