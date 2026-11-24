#pragma once

#include <stdbool.h>
#include <stdint.h>

// The two transports share this small Quake-style envelope, not their
// application messages or their fragmentation/acknowledgment policy.
typedef struct {
    uint32_t sequence;
    uint32_t acknowledged;
    bool reliable;
    bool reliableAcknowledged;
    bool fragmented;
} DatagramHeader;

static inline uint32_t DatagramSequenceWord(uint32_t sequence, bool reliable, bool fragmented) {
    return (sequence & UINT32_C(0x3fffffff))
        | (reliable ? UINT32_C(0x80000000) : 0)
        | (fragmented ? UINT32_C(0x40000000) : 0);
}

static inline DatagramHeader DatagramDecodeHeader(uint32_t sequenceWord, uint32_t acknowledgmentWord) {
    DatagramHeader header = {
        .sequence = sequenceWord & UINT32_C(0x3fffffff),
        .acknowledged = acknowledgmentWord & UINT32_C(0x3fffffff),
        .reliable = (sequenceWord & UINT32_C(0x80000000)) != 0,
        .reliableAcknowledged = (acknowledgmentWord & UINT32_C(0x80000000)) != 0,
        .fragmented = (sequenceWord & UINT32_C(0x40000000)) != 0,
    };
    return header;
}

static inline uint32_t DatagramOutOfBandMarker(void) {
    return UINT32_C(0xffffffff);
}
