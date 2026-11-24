#import "Net.h"
#include "PacketCore/DatagramHeader.h"
#import <QuartzCore/QuartzCore.h>

#define FRAGMENT_SIZE 1200          // payload per datagram; safe under typical MTUs
#define MAX_RELIABLE 4000           // one reliable block

@implementation NetChannel {
    uint32_t _reliableSequence;             // bit: toggles for each new reliable block
    uint32_t _lastReliableSequence;         // outgoing sequence after the block was last sent
    uint32_t _incomingReliableAcknowledged; // bit
    uint32_t _incomingReliableSequence;     // bit
    NSMutableData *_reliable;               // in flight
    NSMutableArray<NSData *> *_pending;     // queued behind it

    uint32_t _fragmentSequence;
    NSMutableData *_fragments;
}

- (instancetype)initWithTransport:(id<NetTransport>)transport address:(NetAddress *)address {
    if ((self = [super init])) {
        _transport = transport;
        _address = address;
        _outgoingSequence = 1;
        _reliable = [NSMutableData data];
        _pending = [NSMutableArray array];
        _fragments = [NSMutableData data];
        _lastReceived = CACurrentMediaTime();
    }
    return self;
}

- (BOOL)hasPendingReliable { return _reliable.length > 0 || _pending.count > 0; }

- (void)queueReliable:(NSData *)message {
    if (message.length) [_pending addObject:[message copy]];
}

- (void)transmit:(NSData *)unreliable {
    // Resend the reliable block if the other side has acknowledged a packet
    // sent after it without flipping the reliable bit: it was lost.
    BOOL sendReliable = (_incomingAcknowledged > _lastReliableSequence && _incomingReliableAcknowledged != _reliableSequence);
    if (!_reliable.length && _pending.count) {
        while (_pending.count && (!_reliable.length || _reliable.length + _pending[0].length <= MAX_RELIABLE)) {
            [_reliable appendData:_pending[0]];
            [_pending removeObjectAtIndex:0];
        }
        _reliableSequence ^= 1;
        sendReliable = YES;
    }

    uint32_t seq = _outgoingSequence++;
    uint32_t w2 = DatagramSequenceWord(_incomingSequence, _incomingReliableSequence, false);
    NSMutableData *payload = [NSMutableData data];
    if (sendReliable) {
        [payload appendData:_reliable];
        _lastReliableSequence = _outgoingSequence;
    }
    if (unreliable) [payload appendData:unreliable];
    _lastSent = CACurrentMediaTime();

    if (payload.length <= FRAGMENT_SIZE) {
        MsgWriter *w = [MsgWriter new];
        [w u32:DatagramSequenceWord(seq, sendReliable, false)];
        [w u32:w2];
        [w bytes:payload];
        [_transport send:w.data to:_address];
        _bytesSent += w.length;
        _packetsSent++;
        return;
    }
    // Fragments: every one but the last is full, so a short one ends the
    // packet (an empty one if the payload is an exact multiple).
    for (NSUInteger start = 0;; start += FRAGMENT_SIZE) {
        NSUInteger len = MIN((NSUInteger)FRAGMENT_SIZE, payload.length - start);
        MsgWriter *w = [MsgWriter new];
        [w u32:DatagramSequenceWord(seq, sendReliable, true)];
        [w u32:w2];
        [w u16:(uint16_t)start / FRAGMENT_SIZE];
        [w u16:(uint16_t)len];
        [w bytes:[payload subdataWithRange:NSMakeRange(start, len)]];
        [_transport send:w.data to:_address];
        _bytesSent += w.length;
        _packetsSent++;
        if (len < FRAGMENT_SIZE) break;
    }
}

- (NSData *)process:(NSData *)packet {
    MsgReader *r = [[MsgReader alloc] initWithData:packet];
    uint32_t w1 = [r u32], w2 = [r u32];
    if (r.overflow) return nil;
    DatagramHeader header = DatagramDecodeHeader(w1, w2);
    uint32_t seq = header.sequence;
    NSData *payload;

    if (header.fragmented) {
        uint16_t index = [r u16], len = [r u16];
        NSData *chunk = [r bytes:len];
        if (r.overflow) return nil;
        if (seq != _fragmentSequence) {
            _fragmentSequence = seq;
            _fragments.length = 0;
        }
        if ((NSUInteger)index * FRAGMENT_SIZE != _fragments.length) return nil;   // a fragment went missing
        [_fragments appendData:chunk];
        if (len == FRAGMENT_SIZE) return nil;                                    // more to come
        payload = [_fragments copy];
        _fragments.length = 0;
    } else {
        payload = [r rest];
    }

    if (seq <= _incomingSequence) return nil;   // duplicate or out of order
    _droppedPackets += seq - _incomingSequence - 1;
    if (header.reliableAcknowledged == _reliableSequence) _reliable.length = 0;   // our block arrived
    _incomingSequence = seq;
    _incomingAcknowledged = header.acknowledged;
    _incomingReliableAcknowledged = header.reliableAcknowledged;
    if (header.reliable) _incomingReliableSequence ^= 1;
    _lastReceived = CACurrentMediaTime();
    return payload;
}

+ (void)sendOutOfBand:(NSString *)text transport:(id<NetTransport>)t to:(NetAddress *)to {
    MsgWriter *w = [MsgWriter new];
    [w u32:DatagramOutOfBandMarker()];
    [w bytes:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [t send:w.data to:to];
}

+ (NSString *)outOfBandText:(NSData *)packet {
    if (packet.length < 4 || *(const uint32_t *)packet.bytes != DatagramOutOfBandMarker()) return nil;
    return [[NSString alloc] initWithData:[packet subdataWithRange:NSMakeRange(4, packet.length - 4)] encoding:NSUTF8StringEncoding];
}

@end
