#include "RaceAuthority.h"

#include <math.h>
#include <string.h>

static float clamp(float x, float lo, float hi)
{
    return x < lo ? lo : (x > hi ? hi : x);
}

static uint64_t read_le(const uint8_t *p, unsigned n)
{
    uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i)
        v |= (uint64_t)p[i] << (8 * i);
    return v;
}

static void write_le(uint8_t *p, unsigned n, uint64_t v)
{
    for (unsigned i = 0; i < n; ++i)
        p[i] = (uint8_t)(v >> (8 * i));
}

bool arc_authority_start(ArcAuthority *race, uint64_t id, float length, uint8_t laps,
                         const ArcRaceSeat *seats, size_t count)
{
    float finish = length * laps;
    if (!race || !id || id == race->race_id || !seats || !count || count > ARC_AUTHORITY_MAX_CARS ||
        !isfinite(finish) || length <= 0 || laps == 0 || laps > 5)
        return false;

    for (size_t i = 0; i < count; ++i) {
        if (!seats[i].is_bot && !seats[i].peer_id)
            return false;
        for (size_t j = 0; j < i; ++j) {
            if (seats[i].car_id == seats[j].car_id ||
                (!seats[i].is_bot && !seats[j].is_bot && seats[i].peer_id == seats[j].peer_id))
                return false;
        }
    }

    *race = (ArcAuthority){.count = count, .race_id = id, .finish_progress = finish};
    for (size_t i = 0; i < count; ++i) {
        race->seats[i].seat = seats[i];
        race->seats[i].connected = true;
    }
    return true;
}

bool arc_authority_encode_input(uint8_t p[ARC_AUTHORITY_INPUT_BYTES], uint64_t race_id,
                                uint32_t sequence, ArcControls c)
{
    if (!p || !race_id || !sequence ||
        !isfinite(c.steer) || !isfinite(c.brake) || !isfinite(c.throttle))
        return false;

    write_le(p, 2, ARC_AUTHORITY_VERSION);
    p[2] = ARC_AUTHORITY_INPUT_TAG;
    p[3] = c.handbrake ? 1 : 0;
    write_le(p + 4, 8, race_id);
    write_le(p + 12, 4, sequence);
    int32_t steer = (int32_t)roundf(clamp(c.steer, -1, 1) * 1000);
    write_le(p + 16, 2, (uint16_t)steer);
    write_le(p + 18, 2, (uint16_t)roundf(clamp(c.throttle, 0, 1) * 1000));
    write_le(p + 20, 2, (uint16_t)roundf(clamp(c.brake, 0, 1) * 1000));
    return true;
}

bool arc_authority_receive(ArcAuthority *race, uint8_t peer_id, const uint8_t *p, size_t size)
{
    if (!race || !p || !peer_id || size != ARC_AUTHORITY_INPUT_BYTES ||
        read_le(p, 2) != ARC_AUTHORITY_VERSION || p[2] != ARC_AUTHORITY_INPUT_TAG ||
        p[3] > 1 || !race->race_id || read_le(p + 4, 8) != race->race_id)
        return false;

    uint32_t seq = (uint32_t)read_le(p + 12, 4);
    for (size_t i = 0; i < race->count; ++i) {
        ArcAuthoritySeat *s = &race->seats[i];
        if (s->seat.is_bot || !s->connected || s->seat.peer_id != peer_id)
            continue;
        if (seq <= s->received_sequence || s->finish_tick)
            return false;

        int32_t steer = (int32_t)read_le(p + 16, 2);
        if (steer >= 32768)
            steer -= 65536;
        s->controls = (ArcControls){
            .steer = clamp((float)steer / 1000, -1, 1),
            .throttle = clamp((float)read_le(p + 18, 2) / 1000, 0, 1),
            .brake = clamp((float)read_le(p + 20, 2) / 1000, 0, 1),
            .handbrake = p[3] == 1
        };
        s->received_sequence = seq;
        s->received_tick = race->tick;
        return true;
    }
    return false;
}

void arc_authority_disconnect(ArcAuthority *race, uint8_t peer_id)
{
    if (!race || !peer_id)
        return;
    for (size_t i = 0; i < race->count; ++i) {
        ArcAuthoritySeat *s = &race->seats[i];
        if (!s->seat.is_bot && s->seat.peer_id == peer_id)
            s->connected = false;
    }
}

bool arc_authority_begin_tick(ArcAuthority *race, ArcControlFrame output[ARC_AUTHORITY_MAX_CARS])
{
    if (!race || !output || !race->count || race->tick_open || race->tick == UINT32_MAX)
        return false;
    ++race->tick;
    race->tick_open = true;
    for (size_t i = 0; i < race->count; ++i) {
        ArcAuthoritySeat *s = &race->seats[i];
        output[i] = (ArcControlFrame){.car_id = s->seat.car_id, .is_bot = s->seat.is_bot};
        if (s->connected && !s->finish_tick && s->received_sequence &&
            race->tick - s->received_tick <= ARC_AUTHORITY_STALE_TICKS) {
            output[i].controls = s->controls;
            s->applied_sequence = s->received_sequence;
        }
        output[i].applied_sequence = s->applied_sequence;
    }
    return true;
}

static bool finite_pose(const ArcHostPose *p)
{
    if (!isfinite(p->progress) || !isfinite(p->steer))
        return false;
    for (size_t i = 0; i < 3; ++i)
        if (!isfinite(p->position[i]) || !isfinite(p->velocity[i]))
            return false;
    float qnorm = 0;
    for (size_t i = 0; i < 4; ++i)
        qnorm += p->orientation[i] * p->orientation[i];
    return isfinite(qnorm) && qnorm > 0.5f && qnorm < 1.5f;
}

bool arc_authority_end_tick(ArcAuthority *race, const ArcHostPose *poses, size_t count,
                            ArcRaceSnapshot *output)
{
    if (!race || !race->tick_open || !poses || !output || count != race->count)
        return false;

    size_t index[ARC_AUTHORITY_MAX_CARS];
    unsigned matched = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!finite_pose(&poses[i]))
            return false;
        size_t j = 0;
        while (j < count && race->seats[j].seat.car_id != poses[i].car_id)
            ++j;
        if (j == count || (matched & (1u << j)))
            return false;
        matched |= 1u << j;
        index[j] = i;
    }

    ArcRaceSnapshot snapshot = {.race_id = race->race_id, .tick = race->tick, .count = count};
    for (size_t i = 0; i < count; ++i) {
        ArcAuthoritySeat *s = &race->seats[i];
        const ArcHostPose *p = &poses[index[i]];
        if (s->connected && !s->finish_tick && p->progress >= race->finish_progress)
            s->finish_tick = race->tick;
        snapshot.cars[i] = (ArcSnapshotCar){
            .pose = *p, .applied_sequence = s->applied_sequence,
            .finish_tick = s->finish_tick, .connected = s->connected
        };
    }
    race->tick_open = false;
    *output = snapshot;
    return true;
}
