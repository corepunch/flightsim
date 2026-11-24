#ifndef ARCLINE_RACE_AUTHORITY_H
#define ARCLINE_RACE_AUTHORITY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    ARC_AUTHORITY_VERSION = 4,
    ARC_AUTHORITY_INPUT_TAG = 15, /* reserved for the authoritative transport */
    ARC_AUTHORITY_INPUT_BYTES = 22,
    ARC_AUTHORITY_MAX_CARS = 8,
    ARC_AUTHORITY_HZ = 60,
    ARC_AUTHORITY_STALE_TICKS = 15
};

typedef struct {
    float steer, throttle, brake;
    bool handbrake;
} ArcControls;

typedef struct {
    uint8_t car_id, peer_id;
    bool is_bot;
} ArcRaceSeat;

typedef struct {
    uint8_t car_id;
    float position[3], orientation[4], velocity[3];
    float progress, steer;
    bool boosting;
} ArcHostPose;

typedef struct {
    uint8_t car_id;
    uint32_t applied_sequence; /* 0 if no human input applied */
    ArcControls controls;
    bool is_bot;
} ArcControlFrame;

typedef struct {
    ArcHostPose pose;
    uint32_t applied_sequence;
    uint32_t finish_tick; /* 0 if not finished */
    bool connected;
} ArcSnapshotCar;

typedef struct {
    uint64_t race_id;
    uint32_t tick;
    size_t count;
    ArcSnapshotCar cars[ARC_AUTHORITY_MAX_CARS];
} ArcRaceSnapshot;

typedef struct {
    ArcRaceSeat seat;
    ArcControls controls;
    uint32_t received_sequence, received_tick, applied_sequence, finish_tick;
    bool connected;
} ArcAuthoritySeat;

typedef struct {
    ArcAuthoritySeat seats[ARC_AUTHORITY_MAX_CARS];
    float finish_progress;
    uint32_t tick;
    uint64_t race_id;
    size_t count;
    bool tick_open;
} ArcAuthority;

/* Zero-initialize ArcAuthority before first use. Call all functions serially, from the
   simulation owner. Create a fresh nonzero race_id
   per race. Peer IDs come from an established lobby connection, never from the packet. */
bool arc_authority_start(ArcAuthority *race, uint64_t race_id, float track_length,
                         uint8_t laps, const ArcRaceSeat *seats, size_t count);

/* Fixed-size little-endian input only: version, tag, flags, race ID, sequence,
   signed steer, unsigned throttle, unsigned brake. No car ID, time, pose, or finish.
   Encoding clamps finite values; intake independently clamps out-of-range wire values. */
bool arc_authority_encode_input(uint8_t packet[ARC_AUTHORITY_INPUT_BYTES],
                                uint64_t race_id, uint32_t sequence, ArcControls controls);
bool arc_authority_receive(ArcAuthority *race, uint8_t peer_id, const uint8_t *packet, size_t size);
void arc_authority_disconnect(ArcAuthority *race, uint8_t peer_id);

/* On the authoritative host only: apply this tick's controls before SceneKit physics,
   then submit exactly one complete set of trusted post-physics samples before publishing.
   Never call end_tick from a network handler. No simulated vehicle model in this module. */
bool arc_authority_begin_tick(ArcAuthority *race, ArcControlFrame output[ARC_AUTHORITY_MAX_CARS]);
bool arc_authority_end_tick(ArcAuthority *race, const ArcHostPose *poses, size_t count,
                            ArcRaceSnapshot *output);
#endif
