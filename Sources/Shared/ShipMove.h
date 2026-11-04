// The fighter flight model, as a pure function of (state, input, dt). The game
// runs it for every ship; the client runs the same code to predict its own
// ship between snapshots, so both must stay bit-for-bit in step.
#pragma once
#include "Protocol.h"

typedef struct {
    float pitch, yaw, roll;     // -1..1
    float throttle;             // 0..1
    bool boost;
} ShipInput;

void ShipMove(ShipMoveState *s, const ShipParams *p, ShipInput in, float dt);
void ShipMoveReset(ShipMoveState *s, simd_float3 origin, simd_quatf orientation);

static inline ShipInput ShipInputFromCmd(const UserCmd *c) {
    return (ShipInput){ c->pitch, c->yaw, c->roll, c->throttle, (c->buttons & BUTTON_BOOST) != 0 };
}
