#import <Foundation/Foundation.h>

// Where a packet goes: the in-process loopback, or an IP address and port.
@interface NetAddress : NSObject <NSCopying>
+ (instancetype)loopback:(int)port;                         // 0 = client side, 1 = server side
+ (instancetype)addressWithString:(NSString *)s port:(int)defaultPort;   // "host", "host:port", "loopback"
+ (instancetype)addressWithSockaddr:(const void *)sa length:(unsigned)len;
@property (nonatomic, readonly) BOOL isLoopback;
@property (nonatomic, readonly) int port;
@property (nonatomic, readonly) NSData *sockaddr;           // nil for loopback
@property (nonatomic, readonly) NSString *string;
@end

// Moves datagrams. Unreliable and unordered: NetChannel adds the rest.
@protocol NetTransport <NSObject>
- (void)send:(NSData *)packet to:(NetAddress *)to;
// Next waiting packet, or nil.
- (NSData *)receiveFrom:(NetAddress *__autoreleasing *)from;
@end

// Two in-memory queues, one per side, like Quake's loopback: packets are
// encoded and decoded exactly as over the network, just never leave the
// process. Thread-safe. The cvars net_loss (fraction dropped) and
// net_latency (round trip, ms) simulate a bad network, both ways.
@interface LoopbackTransport : NSObject <NetTransport>
+ (instancetype)side:(int)port;     // 0 client, 1 server
@end
