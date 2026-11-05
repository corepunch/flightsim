#import <SpriteKit/SpriteKit.h>

// Opaque full-screen overlay shown while a mission (or the game itself) is
// built on a background queue: title card, progress bar, status line and a
// rotating tip. Game drives it from the render loop with -tick:.
@interface Loading : SKScene

// kicker: small line above the title ("MISSION 03"), detail: line under it.
- (void)showTitle:(NSString *)title kicker:(NSString *)kicker detail:(NSString *)detail;
// progress 0..1; the bar eases toward it so coarse steps still look smooth.
- (void)setProgress:(float)progress status:(NSString *)status;
// YES once the displayed bar has caught up with a progress of 1.
@property (nonatomic, readonly) BOOL barFull;
// Opaque artwork under the outgoing menu while it animates into this card.
- (SKNode *)backdropWithSize:(CGSize)size;
// Host enables this only when the mission and the displayed bar are ready.
@property (nonatomic) BOOL readyToStart;
- (void)queueClickAtFraction:(CGPoint)fraction;
- (BOOL)consumeStartRequest;
// Fades the whole card out over `seconds`, starting at the next tick.
- (void)fadeOut:(double)seconds;
// YES while fading or after the fade finished.
@property (nonatomic, readonly) BOOL fading;
@property (nonatomic, readonly) BOOL faded;
- (void)tick:(double)time;

@end
