#import <Foundation/Foundation.h>
#import "NetTransport.h"

@interface LANServer : NSObject
@property (nonatomic, strong) NetAddress *address;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) int players, maxPlayers;
@property (nonatomic) int missionIndex;     // -1: no mission running
@property (nonatomic) double lastSeen;
@end

// Finds servers on the local network: broadcasts "info" to PORT_SERVER (and
// the next few ports) every couple of seconds and collects the replies.
// Also asks any address given with -query: (direct IP).
@interface LANBrowser : NSObject

- (instancetype)init;
@property (nonatomic, readonly) NSArray<LANServer *> *servers;   // newest replies, sorted by name

- (void)query:(NetAddress *)address;
- (void)poll;       // call every frame while browsing

@end
