#import "NetTransport.h"

// A non-blocking IPv4 UDP socket. Servers bind PORT_SERVER (or the next free
// port); clients bind any port. Broadcast is enabled for LAN discovery.
@interface UDPTransport : NSObject <NetTransport>

// port 0 picks any free port. Tries up to `attempts` consecutive ports.
- (instancetype)initWithPort:(int)port attempts:(int)attempts;
@property (nonatomic, readonly) int port;      // the one actually bound

- (void)broadcast:(NSData *)packet port:(int)port;   // to 255.255.255.255

@end
