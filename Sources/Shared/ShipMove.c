#include "Shared.h"

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
    s->boostEnergy = fminf(1, fmaxf(0, s->boostEnergy + (boost ? -p->boostDrain : p->boostRecharge) * dt));
    s->boosting = boost;
    s->throttle = c.throttle;

    // Angular rates chase the stick, giving a little weight to the controls.
    simd_float3 target = simd_make_float3(c.pitch * p->pitchRate, -c.yaw * p->yawRate, -c.roll * p->rollRate) * p->turnRate;
    if (boost) target *= p->boostTurn;
    s->angularVelocity += (target - s->angularVelocity) * (1.0f - expf(-p->agility * dt));
    float w = simd_length(s->angularVelocity);
    if (w > 1e-5f) {
        simd_quatf dq = simd_quaternion(w * dt, s->angularVelocity / w);
        s->orientation = simd_normalize(simd_mul(s->orientation, dq));
    }

    // Arcade space flight: velocity is pulled toward the nose, so hard turns
    // drift before the engines catch up.
    float speed = s->throttle * p->maxSpeed + (boost ? p->maxSpeed * p->boostSpeed : 0);
    simd_float3 desired = QuatForward(s->orientation) * speed;
    float grip = boost ? p->boostGrip : p->grip;
    s->velocity += (desired - s->velocity) * (1.0f - expf(-grip * dt));
    s->origin += s->velocity * dt;
}

simd_float3 AimAssist(simd_float3 forward, simd_float3 muzzle, simd_float3 shooterVelocity,
                      simd_float3 target, simd_float3 targetVelocity, float boltSpeed, float range, float cone) {
    if (cone <= 0 || boltSpeed <= 0) return forward;
    // In the shooter's frame the bolt flies at boltSpeed, so solve
    // |p + v t| = boltSpeed t for the earliest t > 0.
    simd_float3 p = target - muzzle, v = targetVelocity - shooterVelocity;
    float a = simd_dot(v, v) - boltSpeed * boltSpeed, b = 2 * simd_dot(p, v), c = simd_dot(p, p);
    float t;
    if (fabsf(a) < 1e-4f) {
        if (b >= 0) return forward;
        t = -c / b;
    } else {
        float disc = b * b - 4 * a * c;
        if (disc < 0) return forward;
        float r = sqrtf(disc), t1 = (-b - r) / (2 * a), t2 = (-b + r) / (2 * a);
        t = t1 > 0 && (t1 < t2 || t2 <= 0) ? t1 : t2;
    }
    if (t <= 0 || boltSpeed * t > range) return forward;
    simd_float3 aim = simd_normalize(p + v * t);
    return simd_dot(aim, forward) >= cosf(cone) ? aim : forward;
}
