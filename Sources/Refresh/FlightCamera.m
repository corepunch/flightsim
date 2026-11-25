#import "Refresh.h"
#import "Common.h"

// Banks the ship into a yaw turn so it leans like an aircraft instead of
// pivoting flat like a car. The lean follows the eased yaw rate (so it settles
// back when the stick centres) and turns only about the nose axis, which leaves
// aim, flight and the server's state untouched. About 28 degrees at full yaw
// for a ship turning 1.45 rad/s.
static float BankAngle(const ShipMoveState *m) {
    return fminf(fmaxf(m->angularVelocity.y * 0.34f, -0.6f), 0.6f);
}

static simd_quatf BankedOrientation(const ShipMoveState *m) {
    return simd_normalize(simd_mul(m->orientation, simd_quaternion(BankAngle(m), simd_make_float3(0, 0, 1))));
}

simd_quatf FlightViewOrientation(const PlayerState *ps) {
    return ps->params.gravity > 0 ? ps->move.orientation : BankedOrientation(&ps->move);
}

// A rotation from a rotation vector (axis times angle).
static simd_quatf QuatFromRotation(simd_float3 v) {
    float a = simd_length(v);
    return a > 1e-5f ? simd_quaternion(a, v / a) : simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
}

// How far ahead of the ship the chase gunsight's stations lie, nearest first: a
// few lengths past the nose, and far down the line of fire, where a target is
// and the crosshair stands. The chase camera aims at the last, so in level
// flight it is the screen's centre.
static const float SightDistances[HUD_SIGHT_STATIONS] = { 25, 400 };

static float Ease(float value, float target, float rate, float dt) {
    return value + (target - value) * (1.0f - expf(-rate * dt));
}

/// Places the chase or cockpit camera for this frame.
///
/// Everything here is smoothed over time so the view never moves abruptly:
/// - Free-look (hat) and the chase camera's orientation lag behind the ship using
///   exponential easing, `1 - exp(-k*dt)`, which doesn't depend on frame rate.
/// - Boost effects (pull-back, FOV) are scaled by the eased boost state, which
///   eases in and out instead of snapping between 0 and 1.
/// - Shake is a deterministic sum of sines, not per-frame random noise. Random
///   noise jumps to a new spot every frame, so it shows up as jitter (worse at
///   higher frame rates) rather than rumble.
///
/// Tuning: boost rumble amplitude is `boostFx * 0.015f`; the cockpit scale is `0.15f`.
RefCamera FlightCameraUpdate(FlightCameraState *state, const PlayerState *ps, simd_float3 eye,
                             BOOL cockpit, BOOL dynamic, int hat, float dt, double time) {
    float targetYaw = 0, targetPitch = 0;
    if (hat >= 0) {
        float a = hat * (float)M_PI / 4.0f;
        targetYaw = sinf(a) * 1.4f;
        targetPitch = cosf(a) * 0.7f;
        if (hat == 4) { targetYaw = (float)M_PI * 0.95f; targetPitch = 0.1f; }
    }
    FlightCameraState chase = *state;
    chase.lookYaw = Ease(chase.lookYaw, targetYaw, 6, dt);
    chase.lookPitch = Ease(chase.lookPitch, targetPitch, 6, dt);
    simd_quatf look = simd_mul(simd_quaternion(-chase.lookYaw, simd_make_float3(0, 1, 0)),
                               simd_quaternion(chase.lookPitch, simd_make_float3(1, 0, 0)));

    simd_quatf shipQ = ps->move.orientation;
    if (simd_length(chase.orientation.vector) < 0.5f) chase.orientation = shipQ;
    chase.orientation = simd_slerp(chase.orientation, shipQ, 1.0f - expf(-(cockpit ? 30.0f : 7.0f) * dt));
    // The dynamic chase view sits behind the ship but looks into its turn and
    // climb, so the ship slides away from where it is heading (out of a turn,
    // down in a pull-up) and the pilot sees where it is going. It also shares
    // part of the ship's lean, which tilts the horizon. Roll rate is left out:
    // it should spin the ship, not swing the view. Pitch leads less than yaw
    // because the ship already sits low in the frame.
    dynamic = !cockpit && dynamic;
    simd_float3 w = ps->move.angularVelocity;
    simd_float3 lead = simd_make_float3(clampf(w.x * 0.12f, -0.13f, 0.13f), clampf(w.y * 0.3f, -0.42f, 0.42f), 0);
    if (!dynamic) lead = 0;
    chase.lead += (lead - chase.lead) * (1.0f - expf(-4.0f * dt));
    chase.roll = Ease(chase.roll, dynamic ? BankAngle(&ps->move) * 0.6f : 0, 5, dt);
    simd_quatf view = simd_mul(simd_mul(chase.orientation, QuatFromRotation(chase.lead)),
                               simd_quaternion(chase.roll, simd_make_float3(0, 0, 1)));
    // The cockpit eye leans with the ship; the chase view only partly, so the
    // rest of the lean shows on the hull.
    simd_quatf q = simd_mul(cockpit ? FlightViewOrientation(ps) : view, look);

    float speed = simd_length(ps->move.velocity);
    // Ease boost effects in and out so toggling boost never pops the camera.
    chase.boost = Ease(chase.boost, ps->move.boosting ? 1 : 0, 4, dt);
    float boostFx = chase.boost;
    // Once the ship is destroyed the chase view backs away, so its own
    // explosion is seen whole instead of from inside the fireball.
    chase.dead = Ease(chase.dead, ps->alive ? 0 : 1, ps->alive ? 8 : 2.5f, dt);
    simd_float3 deathPull = simd_make_float3(0, 8.0f, 32.0f) * chase.dead;
    // Dynamic: low and close behind the ship, which sits in the lower part of
    // the frame with the gunsight and whatever it is chasing above it. Fixed:
    // farther back, looking along the ship's nose.
    simd_float3 offset = cockpit ? eye
                       : dynamic ? simd_make_float3(0, 3.2f, 14.0f + speed * 0.008f + boostFx * 3.0f)
                                 : simd_make_float3(0, 1.6f, 17.0f + speed * 0.012f + boostFx * 3.0f);
    chase.seat = offset;
    offset += deathPull;
    simd_float3 pos = ps->move.origin + simd_act(cockpit ? shipQ : chase.orientation, simd_act(look, offset));
    if (cockpit) pos = ps->move.origin + simd_act(FlightViewOrientation(ps), offset);
    // Aim down the line of fire at the farthest sight station, which puts it
    // at the centre of the screen and the ship below it.
    if (dynamic) q = simd_mul(q, simd_quaternion(-atan2f(offset.y, offset.z + SightDistances[HUD_SIGHT_STATIONS - 1]),
                                                   simd_make_float3(1, 0, 0)));

    chase.shake = fmaxf(0, chase.shake - dt * 1.5f);
    // Smooth shake: two sines per axis, ~3-7 Hz, at frequencies with no common
    // pattern so it never visibly loops. The wobble is applied in camera space,
    // so shake stays the same relative to the screen whichever way the camera faces.
    // The shake (hits, explosions) falls off with a square curve; boost only adds a faint
    // rumble. The cockpit eye gets 15% of it all because the interior is centimetres
    // away and any movement makes the whole cockpit swim.
    float sh = chase.shake * chase.shake * 0.6f + boostFx * 0.015f;
    if (cockpit) sh *= 0.15f;
    float t = (float)time;
    simd_float3 wobble = simd_make_float3(sinf(t * 23.1f) * 0.6f + sinf(t * 37.7f + 1.3f) * 0.4f,
                                          sinf(t * 29.3f + 2.1f) * 0.6f + sinf(t * 41.9f + 0.7f) * 0.4f,
                                          sinf(t * 19.7f + 4.2f) * 0.6f + sinf(t * 33.1f + 3.3f) * 0.4f);
    pos += simd_act(q, wobble) * sh;

    chase.fov = Ease(chase.fov, 68.0f + speed * 0.03f + boostFx * 8.0f, 3, dt);
    *state = chase;
    return (RefCamera){
        .origin = pos, .orientation = q, .fov = chase.fov, .zNear = cockpit ? 0.08f : 0.3f,
        .focus = ps->move.origin, .velocity = ps->move.velocity,
    };
}

void FlightCameraSight(HUDFrame *frame, id<Refresh> refresh, const PlayerState *ps,
                       simd_float3 seat, BOOL cockpit) {
    simd_float3 me = ps->move.origin, fwd = QuatForward(ps->move.orientation);
    frame->boresightVisible = [refresh projectPoint:me + fwd * SightDistances[HUD_SIGHT_STATIONS - 1] to:&frame->boresight];
    // The chase gunsight is drawn at stations ahead of the ship on its line of
    // fire, leaning with the hull, so its perspective shows where the guns point.
    if (!cockpit) {
        simd_quatf banked = FlightViewOrientation(ps);
        simd_float3 right = simd_act(banked, simd_make_float3(1, 0, 0)), up = simd_act(banked, simd_make_float3(0, 1, 0));
        // The settled camera sits above the line of fire and looks down it at the
        // farthest station; its line of sight passes this far above a nearer one.
        simd_float3 seatUp = simd_act(ps->move.orientation, simd_make_float3(0, 1, 0));
        float reach = SightDistances[HUD_SIGHT_STATIONS - 1] + seat.z;
        for (int i = 0; i < HUD_SIGHT_STATIONS; i++) {
            simd_float3 centre = me + fwd * SightDistances[i];
            float lift = seat.y * (1 - (SightDistances[i] + seat.z) / reach);
            CGPoint c, r, u, l;
            if (![refresh projectPoint:centre to:&c] || ![refresh projectPoint:centre + right to:&r] || ![refresh projectPoint:centre + up to:&u]
                || ![refresh projectPoint:centre + seatUp * lift to:&l]) break;
            frame->sight[frame->sightStations++] = (HUDStation){ .centre = c, .right = PointSub(r, c), .up = PointSub(u, c), .level = l };
        }
    }
}
