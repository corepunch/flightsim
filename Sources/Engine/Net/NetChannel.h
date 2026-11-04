#import <Foundation/Foundation.h>
#import "NetTransport.h"

// Sequenced packets over an unreliable transport, after Quake 2's netchan:
// every packet carries its sequence and the last sequence received, and one
// block of reliable data rides along until the other side acknowledges it.
// Unreliable data (snapshots, user commands) is sent once. Packets bigger
// than the MTU are split into fragments (as in Quake 3) and reassembled;
// losing one fragment loses the packet.
@interface NetChannel : NSObject

- (instancetype)initWithTransport:(id<NetTransport>)transport address:(NetAddress *)address;

@property (nonatomic, readonly) NetAddress *address;
@property (nonatomic, readonly) id<NetTransport> transport;
@property (nonatomic, readonly) uint32_t outgoingSequence, incomingSequence, incomingAcknowledged;
@property (nonatomic) double lastReceived, lastSent;      // CACurrentMediaTime
@property (nonatomic, readonly) BOOL hasPendingReliable;
@property (nonatomic, readonly) NSUInteger droppedPackets;
@property (nonatomic) NSUInteger bytesSent, packetsSent;   // datagrams, headers included

- (void)queueReliable:(NSData *)message;
- (void)transmit:(NSData *)unreliable;
// Returns the payload (reliable then unreliable messages), or nil for a
// duplicate, stale or incomplete packet.
- (NSData *)process:(NSData *)packet;

// Connectionless ("out of band") packets: 0xFFFFFFFF then text.
+ (void)sendOutOfBand:(NSString *)text transport:(id<NetTransport>)t to:(NetAddress *)to;
+ (NSString *)outOfBandText:(NSData *)packet;   // nil if not out of band

@end
