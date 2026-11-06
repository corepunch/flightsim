#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#include "Shared.h"

// MARK: - NetTransport

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

// MARK: - LANBrowser

@interface LANServer : NSObject
@property (nonatomic, strong) NetAddress *address;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) int players, maxPlayers;
@property (nonatomic, copy) NSString *levelName;   // nil: no level running
@property (nonatomic) double lastSeen;
@end

// Finds a declared Bonjour service and asks its resolved IPv4 addresses for
// game information. macOS also broadcasts to the default ports for legacy
// hosts; iOS uses unicast so it needs no multicast entitlement.
@interface LANBrowser : NSObject

- (instancetype)init;
@property (nonatomic, readonly) NSArray<LANServer *> *servers;   // newest replies, sorted by name
@property (atomic, readonly) BOOL discoveryFailed;

- (void)query:(NetAddress *)address;
- (void)poll;       // call every frame while browsing
- (void)stop;       // finishes Bonjour callbacks on the main thread

@end

// Publishes a specific Bonjour service; UDP gameplay remains unicast.
// Create only after the player chooses to host, release to stop advertising.
@interface LANAdvertisement : NSObject
- (instancetype)initWithName:(NSString *)name port:(int)port;
- (void)stop;
@property (atomic, readonly) BOOL failed;
@end

// MARK: - NetChannel

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

// MARK: - NetMsg

// Little-endian byte writer/reader for packets. Reads past the end return
// zero and set `overflow`, so a truncated packet can't crash the parser;
// callers check `overflow` once at the end.
@interface MsgWriter : NSObject
@property (nonatomic, readonly) NSMutableData *data;
@property (nonatomic, readonly) NSUInteger length;
- (void)u8:(uint8_t)v;
- (void)u16:(uint16_t)v;
- (void)u32:(uint32_t)v;
- (void)u64:(uint64_t)v;
- (void)i16:(int16_t)v;
- (void)f32:(float)v;
- (void)f64:(double)v;
- (void)vec3:(simd_float3)v;
- (void)quat:(simd_quatf)q;     // full precision
- (void)string:(NSString *)s;   // u16 length + UTF-8
- (void)bytes:(NSData *)d;
@end

@interface MsgReader : NSObject
- (instancetype)initWithData:(NSData *)data;
@property (nonatomic, readonly) BOOL overflow;
@property (nonatomic, readonly) NSUInteger remaining;
- (uint8_t)u8;
- (uint16_t)u16;
- (uint32_t)u32;
- (uint64_t)u64;
- (int16_t)i16;
- (float)f32;
- (double)f64;
- (simd_float3)vec3;
- (simd_quatf)quat;
- (NSString *)string;
- (NSData *)bytes:(NSUInteger)n;
- (NSData *)rest;
@end

// MARK: - NetProtocol

// The wire format between server and client: message ids, and how entity
// states (delta-compressed against a frame the client has), player states,
// events and user commands are written.

#define PORT_SERVER 27910
#define NET_TIMEOUT 10.0                // seconds without a packet before giving up
#define UPDATE_BACKUP 32                // frames of entity history kept for deltas

// Server to client.
enum {
    svc_nop = 1,
    svc_disconnect,         // string reason
    svc_gamestate,          // u32 spawn count; then configstrings, then svc_gamestate_done
    svc_configstring,       // u16 index, string
    svc_gamestate_done,     // u32 spawn count
    svc_command,            // u8 type, string a, b, c
    svc_frame,              // see WriteFrame
};

// Client to server.
enum {
    clc_nop = 1,
    clc_move,               // u32 delta frame (last frame received), u8 count, commands
    clc_stringcmd,          // string: "begin <spawncount>", "disconnect"
};

// Rounds every field to what goes over the wire, so the server diffs (and
// stores) exactly what the client will decode.
void QuantizeEntity(EntityState *e);
// Writes `to` as a change from `from` (NULL: a new entity). Writes nothing
// when nothing changed and `force` is NO.
void WriteDeltaEntity(MsgWriter *w, const EntityState *from, const EntityState *to, BOOL force);
// Writes the entity list `to` against baseline `from` (sorted by number).
void WritePacketEntities(MsgWriter *w, const EntityState *from, NSUInteger fromCount, const EntityState *to, NSUInteger toCount);
// Reads an entity list against baseline `from`; appends the result to `out`.
BOOL ReadPacketEntities(MsgReader *r, const EntityState *from, NSUInteger fromCount, NSMutableData *out);

void WritePlayerState(MsgWriter *w, const PlayerState *ps);
void ReadPlayerState(MsgReader *r, PlayerState *ps);

void WriteEvents(MsgWriter *w, const GameEvent *events, NSUInteger count);
NSData *ReadEvents(MsgReader *r);

// Stick axes go over the wire as 16-bit values; the client quantizes
// before using a command so its prediction runs on what the server runs.
void QuantizeUserCmd(UserCmd *c);
void WriteUserCmd(MsgWriter *w, const UserCmd *c);
void ReadUserCmd(MsgReader *r, UserCmd *c);

// MARK: - UDPTransport

// A non-blocking IPv4 UDP socket. Servers bind PORT_SERVER (or the next free
// port); clients bind any port. Broadcast is enabled for LAN discovery.
@interface UDPTransport : NSObject <NetTransport>

// port 0 picks any free port. Tries up to `attempts` consecutive ports.
- (instancetype)initWithPort:(int)port attempts:(int)attempts;
@property (nonatomic, readonly) int port;      // the one actually bound

- (void)broadcast:(NSData *)packet port:(int)port;   // to 255.255.255.255

@end
