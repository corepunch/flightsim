#import <SpriteKit/SpriteKit.h>
#import "Input.h"
#import "LANBrowser.h"

typedef NS_ENUM(NSInteger, BrowserCommand) { BrowserCommandNone, BrowserCommandJoin, BrowserCommandBack };

// The multiplayer screen: games found on the local network, plus how to
// join one by address. Up/Down pick, Return joins, Esc goes back.
@interface ServerBrowser : SKScene

@property (nonatomic, readonly) LANServer *selected;
@property (nonatomic, copy) NSString *hostLine;     // "Hosting on port 27910", shown at the bottom

- (void)showServers:(NSArray<LANServer *> *)servers;
- (void)queueClickAtFraction:(CGPoint)point;
- (BrowserCommand)handle:(InputAction)actions;
- (void)setStatus:(NSString *)status;

@end
