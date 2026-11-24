#include "RaceAuthority.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static const uint64_t game = UINT64_C(0x123456789abcdef0);
static const ArcRaceSeat roster[] = {
    { .car_id = 0, .peer_id = 3 },
    { .car_id = 5, .peer_id = 7 },
    { .car_id = 8, .peer_id = 3, .is_bot = true }
};

int main(void)
{
    ArcAuthority a = {0};
    ArcRaceSnapshot snap = {0};
    ArcControlFrame controls[ARC_AUTHORITY_MAX_CARS];
    const ArcRaceSeat duplicate_peer[] = {{2, 7, false}, {1, 7, false}};
    assert(!arc_authority_start(&a, game, 100, 2, duplicate_peer, 2));
    assert(!arc_authority_start(&a, game, 100, 6, roster, 3));
    assert(!arc_authority_start(&a, game, NAN, 2, roster, 3));
    assert(arc_authority_start(&a, game, 100, 2, roster, 3));
    assert(!arc_authority_start(&a, game, 100, 2, roster, 3));

    uint8_t input[ARC_AUTHORITY_INPUT_BYTES + 1] = {0};
    assert(!arc_authority_encode_input(input, game, 1, (ArcControls){.steer = NAN}));
    assert(arc_authority_encode_input(input, game, 10, (ArcControls){-2, 5, -1, true}));
    assert(input[0] == ARC_AUTHORITY_VERSION && input[1] == 0);
    assert(input[4] == 0xf0 && input[11] == 0x12 && input[12] == 10);
    assert(!arc_authority_receive(&a, 99, input, ARC_AUTHORITY_INPUT_BYTES));
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES - 1));
    assert(!arc_authority_receive(&a, 3, input, sizeof input));
    input[0] = 3;
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    input[0] = ARC_AUTHORITY_VERSION;
    input[2] = 7; /* legacy finish opcode */
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    input[2] = 10; /* legacy pose opcode */
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    input[2] = ARC_AUTHORITY_INPUT_TAG;
    input[3] = 2;
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    input[3] = 1;
    /* Independently clamp all received fields, not just trusted local encoding. */
    input[16] = 0; input[17] = 128; input[18] = 255; input[19] = 255;
    input[20] = 255; input[21] = 255;
    assert(arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    assert(arc_authority_encode_input(input, game, 9, (ArcControls){0}));
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    assert(arc_authority_encode_input(input, game, 1, (ArcControls){.throttle = 0.5f}));
    assert(arc_authority_receive(&a, 7, input, ARC_AUTHORITY_INPUT_BYTES));

    ArcHostPose poses[] = {
        {.car_id = 5, .orientation = {0, 0, 0, 1}, .progress = -4},
        {.car_id = 0, .orientation = {0, 0, 0, 1}},
        {.car_id = 8, .orientation = {0, 0, 0, 1}}
    };

    assert(arc_authority_begin_tick(&a, controls));
    assert(!arc_authority_begin_tick(&a, controls));
    assert(controls[0].car_id == 0 && controls[0].applied_sequence == 10);
    assert(controls[0].controls.steer == -1 && controls[0].controls.throttle == 1 &&
           controls[0].controls.brake == 1 && controls[0].controls.handbrake);
    assert(controls[1].applied_sequence == 1 && controls[1].controls.throttle == 0.5f);
    assert(controls[2].is_bot && controls[2].applied_sequence == 0);
    assert(!arc_authority_end_tick(&a, poses, 2, &snap));
    poses[2].car_id = 5;
    assert(!arc_authority_end_tick(&a, poses, 3, &snap) && snap.tick == 0);
    poses[2].car_id = 8;
    poses[2].position[0] = INFINITY;
    assert(!arc_authority_end_tick(&a, poses, 3, &snap) && snap.tick == 0);
    poses[2].position[0] = 0;
    assert(arc_authority_end_tick(&a, poses, 3, &snap));
    assert(snap.race_id == game && snap.tick == 1 && snap.count == 3);
    assert(snap.cars[0].pose.car_id == 0 && snap.cars[1].pose.progress == -4);
    assert(!snap.cars[0].finish_tick && !snap.cars[1].finish_tick);
    assert(!arc_authority_end_tick(&a, poses, 3, &snap) && snap.tick == 1);

    for (int tick = 2; tick <= ARC_AUTHORITY_STALE_TICKS + 1; ++tick) {
        assert(arc_authority_begin_tick(&a, controls));
        assert(controls[0].controls.throttle == (tick <= ARC_AUTHORITY_STALE_TICKS ? 1 : 0));
        assert(controls[0].applied_sequence == 10);
        assert(arc_authority_end_tick(&a, poses, 3, &snap));
    }
    arc_authority_disconnect(&a, 7);
    assert(arc_authority_encode_input(input, game, 2, (ArcControls){.throttle = 1}));
    assert(!arc_authority_receive(&a, 7, input, ARC_AUTHORITY_INPUT_BYTES));
    assert(arc_authority_encode_input(input, game, 11, (ArcControls){.throttle = 1}));
    assert(arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));

    assert(arc_authority_begin_tick(&a, controls));
    assert(controls[0].controls.throttle == 1 && controls[0].applied_sequence == 11);
    assert(controls[1].controls.throttle == 0);
    poses[0].progress = 250; /* disconnected is DNF, even if coasting across the line */
    poses[1].progress = 199.9f;
    assert(arc_authority_end_tick(&a, poses, 3, &snap));
    assert(!snap.cars[1].connected && !snap.cars[1].finish_tick);
    assert(!snap.cars[0].finish_tick);

    assert(arc_authority_begin_tick(&a, controls));
    poses[1].progress = 200;
    assert(arc_authority_end_tick(&a, poses, 3, &snap));
    uint32_t finish = snap.tick;
    assert(snap.cars[0].finish_tick == finish);
    assert(!snap.cars[2].finish_tick);
    assert(arc_authority_encode_input(input, game, 12, (ArcControls){.throttle = 1}));
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));

    assert(arc_authority_begin_tick(&a, controls));
    assert(controls[0].controls.throttle == 0);
    poses[1].progress = 205;
    assert(arc_authority_end_tick(&a, poses, 3, &snap));
    assert(snap.cars[0].finish_tick == finish && snap.tick > finish);

    assert(arc_authority_start(&a, game + 1, 120, 1, roster, 3));
    assert(!arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    assert(arc_authority_encode_input(input, game + 1, 1, (ArcControls){.throttle = 1}));
    assert(arc_authority_receive(&a, 3, input, ARC_AUTHORITY_INPUT_BYTES));
    for (size_t i = 0; i < 3; ++i)
        poses[i].progress = -4;
    assert(arc_authority_begin_tick(&a, controls));
    assert(arc_authority_end_tick(&a, poses, 3, &snap));
    assert(snap.race_id == game + 1 && snap.tick == 1 && !snap.cars[0].finish_tick);
    puts("Authoritative race boundary passed");
}
