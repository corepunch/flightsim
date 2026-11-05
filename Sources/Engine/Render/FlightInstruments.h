#import <SpriteKit/SpriteKit.h>
#import "Cockpit.h"

// Authored at 608 x 400; shared by the cockpit glass and chase-view HUD.
@interface TargetReadout : SKNode
- (instancetype)initWithPreview:(BOOL)preview;
- (void)setCompact:(BOOL)compact;
- (void)updateFrame:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count;
@end

// A hemisphere sensor: straight ahead/behind is centre; abeam is the rim.
@interface SensorScope : SKNode
- (instancetype)initRear:(BOOL)rear;
- (void)updateFrame:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count;
@end
