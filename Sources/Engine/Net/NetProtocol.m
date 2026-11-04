#import "NetProtocol.h"

enum {
    U_ORIGIN   = 1 << 0,
    U_VELOCITY = 1 << 1,
    U_ORIENT   = 1 << 2,
    U_THROTTLE = 1 << 3,
    U_HEALTH   = 1 << 4,
    U_FLAGS    = 1 << 5,
    U_MODEL    = 1 << 6,    // kind, team, model
    U_NAMES    = 1 << 7,
    U_TARGET   = 1 << 8,
    U_SCALE    = 1 << 9,
    U_STEALTH  = 1 << 10,
    U_PARTS    = 1 << 11,
    U_REMOVE   = 1 << 15,
};

static const float kVelocityStep = 1.0f / 8.0f;     // m/s
static const float kQuatScale = 32767.0f * (float)M_SQRT2;   // smallest three are within ±1/sqrt(2)

#pragma mark - Quantization

static int16_t QuantizeVelocity(float v) { return (int16_t)fmaxf(-32767, fminf(32767, roundf(v / kVelocityStep))); }
static uint8_t QuantizeUnit(float v) { return (uint8_t)lroundf(fmaxf(0, fminf(1, v)) * 255); }

// Smallest three: drop the largest component (made positive), send the
// other three as 16-bit values and rebuild the dropped one.
static void EncodeQuat(simd_quatf q, uint8_t *index, int16_t c[3]) {
    simd_float4 v = simd_normalize(q.vector);
    int big = 0;
    for (int i = 1; i < 4; i++) if (fabsf(v[i]) > fabsf(v[big])) big = i;
    if (v[big] < 0) v = -v;
    *index = (uint8_t)big;
    for (int i = 0, k = 0; i < 4; i++) {
        if (i == big) continue;
        c[k++] = (int16_t)fmaxf(-32767, fminf(32767, roundf(v[i] * kQuatScale)));
    }
}

static simd_quatf DecodeQuat(uint8_t index, const int16_t c[3]) {
    simd_float4 v = 0;
    float sum = 0;
    for (int i = 0, k = 0; i < 4; i++) {
        if (i == (index & 3)) continue;
        v[i] = c[k++] / kQuatScale;
        sum += v[i] * v[i];
    }
    v[index & 3] = sqrtf(fmaxf(0, 1 - sum));
    return simd_quaternion(simd_normalize(v));
}

void QuantizeEntity(EntityState *e) {
    for (int i = 0; i < 3; i++) e->velocity[i] = QuantizeVelocity(e->velocity[i]) * kVelocityStep;
    uint8_t idx;
    int16_t c[3];
    EncodeQuat(e->orientation, &idx, c);
    e->orientation = DecodeQuat(idx, c);
    e->throttle = QuantizeUnit(e->throttle) / 255.0f;
    e->hull = QuantizeUnit(e->hull) / 255.0f;
    e->shield = QuantizeUnit(e->shield) / 255.0f;
}

#pragma mark - Entities

static BOOL QuatEqual(simd_quatf a, simd_quatf b) { return simd_equal(a.vector, b.vector); }

void WriteDeltaEntity(MsgWriter *w, const EntityState *from, const EntityState *to, BOOL force) {
    static const EntityState zero = { .scale = 1, .orientation = { { 0, 0, 0, 1 } } };
    if (!from) from = &zero;
    uint16_t bits = 0;
    if (!simd_equal(from->origin, to->origin)) bits |= U_ORIGIN;
    if (!simd_equal(from->velocity, to->velocity)) bits |= U_VELOCITY;
    if (!QuatEqual(from->orientation, to->orientation)) bits |= U_ORIENT;
    if (from->throttle != to->throttle) bits |= U_THROTTLE;
    if (from->hull != to->hull || from->shield != to->shield) bits |= U_HEALTH;
    if (from->flags != to->flags) bits |= U_FLAGS;
    if (from->kind != to->kind || from->team != to->team || from->model != to->model) bits |= U_MODEL;
    if (from->name != to->name || from->className != to->className) bits |= U_NAMES;
    if (from->target != to->target) bits |= U_TARGET;
    if (from->scale != to->scale) bits |= U_SCALE;
    if (from->stealthRange != to->stealthRange) bits |= U_STEALTH;
    if (from->deadParts != to->deadParts) bits |= U_PARTS;
    if (!bits && !force) return;

    [w u16:to->number];
    [w u16:bits];
    if (bits & U_ORIGIN) [w vec3:to->origin];
    if (bits & U_VELOCITY) for (int i = 0; i < 3; i++) [w i16:QuantizeVelocity(to->velocity[i])];
    if (bits & U_ORIENT) {
        uint8_t idx;
        int16_t c[3];
        EncodeQuat(to->orientation, &idx, c);
        [w u8:idx];
        for (int i = 0; i < 3; i++) [w i16:c[i]];
    }
    if (bits & U_THROTTLE) [w u8:QuantizeUnit(to->throttle)];
    if (bits & U_HEALTH) { [w u8:QuantizeUnit(to->hull)]; [w u8:QuantizeUnit(to->shield)]; }
    if (bits & U_FLAGS) [w u32:to->flags];
    if (bits & U_MODEL) { [w u8:to->kind]; [w u8:to->team]; [w u16:to->model]; }
    if (bits & U_NAMES) { [w u16:to->name]; [w u16:to->className]; }
    if (bits & U_TARGET) [w u16:to->target];
    if (bits & U_SCALE) [w f32:to->scale];
    if (bits & U_STEALTH) [w f32:to->stealthRange];
    if (bits & U_PARTS) [w u64:to->deadParts];
}

static void WriteRemove(MsgWriter *w, uint16_t number) {
    [w u16:number];
    [w u16:U_REMOVE];
}

// Merge the two sorted lists, Quake 2 style: changed, new and removed
// entities are written; unchanged ones cost nothing. Ends with number 0.
void WritePacketEntities(MsgWriter *w, const EntityState *from, NSUInteger fromCount, const EntityState *to, NSUInteger toCount) {
    NSUInteger i = 0, j = 0;
    while (i < fromCount || j < toCount) {
        uint16_t a = i < fromCount ? from[i].number : 0xFFFF, b = j < toCount ? to[j].number : 0xFFFF;
        if (a == b) { WriteDeltaEntity(w, &from[i], &to[j], NO); i++; j++; }
        else if (b < a) { WriteDeltaEntity(w, NULL, &to[j], YES); j++; }
        else { WriteRemove(w, a); i++; }
    }
    [w u16:0];
}

static void ReadDeltaEntity(MsgReader *r, uint16_t bits, EntityState *e) {
    if (bits & U_ORIGIN) e->origin = [r vec3];
    if (bits & U_VELOCITY) for (int i = 0; i < 3; i++) e->velocity[i] = [r i16] * kVelocityStep;
    if (bits & U_ORIENT) {
        uint8_t idx = [r u8];
        int16_t c[3];
        for (int i = 0; i < 3; i++) c[i] = [r i16];
        e->orientation = DecodeQuat(idx, c);
    }
    if (bits & U_THROTTLE) e->throttle = [r u8] / 255.0f;
    if (bits & U_HEALTH) { e->hull = [r u8] / 255.0f; e->shield = [r u8] / 255.0f; }
    if (bits & U_FLAGS) e->flags = [r u32];
    if (bits & U_MODEL) { e->kind = [r u8]; e->team = [r u8]; e->model = [r u16]; }
    if (bits & U_NAMES) { e->name = [r u16]; e->className = [r u16]; }
    if (bits & U_TARGET) e->target = [r u16];
    if (bits & U_SCALE) e->scale = [r f32];
    if (bits & U_STEALTH) e->stealthRange = [r f32];
    if (bits & U_PARTS) e->deadParts = [r u64];
}

BOOL ReadPacketEntities(MsgReader *r, const EntityState *from, NSUInteger fromCount, NSMutableData *out) {
    static const EntityState zero = { .scale = 1, .orientation = { { 0, 0, 0, 1 } } };
    NSUInteger i = 0;
    for (;;) {
        uint16_t number = [r u16];
        if (r.overflow) return NO;
        // Baseline entities before this number are unchanged.
        while (i < fromCount && (number == 0 || from[i].number < number)) [out appendBytes:&from[i++] length:sizeof(EntityState)];
        if (number == 0) return YES;
        uint16_t bits = [r u16];
        EntityState e;
        if (i < fromCount && from[i].number == number) e = from[i++];
        else { e = zero; e.number = number; }
        if (bits & U_REMOVE) continue;
        ReadDeltaEntity(r, bits, &e);
        if (r.overflow) return NO;
        [out appendBytes:&e length:sizeof e];
    }
}

#pragma mark - Player state

// Full precision: prediction replays commands from this state, so it has to
// match the server's exactly.
void WritePlayerState(MsgWriter *w, const PlayerState *ps) {
    const ShipMoveState *m = &ps->move;
    [w vec3:m->origin];
    [w vec3:m->velocity];
    [w vec3:m->angularVelocity];
    [w quat:m->orientation];
    [w f32:m->throttle];
    [w f32:m->boostEnergy];
    [w u8:(uint8_t)(m->boosting | (m->boostDepleted << 1) | (ps->alive << 2))];
    [w f32:ps->params.maxSpeed];
    [w f32:ps->params.turnRate];
    [w u16:ps->entity];
    [w f32:ps->hull];
    [w f32:ps->shield];
    [w f32:ps->missionTime];
    for (int i = 0; i < MAX_STATS; i++) [w i16:ps->stats[i]];
    [w u32:ps->commandTime];
    [w u32:ps->lastCommand];
}

void ReadPlayerState(MsgReader *r, PlayerState *ps) {
    ShipMoveState *m = &ps->move;
    m->origin = [r vec3];
    m->velocity = [r vec3];
    m->angularVelocity = [r vec3];
    m->orientation = [r quat];
    m->throttle = [r f32];
    m->boostEnergy = [r f32];
    uint8_t b = [r u8];
    m->boosting = b & 1;
    m->boostDepleted = (b >> 1) & 1;
    ps->alive = (b >> 2) & 1;
    ps->params.maxSpeed = [r f32];
    ps->params.turnRate = [r f32];
    ps->entity = [r u16];
    ps->hull = [r f32];
    ps->shield = [r f32];
    ps->missionTime = [r f32];
    for (int i = 0; i < MAX_STATS; i++) ps->stats[i] = [r i16];
    ps->commandTime = [r u32];
    ps->lastCommand = [r u32];
}

#pragma mark - Events

void WriteEvents(MsgWriter *w, const GameEvent *events, NSUInteger count) {
    count = MIN(count, 255);
    [w u8:(uint8_t)count];
    for (NSUInteger i = 0; i < count; i++) {
        const GameEvent *e = &events[i];
        [w u8:e->type];
        [w u8:e->team];
        [w u8:e->flags];
        [w u16:e->entity];
        [w u16:e->id];
        [w u16:e->model];
        [w vec3:e->pos];
        // Only some events use these; skip them for the rest.
        BOOL motion = e->type == EV_BOLT || e->type == EV_EXPLOSION;
        BOOL sized = e->type == EV_EXPLOSION || e->type == EV_DAMAGE || e->type == EV_JUMP;
        if (motion) [w vec3:e->vel];
        if (sized) { [w f32:e->scale]; [w f32:e->radius]; }
    }
}

NSData *ReadEvents(MsgReader *r) {
    NSUInteger count = [r u8];
    NSMutableData *out = [NSMutableData dataWithCapacity:count * sizeof(GameEvent)];
    for (NSUInteger i = 0; i < count && !r.overflow; i++) {
        GameEvent e = {0};
        e.type = [r u8];
        e.team = [r u8];
        e.flags = [r u8];
        e.entity = [r u16];
        e.id = [r u16];
        e.model = [r u16];
        e.pos = [r vec3];
        if (e.type == EV_BOLT || e.type == EV_EXPLOSION) e.vel = [r vec3];
        if (e.type == EV_EXPLOSION || e.type == EV_DAMAGE || e.type == EV_JUMP) { e.scale = [r f32]; e.radius = [r f32]; }
        [out appendBytes:&e length:sizeof e];
    }
    return out;
}

#pragma mark - User commands

static int16_t AxisToWire(float v) { return (int16_t)lroundf(fmaxf(-1, fminf(1, v)) * 32767); }

void QuantizeUserCmd(UserCmd *c) {
    c->pitch = AxisToWire(c->pitch) / 32767.0f;
    c->yaw = AxisToWire(c->yaw) / 32767.0f;
    c->roll = AxisToWire(c->roll) / 32767.0f;
    c->throttle = (uint16_t)lroundf(fmaxf(0, fminf(1, c->throttle)) * 65535) / 65535.0f;
}

void WriteUserCmd(MsgWriter *w, const UserCmd *c) {
    [w u32:c->sequence];
    [w u8:c->msec];
    [w u8:c->buttons];
    [w u8:c->impulse];
    [w i16:AxisToWire(c->pitch)];
    [w i16:AxisToWire(c->yaw)];
    [w i16:AxisToWire(c->roll)];
    [w u16:(uint16_t)lroundf(fmaxf(0, fminf(1, c->throttle)) * 65535)];
}

void ReadUserCmd(MsgReader *r, UserCmd *c) {
    c->sequence = [r u32];
    c->msec = [r u8];
    c->buttons = [r u8];
    c->impulse = [r u8];
    c->pitch = [r i16] / 32767.0f;
    c->yaw = [r i16] / 32767.0f;
    c->roll = [r i16] / 32767.0f;
    c->throttle = [r u16] / 65535.0f;
}
