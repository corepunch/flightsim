#include "ShipMove.h"
#include "SharedMath.h"

void ShipMoveReset(ShipMoveState *s, simd_float3 origin, simd_quatf orientation) {
    s->origin = origin;
    s->orientation = orientation;
    s->velocity = QuatForward(orientation) * 60;
    s->angularVelocity = 0;
    s->boostEnergy = 1;
    s->boostDepleted = 0;
    s->boosting = 0;
}

void ShipMove(ShipMoveState *s, const ShipParams *p, ShipInput c, float dt) {
    // Boost drains energy; it recharges when not boosting. Once drained it
    // stays locked out until 15% has recharged (hysteresis). Without that,
    // holding the button at empty would toggle boost every frame or two
    // (recharge a bit, go over the threshold, drain, repeat), and the camera,
    // exhaust and HUD would all flicker along with it.
    if (s->boostEnergy <= 0.02f) s->boostDepleted = 1;
    else if (s->boostEnergy >= 0.15f) s->boostDepleted = 0;
    bool boost = c.boost && !s->boostDepleted;
    s->boostEnergy = fminf(1, fmaxf(0, s->boostEnergy + (boost ? -0.28f : 0.12f) * dt));
    s->boosting = boost;
    s->throttle = c.throttle;

    // Angular rates chase the stick, giving a little weight to the controls.
    simd_float3 target = simd_make_float3(c.pitch * 1.45f, -c.yaw * 0.85f, -c.roll * 2.6f) * p->turnRate;
    if (boost) target *= 0.7f;
    s->angularVelocity += (target - s->angularVelocity) * (1.0f - expf(-5.5f * dt));
    float w = simd_length(s->angularVelocity);
    if (w > 1e-5f) {
        simd_quatf dq = simd_quaternion(w * dt, s->angularVelocity / w);
        s->orientation = simd_normalize(simd_mul(s->orientation, dq));
    }

    // Arcade space flight: velocity is pulled toward the nose, so hard turns
    // drift before the engines catch up.
    float speed = s->throttle * p->maxSpeed + (boost ? p->maxSpeed * 0.9f : 0);
    simd_float3 desired = QuatForward(s->orientation) * speed;
    float grip = boost ? 2.2f : 1.4f;
    s->velocity += (desired - s->velocity) * (1.0f - expf(-grip * dt));
    s->origin += s->velocity * dt;
}
