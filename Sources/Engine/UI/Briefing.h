#import <SpriteKit/SpriteKit.h>
#import "Input.h"
#import "BriefingRoom.h"

typedef NS_ENUM(NSInteger, BriefingCommand) {
    BriefingCommandNone,
    BriefingCommandLaunch,      // fly selectedIndex
};

// Full-screen campaign UI drawn over the 3D view: the mission list, the
// briefing for one mission (story text, objectives, intel, and a tactical
// map that steps through the briefing captions) and the debriefing.
@interface Briefing : SKScene

@property (nonatomic, readonly) NSUInteger selectedIndex;

// The briefing room's screen (BriefingRoom.presentation). When set, the
// dialogue and tactical briefing play in the room: their map is drawn on
// the screen and the overlay leaves the room visible. nil: flat layout.
@property (nonatomic, strong) SKScene *presentation;
// What the room should show now; read by the host every frame.
@property (nonatomic, readonly) BOOL inRoom;
@property (nonatomic, readonly) RoomShot roomShot;
@property (nonatomic, readonly) float roomLean;   // toward the speaker, -1..1

- (void)showListSelecting:(NSUInteger)index;
- (void)showBriefing:(NSUInteger)index;
// results: one line per objective, prefixed "+" done, "x" failed, "-" not done.
- (void)showDebrief:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results;
- (void)queueClickAtFraction:(CGPoint)point;
- (BriefingCommand)handle:(InputAction)actions;
- (void)tick:(double)time;

@end
