#import <SpriteKit/SpriteKit.h>

// Which screen is up, and the change from one to the next: the outgoing
// screen plays its exit (UIMotionScene) before the next one is installed; if
// another change arrives meanwhile, the newest wins. Frame thread only.
@interface ScreenHost : NSObject

// `install` puts a screen on the view (the host hops to the main thread) and
// then removes `cover` (a backdrop that hid the gap) from the old one.
- (instancetype)initWithScreen:(SKScene *)first install:(void (^)(SKScene *screen, SKNode *cover))install;

@property (nonatomic, readonly) SKScene *shown;
// YES while a screen is playing its exit; input should be held back.
@property (nonatomic, readonly) BOOL changing;

// `cover`, if given, is added under the outgoing screen's content so it stays
// opaque while that content animates away (e.g. the loading card's art).
- (void)present:(SKScene *)next cover:(SKNode *)cover time:(double)now;
// Runs `then` after `seconds` of exit animation, on a later -pump:.
- (void)after:(NSTimeInterval)seconds then:(void (^)(void))then time:(double)now;
// Call once per frame.
- (void)pump:(double)now;

@end
