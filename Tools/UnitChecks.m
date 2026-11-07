// Headless checks of the engine's shared core: the flight model, the wire
// format, the console and the campaign data. No window, no GPU, no game
// module: it links the Shared, Common and Net sources and runs anywhere a
// Mac can compile. Tools/run-unit-checks.sh builds and runs it.
#import <Foundation/Foundation.h>
#include "Shared.h"
#import "Shared.h"
#import "Common.h"
#import "Net.h"
#import "Mission.h"
#import "Story.h"

static int failures;

// Data/<directory>/<name>.json on the search path (the game's folder) as a dictionary.
static NSDictionary *DefinitionJSON(NSString *directory, NSString *name) {
    return FSJSON(FSURL([@"Data" stringByAppendingPathComponent:directory], name, @"json"));
}
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)
#define NEAR(a, b, eps) (fabsf((float)(a) - (float)(b)) <= (eps))

#pragma mark - Comparisons

// simd_float3 carries a fourth lane the wire never sends, so states are
// compared lane by lane, not with memcmp.
static bool Vec3Equal(simd_float3 a, simd_float3 b) { return a.x == b.x && a.y == b.y && a.z == b.z; }
static bool QuatEqual(simd_quatf a, simd_quatf b) { return simd_equal(a.vector, b.vector); }

static bool EntityEqual(const EntityState *a, const EntityState *b) {
    return a->number == b->number && a->kind == b->kind && a->team == b->team && a->model == b->model &&
           a->name == b->name && a->className == b->className && a->target == b->target && a->flags == b->flags &&
           Vec3Equal(a->origin, b->origin) && Vec3Equal(a->velocity, b->velocity) && QuatEqual(a->orientation, b->orientation) &&
           a->scale == b->scale && a->throttle == b->throttle && a->hull == b->hull && a->shield == b->shield &&
           a->stealthRange == b->stealthRange && a->deadParts == b->deadParts;
}

static bool MoveEqual(const ShipMoveState *a, const ShipMoveState *b) {
    return Vec3Equal(a->origin, b->origin) && Vec3Equal(a->velocity, b->velocity) &&
           Vec3Equal(a->angularVelocity, b->angularVelocity) && QuatEqual(a->orientation, b->orientation) &&
           a->throttle == b->throttle && a->boostEnergy == b->boostEnergy &&
           a->boosting == b->boosting && a->boostDepleted == b->boostDepleted;
}

#pragma mark - Flight model

static ShipInput InputAt(int step) {
    return (ShipInput){ sinf(step * 0.07f) * 0.8f, cosf(step * 0.05f) * 0.5f, sinf(step * 0.11f) * 0.6f,
                        0.6f + 0.4f * sinf(step * 0.02f), (step / 90) % 3 == 1 };
}

// Every ship definition in the bundle loads and is complete enough to fly
// and shoot; the first one's flight parameters drive the flight model checks.
static ShipParams CheckShipDefinitions(void) {
    NSArray<NSString *> *names = ShipDefNames();
    CHECK(names.count >= 1);
    for (NSString *name in names) {
        const ShipDef *def = ShipDefNamed(name);
        CHECK(def != NULL);
        if (!def) continue;
        CHECK(def->gunCount > 0 && def->nozzleCount > 0 && def->radius > 0);
        CHECK(def->gun.speed > 0 && def->gun.life > 0 && def->gun.interval > 0 && def->gun.energy > 0 && def->gun.recharge > 0);
        CHECK(def->params.maxSpeed > 0 && def->params.turnRate > 0 && def->params.agility > 0 && def->params.grip > 0);
        CHECK(def->params.boostDrain > 0 && def->params.boostRecharge > 0 && def->params.boostSpeed > 0);
        CHECK(def->aiParams.maxSpeed > 0 && def->aiGun.speed > 0);
        CHECK(def->hull > 0 && def->shield >= 0 && def->shieldRegen >= 0);
        const ShipSecondary *w = &def->secondary;
        CHECK(w->rounds >= 0 && w->range > 0 && w->maxSpeed > 0 && w->life > 0 && w->damage > 0 && w->capitalDamage > 0 && w->fuse > 0);
        CHECK([ShipModelName(name) isEqualToString:[@"ship:" stringByAppendingString:name]] && ShipDefForModel(ShipModelName(name)) == def);
    }
    CHECK(ShipDefNamed(@"no-such-ship") == NULL && ShipDefForModel(@"cap:Carrier:concord") == NULL);
    // The game's own tuning: the light fighter flies unshielded.
    const ShipDef *wasp = ShipDefNamed(@"wasp");
    CHECK(wasp && wasp->shield == 0 && wasp->hull > 1);
    const ShipDef *first = ShipDefNamed(names.firstObject);
    return first ? first->params : (ShipParams){ .maxSpeed = 150, .turnRate = 1 };
}

static void CheckShipMove(void) {
    ShipParams params = CheckShipDefinitions();
    ShipMoveState a, b;
    ShipMoveReset(&a, simd_make_float3(1, 2, 3), simd_quaternion(0.3f, simd_make_float3(0, 1, 0)));
    b = a;
    // The same commands through the same model give the same bits: that is
    // what lets the client predict what the server will compute.
    for (int i = 0; i < 1200; i++) {
        ShipMove(&a, &params, InputAt(i), TICK_DT);
        ShipMove(&b, &params, InputAt(i), TICK_DT);
    }
    CHECK(MoveEqual(&a, &b));
    CHECK(isfinite(a.origin.x) && isfinite(a.velocity.y) && NEAR(simd_length(a.orientation.vector), 1, 1e-3f));

    // Full throttle in a straight line settles at maxSpeed.
    ShipMoveState s;
    ShipMoveReset(&s, 0, simd_quaternion(0.0f, simd_make_float3(0, 1, 0)));
    for (int i = 0; i < 30 * 20; i++) ShipMove(&s, &params, (ShipInput){ 0, 0, 0, 1, false }, TICK_DT);
    CHECK(NEAR(simd_length(s.velocity), params.maxSpeed, 1.0f));
    CHECK(simd_dot(simd_normalize(s.velocity), QuatForward(s.orientation)) > 0.999f);

    // Boost drains, and once drained stays locked out until it has recharged.
    ShipMoveReset(&s, 0, simd_quaternion(0.0f, simd_make_float3(0, 1, 0)));
    for (int i = 0; i < 30 * 6; i++) ShipMove(&s, &params, (ShipInput){ 0, 0, 0, 1, true }, TICK_DT);
    CHECK(s.boostDepleted && !s.boosting);
    for (int i = 0; i < 3; i++) ShipMove(&s, &params, (ShipInput){ 0, 0, 0, 1, true }, TICK_DT);
    CHECK(!s.boosting);

    // A ship with no power coasts: heading and spin kept, speed bleeding off slowly.
    ShipMoveReset(&s, 0, simd_quaternion(0.0f, simd_make_float3(0, 1, 0)));
    s.angularVelocity = simd_make_float3(0.2f, 0, 0);
    s.throttle = 1;
    for (int i = 0; i < 30 * 10; i++) ShipDrift(&s, TICK_DT);
    CHECK(s.throttle == 0 && !s.boosting && NEAR(simd_length(s.angularVelocity), 0.2f, 1e-6f));
    CHECK(simd_length(s.velocity) > 30 && simd_length(s.velocity) < 60);     // 60 m/s at reset
    CHECK(simd_dot(QuatForward(s.orientation), simd_make_float3(0, 0, -1)) < 0.9f);
}

static void CheckAtmosphericFlight(void) {
    ShipParams p = { .maxSpeed = 55, .turnRate = 1, .pitchRate = 0.8f, .yawRate = 0.6f,
        .rollRate = 1.8f, .agility = 4, .grip = 0.7f, .gravity = 9.81f, .stallSpeed = 20,
        .boostSpeed = 1, .boostDrain = 0.2f, .boostRecharge = 0.1f };
    simd_quatf facing = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
    ShipMoveState cruise, stalled, repeat;
    ShipMoveReset(&cruise, simd_make_float3(0, 400, 0), facing);
    stalled = cruise;
    stalled.velocity = simd_make_float3(0, 0, -10);
    repeat = cruise;
    for (int i = 0; i < 300; i++) {
        ShipInput input = { .throttle = 1, .boost = true };
        ShipMove(&cruise, &p, input, TICK_DT);
        ShipMove(&repeat, &p, input, TICK_DT);
        ShipMove(&stalled, &p, (ShipInput){0}, TICK_DT);
    }
    CHECK(MoveEqual(&cruise, &repeat));
    CHECK(!cruise.boosting && NEAR(simd_length(cruise.velocity), p.maxSpeed, 0.1f));
    CHECK(NEAR(cruise.origin.y, 400, 0.01f) && stalled.origin.y < 300);
    ShipMoveState banked;
    ShipMoveReset(&banked, simd_make_float3(0, 400, 0), simd_quaternion((float)M_PI_2, simd_make_float3(0, 0, 1)));
    ShipMove(&banked, &p, (ShipInput){ .throttle = 1 }, TICK_DT);
    CHECK(banked.velocity.y < 0 && banked.origin.y < 400);
    LevelDef *bad = LevelCreate(@{ @"environment": @"invalid" });
    CHECK(bad->problems.count > 0);
    LevelRelease(bad);
}

static void CheckAimAssist(void) {
    simd_float3 fwd = simd_make_float3(0, 0, -1), muzzle = 0, still = 0;
    float speed = 900, range = 900 * 1.6f, cone = 3 * (float)M_PI / 180;
    // A target 1 km dead ahead crossing at 30 m/s: its lead point is about 2
    // degrees off the nose, so the shot goes to where the bolt meets it.
    simd_float3 target = simd_make_float3(0, 0, -1000), tv = simd_make_float3(30, 0, 0);
    simd_float3 dir = AimAssist(fwd, muzzle, still, target, tv, speed, range, cone);
    CHECK(!Vec3Equal(dir, fwd));
    float t = simd_length(target) / speed;
    for (int i = 0; i < 4; i++) t = simd_length(target + tv * t) / speed;
    CHECK(NEAR(simd_length(dir), 1, 1e-4f));
    CHECK(simd_distance(dir * speed * t, target + tv * t) < 0.5f);
    // Outside the cone, beyond range, behind, or with the assist off: straight along the nose.
    CHECK(Vec3Equal(AimAssist(fwd, muzzle, still, simd_make_float3(200, 0, -1000), 0, speed, range, cone), fwd));
    CHECK(Vec3Equal(AimAssist(fwd, muzzle, still, simd_make_float3(0, 0, -3000), 0, speed, range, cone), fwd));
    CHECK(Vec3Equal(AimAssist(fwd, muzzle, still, simd_make_float3(0, 0, 500), 0, speed, range, cone), fwd));
    CHECK(Vec3Equal(AimAssist(fwd, muzzle, still, target, tv, speed, range, 0), fwd));
    // The shooter's velocity is part of the bolt's: chasing a target at the
    // same velocity, aim straight at it.
    simd_float3 v = simd_make_float3(30, 0, -140);
    dir = AimAssist(fwd, muzzle, v, simd_make_float3(10, 0, -800), v, speed, range, cone);
    CHECK(simd_dot(dir, simd_normalize(simd_make_float3(10, 0, -800))) > 0.99999f);
}

#pragma mark - Wire format

static EntityState Entity(uint16_t number, float x) {
    EntityState e = {0};
    e.number = number;
    e.kind = EntityFighter;
    e.team = 1;
    e.model = 3;
    e.name = 7;
    e.flags = EF_BOOST;
    e.origin = simd_make_float3(x, x * 2, -x);
    e.velocity = simd_make_float3(12.5f, -3.25f, 100);
    e.orientation = simd_normalize(simd_quaternion(0.7f, simd_normalize(simd_make_float3(1, 2, 3))));
    e.scale = 1;
    e.throttle = 0.75f;
    e.hull = 0.5f;
    e.shield = 0.25f;
    e.deadParts = 0x5;
    return e;
}

static void CheckEntityDeltas(void) {
    // Baseline: 1, 2, 3. New frame: 1 unchanged, 2 moved, 3 gone, 4 new.
    EntityState from[3] = { Entity(1, 10), Entity(2, 20), Entity(3, 30) };
    EntityState to[3] = { Entity(1, 10), Entity(2, 25), Entity(4, 40) };
    for (int i = 0; i < 3; i++) { QuantizeEntity(&from[i]); QuantizeEntity(&to[i]); }
    MsgWriter *w = [MsgWriter new];
    WritePacketEntities(w, from, 3, to, 3);
    MsgReader *r = [[MsgReader alloc] initWithData:w.data];
    NSMutableData *out = [NSMutableData data];
    CHECK(ReadPacketEntities(r, from, 3, out));
    CHECK(!r.overflow && r.remaining == 0);
    CHECK(out.length == 3 * sizeof(EntityState));
    const EntityState *got = out.bytes;
    // The decoded states must equal the quantized ones bit for bit: the
    // server keeps the quantized frame as the client's baseline for the
    // next delta, so any mismatch would be re-sent every frame.
    for (int i = 0; i < 3; i++) CHECK(EntityEqual(&got[i], &to[i]));
    // No baseline: every entity is written in full.
    w = [MsgWriter new];
    WritePacketEntities(w, NULL, 0, to, 3);
    r = [[MsgReader alloc] initWithData:w.data];
    out = [NSMutableData data];
    CHECK(ReadPacketEntities(r, NULL, 0, out) && out.length == 3 * sizeof(EntityState));
    got = out.bytes;
    for (int i = 0; i < 3; i++) CHECK(EntityEqual(&got[i], &to[i]));
    // A truncated packet is refused, not misread.
    r = [[MsgReader alloc] initWithData:[w.data subdataWithRange:NSMakeRange(0, w.data.length / 2)]];
    out = [NSMutableData data];
    CHECK(!ReadPacketEntities(r, NULL, 0, out));
}

static void CheckPlayerState(void) {
    PlayerState ps = {0};
    ShipParams params = { .maxSpeed = 160, .turnRate = 0.8f };
    ShipMoveReset(&ps.move, simd_make_float3(5, -6, 7), simd_normalize(simd_quaternion(0.2f, simd_make_float3(0, 0, 1))));
    ps.move.throttle = 0.35f;
    ps.move.boostEnergy = 0.5f;
    ps.move.boosting = 1;
    ps.params = params;
    ps.entity = 42;
    ps.alive = 1;
    ps.disabled = 1;
    ps.hull = 0.8f;
    ps.shield = 0.3f;
    ps.missionTime = 123.5f;
    for (int i = 0; i < MAX_STATS; i++) ps.stats[i] = (int16_t)(i * 37 - 100);
    ps.commandTime = 99999;
    ps.lastCommand = 777;
    MsgWriter *w = [MsgWriter new];
    WritePlayerState(w, &ps);
    PlayerState back = {0};
    MsgReader *r = [[MsgReader alloc] initWithData:w.data];
    ReadPlayerState(r, &back);
    CHECK(!r.overflow && r.remaining == 0);
    // Prediction replays commands from this state: it has to survive the
    // wire exactly, not approximately.
    CHECK(MoveEqual(&back.move, &ps.move));
    CHECK(memcmp(&back.params, &ps.params, sizeof ps.params) == 0);
    CHECK(back.entity == ps.entity && back.alive == ps.alive && back.disabled == 1 && back.hull == ps.hull && back.shield == ps.shield);
    CHECK(back.missionTime == ps.missionTime && back.commandTime == ps.commandTime && back.lastCommand == ps.lastCommand);
    CHECK(memcmp(back.stats, ps.stats, sizeof ps.stats) == 0);
}

static void CheckEventsAndCommands(void) {
    GameEvent events[4] = {
        { .type = EV_BOLT, .team = 1, .entity = 5, .id = 9, .pos = { 1, 2, 3 }, .vel = { 4, 5, 6 } },
        { .type = EV_EXPLOSION, .model = 2, .pos = { -1, -2, -3 }, .vel = { 0, 1, 0 }, .scale = 1.5f, .radius = 300 },
        { .type = EV_IMPACT, .flags = EVF_SHIELDED, .id = 9, .pos = { 7, 8, 9 } },
        { .type = EV_DAMAGE, .entity = 5, .flags = EVF_SHIELDED, .pos = { -0.6f, 0, 0.8f }, .scale = 0.35f },
    };
    MsgWriter *w = [MsgWriter new];
    WriteEvents(w, events, 4);
    MsgReader *r = [[MsgReader alloc] initWithData:w.data];
    NSData *back = ReadEvents(r);
    CHECK(!r.overflow && back.length == 4 * sizeof(GameEvent));
    const GameEvent *e = back.bytes;
    CHECK(e[0].type == EV_BOLT && e[0].entity == 5 && simd_equal(e[0].vel, events[0].vel));
    CHECK(e[1].type == EV_EXPLOSION && e[1].scale == 1.5f && e[1].radius == 300 && e[1].model == 2);
    CHECK(e[2].type == EV_IMPACT && e[2].flags == EVF_SHIELDED && simd_equal(e[2].pos, events[2].pos));
    CHECK(e[3].type == EV_DAMAGE && e[3].entity == 5 && e[3].flags == EVF_SHIELDED
          && simd_equal(e[3].pos, events[3].pos) && e[3].scale == events[3].scale);

    // A user command is quantized before use, so the client predicts on
    // exactly what the server runs.
    UserCmd c = { .sequence = 12345, .msec = 17, .buttons = BUTTON_FIRE | BUTTON_BOOST, .impulse = IMPULSE_TARGET,
                  .pitch = 0.123456f, .yaw = -0.98765f, .roll = 1.5f, .throttle = 0.333333f };
    QuantizeUserCmd(&c);
    CHECK(c.roll == 1.0f);
    w = [MsgWriter new];
    WriteUserCmd(w, &c);
    UserCmd d = {0};
    r = [[MsgReader alloc] initWithData:w.data];
    ReadUserCmd(r, &d);
    CHECK(!r.overflow && memcmp(&c, &d, sizeof c) == 0);
}

#pragma mark - Console

static void CheckConsole(void) {
    NSArray *tokens = [Cmd tokenize:@"set  name \"two words\" tail // a comment"];
    CHECK(tokens.count == 4 && [tokens[2] isEqualToString:@"two words"] && [tokens[3] isEqualToString:@"tail"]);

    Cvar *plain = [Cvar get:@"unit_plain" defaultValue:@"3" flags:0 help:@"test"];
    CHECK(plain.integer == 3 && NEAR(plain.value, 3, 0) && plain.boolValue);
    [Cmd execute:@"set unit_plain 4.5; unit_plain"];
    CHECK(NEAR(plain.value, 4.5f, 0) && plain.integer == 4);
    [Cmd execute:@"unit_plain 0"];
    CHECK(!plain.boolValue);
    [Cmd execute:@"reset unit_plain"];
    CHECK(plain.integer == 3);

    // Cheats are refused until sv_cheats is on, including a value set
    // before the owning module registered the cvar.
    [Cvar set:@"sv_cheats" value:@"0"];
    Cvar *cheat = [Cvar get:@"unit_cheat" defaultValue:@"0" flags:CVAR_CHEAT help:nil];
    CHECK(![cheat setString:@"1"] && cheat.integer == 0);
    [Cvar set:@"unit_early" value:@"1"];
    Cvar *early = [Cvar get:@"unit_early" defaultValue:@"0" flags:CVAR_CHEAT help:nil];
    CHECK(early.integer == 0);
    [Cvar set:@"sv_cheats" value:@"1"];
    CHECK([cheat setString:@"1"] && cheat.integer == 1);
    [Cvar set:@"sv_cheats" value:@"0"];

    // Change handlers fire on accepted changes only.
    __block int changes = 0;
    plain.onChange = ^(Cvar *c) { changes++; };
    [plain setInteger:8];
    [plain setInteger:8];
    CHECK(changes == 1 && plain.integer == 8);

    // Command line: +set runs early, the rest is queued for the buffer,
    // and wait defers what follows to the next frame.
    __block NSArray *mapArgs = nil;
    __block int echoes = 0;
    [Cmd add:@"unit_map" help:nil handler:^(NSArray<NSString *> *a) { mapArgs = a; }];
    [Cmd add:@"unit_echo" help:nil handler:^(NSArray<NSString *> *a) { echoes++; }];
    [Cmd setArguments:@[@"app", @"-NSSomething", @"YES", @"+set", @"unit_plain", @"11", @"+unit_map", @"3", @"+unit_echo"]];
    [Cmd executeEarlyCommands];
    CHECK(plain.integer == 11 && mapArgs == nil);
    [Cmd executeLateCommands];
    CHECK(mapArgs == nil);
    [Cmd executeBuffer];
    CHECK(mapArgs.count == 2 && [mapArgs[1] isEqualToString:@"3"] && echoes == 1);
    [Cmd addText:@"unit_echo\nwait\nunit_echo"];
    [Cmd executeBuffer];
    CHECK(echoes == 2);
    [Cmd executeBuffer];
    CHECK(echoes == 3);
    CHECK([Cmd exists:@"cvarlist"] && [Cmd exists:@"exec"]);
}

#pragma mark - Data

static void CheckCampaign(void) {
    NSArray *missions = CampaignMissions();
    CHECK(missions.count == 20);
    NSMutableSet *assets = [NSMutableSet set];
    for (CampaignMission *m in missions) {
        const LevelDef *level = m.level;
        CHECK(m.title.length && level->objectiveCount > 0 && level->problems.count == 0);
        for (int i = 0; i < level->entityCount; i++) {
            [assets addObject:level->entities[i].asset];
            CHECK(CapitalDefNamed(level->entities[i].asset) != NULL);   // every capital the campaign places has a definition
        }
    }
    CHECK(assets.count > 10);
    CHECK([CapitalModelName(@"Carrier", nil) isEqualToString:@"cap:Carrier:concord"]);
    CHECK([CapitalModelName(@"Carrier", @"skarn") isEqualToString:@"cap:Carrier:skarn"]);
}

// Every capital definition is complete and names a hull style that exists;
// the default style covers every material slot the models use; the
// projectile the game fires is defined.
// Pickup definitions name a real mesh and style, the deathmatch arena places
// them, and collecting tops a pilot up without passing what the ship holds.
static void CheckPickups(void) {
    NSArray<NSString *> *names = PickupDefNames();
    CHECK([names containsObject:@"torpedoes"] && [names containsObject:@"repair"]);
    for (NSString *name in names) {
        const PickupDef *def = PickupDefNamed(name);
        CHECK(def && def->radius > 0 && def->respawn > 0 && def->size > 0);
        if (!def) continue;
        CHECK(def->torpedoes > 0 || def->repair > 0);
        NSDictionary *style = DefinitionJSON(@"Styles", @(def->style));
        CHECK(style != nil);
        for (NSString *slot in style) {
            NSString *baked = [style[slot] isKindOfClass:NSDictionary.class] ? style[slot][@"baked"] : nil;
            if (baked) CHECK(FSURL(@"Textures", baked, @"png") != nil);
        }
        CHECK(FSURL(@"Models/Capital", @(def->asset), @"obj") != nil);
        CHECK(PickupDefForModel(PickupModelName(name)) == def);
    }
    CHECK(PickupDefNamed(@"no-such-pickup") == NULL && PickupDefForModel(@"proj:torpedo") == NULL);

    const LevelDef *arena = LevelNamed(@"lan-dogfight");
    CHECK(arena && arena->pickupCount >= 2 && arena->problems.count == 0);
    LevelDef *bad = LevelCreate(@{ @"name": @"x", @"pickups": @[ @{ @"type": @"no-such-pickup" }, @{ @"pos": @[@0, @0, @0] } ] });
    CHECK(bad->pickupCount == 2 && bad->problems.count == 2);
    LevelRelease(bad);

    const PickupDef *torpedoes = PickupDefNamed(@"torpedoes"), *repair = PickupDefNamed(@"repair");
    if (!torpedoes || !repair) return;
    PilotStores full = { .torpedoes = 4, .torpedoCapacity = 4, .hull = 1, .maxHull = 1 };
    PilotStores s = full;
    CHECK(!PickupApply(torpedoes, &s) && !PickupApply(repair, &s) && s.torpedoes == 4 && s.hull == 1);
    s = (PilotStores){ .torpedoes = 3, .torpedoCapacity = 4, .hull = 0.2f, .maxHull = 1.5f };
    CHECK(PickupApply(torpedoes, &s) && s.torpedoes == 4 && s.hull == 0.2f);
    CHECK(!PickupApply(torpedoes, &s));
    CHECK(PickupApply(repair, &s) && fabsf(s.hull - (0.2f + repair->repair * 1.5f)) < 1e-4f && s.torpedoes == 4);
    s.hull = 1.4f;
    CHECK(PickupApply(repair, &s) && s.hull == 1.5f);
    s = (PilotStores){ .torpedoes = 0, .torpedoCapacity = 0, .hull = 1, .maxHull = 1 };
    CHECK(!PickupApply(torpedoes, &s));     // a ship that carries none takes none
}

static void CheckDefinitions(void) {
    NSArray<NSString *> *capitals = CapitalDefNames();
    CHECK(capitals.count >= 20);
    NSMutableSet *styles = [NSMutableSet set];
    for (NSString *name in capitals) {
        const CapitalDef *def = CapitalDefNamed(name);
        CHECK(def != NULL);
        if (!def) continue;
        CHECK(strlen(def->className) > 0 && def->hp > 0 && strlen(def->style) > 0);
        CHECK(!(def->mine && !def->prop));   // a mine is a prop that goes off
        [styles addObject:@(def->style)];
    }
    CHECK(CapitalDefNamed(@"no-such-capital") == NULL);
    for (NSString *asset in @[@"AsteroidA", @"AsteroidB", @"AsteroidC"])
        CHECK(CapitalDefNamed(asset)->asteroid);
    CHECK(!CapitalDefNamed(@"Carrier")->asteroid);
    NSDictionary *defaults = DefinitionJSON(@"Styles", @"default");
    for (NSString *slot in @[@"Hull", @"HullDark", @"Glow", @"Lights", @"ShieldGen", @"Windows", @"Trim", @"Rock"])
        CHECK([defaults[slot] isKindOfClass:NSDictionary.class]);
    for (NSString *style in styles) {
        NSDictionary *d = DefinitionJSON(@"Styles", style);
        CHECK(d != nil);
        for (NSString *slot in d) {
            NSDictionary *spec = d[slot];
            CHECK([spec isKindOfClass:NSDictionary.class] && (spec[@"textures"] || spec[@"emissive"] || spec[@"color"] || spec[@"baked"]));
        }
    }
    const ProjectileDef *torpedo = ProjectileDefNamed(@"torpedo");
    CHECK(torpedo && torpedo->size > 0 && strlen(torpedo->glow) > 0);
    CHECK(ProjectileDefForModel(ProjectileModelName(@"torpedo")) == torpedo && ProjectileDefForModel(@"ship:wasp") == NULL);
    CheckPickups();
}

#pragma mark - Mission runtime

// A stand-in world for the mission runtime: units at positions, players that
// can be moved, and a record of what the runtime asked for.
@interface FakeUnit : NSObject <MissionUnit>
@property (nonatomic, strong) NSString *missionKey, *missionName, *group;
@property (nonatomic) simd_float3 missionPosition;
@property (nonatomic) float missionRadius, missionHullFraction;
@property (nonatomic) BOOL missionAlive, missionGone, missionAttacked, missionScanned, missionDisabled, missionCaptured;
@property (nonatomic) NSUInteger turrets, turretsAlive;
@end
@implementation FakeUnit
- (NSUInteger)missionPartsOfKind:(NSString *)kind alive:(BOOL)aliveOnly {
    return [kind isEqualToString:@"Turret"] ? (aliveOnly ? _turretsAlive : _turrets) : 0;
}
@end

static FakeUnit *Unit(NSString *key, NSString *group, simd_float3 p) {
    FakeUnit *u = [FakeUnit new];
    u.missionKey = key; u.missionName = key; u.group = group; u.missionPosition = p;
    u.missionRadius = 10; u.missionHullFraction = 1; u.missionAlive = YES;
    return u;
}

@interface FakeWorld : NSObject <MissionWorld>
@property (nonatomic) NSMutableArray<FakeUnit *> *units, *players;
@property (nonatomic) NSMutableDictionary<NSString *, FakeUnit *> *held;
@property (nonatomic) NSMutableArray<NSString *> *radio, *banners;
@property (nonatomic) NSDictionary<NSString *, NSValue *> *navs;
@property (nonatomic) NSString *nav, *lastObjectives;
@property (nonatomic) MissionRunner *runner;
@property (nonatomic) int ended;      // 0 running, 1 success, 2 failure
@property (nonatomic) int reinforced;
@property (nonatomic) NSArray<NSString *> *results;
@end
@implementation FakeWorld
- (instancetype)init {
    if ((self = [super init])) {
        _units = [NSMutableArray array]; _players = [NSMutableArray array]; _held = [NSMutableDictionary dictionary];
        _radio = [NSMutableArray array]; _banners = [NSMutableArray array];
    }
    return self;
}
- (NSArray *)missionUnitsNamed:(NSString *)name {
    NSMutableArray *a = [NSMutableArray array];
    for (FakeUnit *u in [_units arrayByAddingObjectsFromArray:_players])
        if ([u.missionKey isEqualToString:name] || [u.group isEqualToString:name]) [a addObject:u];
    return a;
}
- (NSArray *)missionPlayers { return _players; }
- (NSArray *)missionNavs { return _navs.allKeys; }
- (BOOL)missionNav:(NSString *)nav position:(simd_float3 *)p {
    NSValue *v = _navs[nav];
    if (!v) return NO;
    [v getValue:p size:sizeof *p];
    return YES;
}
- (void)missionSpawn:(NSString *)name {
    FakeUnit *u = _held[name];
    if (!u) return;
    [_held removeObjectForKey:name];
    [_units addObject:u];
    [_runner noteSpawned:u.missionKey];
    [_runner noteSpawned:u.group];
}
- (void)missionReinforce:(NSString *)wave {
    for (FakeUnit *u in [_units copy])
        if ([u.group isEqualToString:wave]) {
            FakeUnit *again = Unit([u.missionKey stringByAppendingString:@"+"], wave, u.missionPosition);
            [_units addObject:again];
        }
    _reinforced++;
}
- (void)missionSetTeam:(NSString *)team ofUnits:(NSArray *)units {}
- (void)missionDepart:(id<MissionUnit>)unit { ((FakeUnit *)unit).missionGone = YES; ((FakeUnit *)unit).missionAlive = NO; }
- (void)missionCollect:(id<MissionUnit>)unit { ((FakeUnit *)unit).missionGone = YES; ((FakeUnit *)unit).missionAlive = NO; }
- (void)missionMarkScanned:(id<MissionUnit>)unit { ((FakeUnit *)unit).missionScanned = YES; }
- (void)missionDestroy:(id<MissionUnit>)unit { ((FakeUnit *)unit).missionAlive = NO; }
- (void)missionRadio:(NSString *)text from:(NSString *)from { [_radio addObject:text]; }
- (void)missionBanner:(NSString *)text alert:(BOOL)alert { [_banners addObject:text]; }
- (void)missionStatus:(NSString *)status forPlayer:(id<MissionUnit>)player {}
- (void)missionObjectives:(NSArray *)lines states:(NSString *)states summary:(NSString *)summary { _lastObjectives = states; }
- (void)missionCurrentNav:(NSString *)nav { _nav = nav; }
- (void)missionEnded:(BOOL)success results:(NSArray *)results { _ended = success ? 1 : 2; _results = results; }
- (void)missionLog:(NSString *)line {}
@end

static NSValue *V3(float x, float y, float z) { simd_float3 v = {x, y, z}; return [NSValue valueWithBytes:&v objCType:"[4f]"]; }

static void Run(FakeWorld *w, float seconds) {
    for (float t = 0; t < seconds && !w.ended; t += 0.05f) [w.runner update:0.05f];
}

static void CheckDawnPatrol(void) {
    NSString *saved = FSGame();
    FSSetGame(@"DawnPatrol");
    LevelDef *level = LevelCreate(FSJSON(FSURL(@"Levels", @"01-morning-patrol", @"json")));
    const ShipDef *aircraft = ShipDefNamed(@"se5a");
    CHECK(level && level->environment.terrain && !level->environment.model);
    LevelDef *both = LevelCreate(@{ @"environment": @{ @"terrain": @YES, @"model": @"PatrolLandscape" } });
    CHECK(both->problems.count > 0);
    LevelRelease(both);
    CHECK(aircraft && aircraft->params.gravity > 0 && aircraft->shield == 0 && aircraft->secondary.rounds == 0);
    CHECK(aircraft && !aircraft->texture[0] && aircraft->propeller.w > 0);
    CHECK([MissionRunner problemsWithLevel:level].count == 0);
    for (int outcome = 0; outcome < 2; outcome++) {
        FakeWorld *w = [FakeWorld new];
        NSMutableDictionary *navs = [NSMutableDictionary dictionary];
        for (int i = 0; i < level->navCount; i++) {
            simd_float3 v = level->navs[i].pos;
            navs[level->navs[i].identifier] = V3(v.x, v.y, v.z);
        }
        w.navs = navs;
        FakeUnit *player = Unit(@"player", nil, level->playerPos);
        [w.players addObject:player];
        FakeUnit *wing = Unit(@"Bennett", @"wing", level->playerPos);
        [w.units addObject:wing];
        w.held[@"patrol"] = Unit(@"Falke 1", @"patrol", level->waves[1].pos);
        w.runner = [[MissionRunner alloc] initWithLevel:level world:w];
        [w.runner noteSpawned:@"wing"];
        Run(w, 0.1f);
        CHECK(!w.ended && [w.runner objectiveNamed:@"return"].state == MissionObjectiveHidden);
        if (outcome) {
            player.missionAlive = NO;
            Run(w, 5);
            CHECK(w.ended == 2);
            continue;
        }
        for (int i = 0; i < 3; i++) {
            player.missionPosition = level->navs[i].pos;
            Run(w, 0.2f);
        }
        CHECK(!w.held[@"patrol"] && !w.ended);
        FakeUnit *second = Unit(@"Falke 2", @"patrol", level->waves[1].pos);
        [w.units addObject:second];
        [w.runner noteSpawned:second.missionKey];
        for (FakeUnit *enemy in [w missionUnitsNamed:@"patrol"]) enemy.missionAlive = NO;
        wing.missionAlive = NO;    // optional loss must not fail the patrol
        Run(w, 0.2f);
        CHECK(!w.ended && [w.runner objectiveNamed:@"return"].state == MissionObjectiveActive);
        player.missionPosition = level->navs[3].pos;
        Run(w, 5);
        CHECK(w.ended == 1 && [w.runner objectiveNamed:@"wingman"].state == MissionObjectiveFailed);
    }
    LevelRelease(level);
    FSSetGame(saved);
}

// A game-registered objective type (the escape hatch): complete once a flag is set.
@interface FlagObjective : MissionObjective @end
@implementation FlagObjective
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    if ([(id<MissionEventContext>)ctx flag:self.definition[@"flag"]]) [ctx objective:self becomes:MissionObjectiveComplete];
}
@end

static NSDictionary *TestLevelJSON(void) {
    return @{
        @"navs": @[@{ @"id": @"n1", @"pos": @[@0, @0, @(-1000)] }],
        @"objectives": @[
            @{ @"id": @"go", @"type": @"reach", @"navs": @[@"n1"], @"text": @"Reach N1" },
            @{ @"id": @"guard", @"type": @"protect", @"targets": @[@"relay"], @"text": @"Keep the relay" },
            @{ @"id": @"kill", @"type": @"destroy", @"targets": @[@"raiders"], @"after": @[@"go"], @"text": @"Destroy raiders" },
            @{ @"id": @"guns", @"type": @"disable", @"targets": @[@"relay"], @"kind": @"Turret", @"optional": @YES, @"text": @"Silence turrets" },
            @{ @"id": @"signal", @"type": @"test_flag", @"flag": @"signal", @"text": @"Wait for the signal" },
        ],
        @"events": @[
            @{ @"when": @{ @"nav": @"n1" }, @"do": @[@{ @"spawn": @"raiders" }] },
            @{ @"when": @{ @"spawned": @"raiders" }, @"do": @[@{ @"radio": @{ @"from": @"Control", @"text": @"Raiders!" } }] },
            @{ @"when": @{ @"all": @[@{ @"objective": @"kill" }, @{ @"time": @1 }] }, @"do": @[@{ @"set_flag": @"signal" }] },
            @{ @"when": @{ @"destroyed": @"relay" }, @"do": @[@{ @"radio": @{ @"from": @"Control", @"text": @"Relay lost" } }] },
        ],
    };
}

// Parsed once; lives for the process like a cached level.
static const LevelDef *TestLevel(void) {
    static LevelDef *level;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ level = LevelCreate(TestLevelJSON()); });
    return level;
}

static FakeWorld *StartTestLevel(void) {
    FakeWorld *w = [FakeWorld new];
    w.navs = @{ @"n1": V3(0, 0, -1000) };
    [w.players addObject:Unit(@"player", nil, simd_make_float3(0, 0, 0))];
    FakeUnit *relay = Unit(@"relay", nil, simd_make_float3(500, 0, 0));
    relay.turrets = relay.turretsAlive = 2;
    [w.units addObject:relay];
    w.held[@"raiders"] = Unit(@"raider1", @"raiders", simd_make_float3(0, 0, -1500));
    w.runner = [[MissionRunner alloc] initWithLevel:TestLevel() world:w];
    [w.runner noteSpawned:@"relay"];
    return w;
}

// Units that come and go by themselves: a raid launched from a carrier 2 s
// after the guard dies, which comes back once when wiped out; pickets that
// leave at 5 s; and the same raid kept aboard when its carrier is lost first.
static NSDictionary *ArrivalsLevelJSON(void) {
    return @{
        @"entities": @[@{ @"id": @"carrier", @"asset": @"Corvette" }, @{ @"id": @"guard", @"asset": @"Corvette" }],
        @"waves": @[
            @{ @"id": @"raid", @"ship": @"wasp", @"count": @2, @"mothership": @"carrier",
               @"arrival": @{ @"when": @{ @"destroyed": @"guard" }, @"delay": @2 },
               @"reinforcements": @{ @"count": @1, @"delay": @1 }, @"skill": @"ace", @"formation": @"vic" },
            @{ @"id": @"pickets", @"ship": @"wasp", @"departure": @{ @"when": @{ @"time": @5 } } },
        ],
        @"objectives": @[
            @{ @"id": @"kill", @"type": @"destroy", @"targets": @[@"raid"], @"text": @"Stop the raid" },
            @{ @"id": @"pick", @"type": @"destroy", @"targets": @[@"pickets"], @"optional": @YES, @"text": @"Catch the pickets" },
        ],
    };
}

static FakeWorld *StartArrivals(const LevelDef *level) {
    FakeWorld *w = [FakeWorld new];
    [w.players addObject:Unit(@"player", nil, 0)];
    [w.units addObject:Unit(@"carrier", nil, 0)];
    [w.units addObject:Unit(@"guard", nil, 0)];
    [w.units addObject:Unit(@"picket", @"pickets", 0)];
    w.held[@"raid"] = Unit(@"raider", @"raid", 0);
    w.runner = [[MissionRunner alloc] initWithLevel:level world:w];
    for (NSString *n in @[@"carrier", @"guard", @"pickets"]) [w.runner noteSpawned:n];
    return w;
}

static FakeUnit *UnitKeyed(FakeWorld *w, NSString *key) {
    for (FakeUnit *u in w.units) if ([u.missionKey isEqualToString:key]) return u;
    return nil;
}

static void CheckArrivals(void) {
    LevelDef *level = LevelCreate(ArrivalsLevelJSON());
    const LevelWave *raid = LevelWaveNamed(level, @"raid"), *pickets = LevelWaveNamed(level, @"pickets");
    CHECK(raid->hold && raid->arrival.delay == 2 && raid->arrival.when[@"destroyed"] && [raid->mothership isEqualToString:@"carrier"]);
    CHECK(raid->reinforcements == 1 && raid->reinforcementDelay == 1);
    CHECK(raid->skill == LevelSkillAce && raid->formation == LevelFormationVic);
    CHECK(!pickets->hold && pickets->departure.when && pickets->skill == LevelSkillDefault && pickets->formation == LevelFormationScatter);
    CHECK([MissionRunner problemsWithLevel:level].count == 0);

    // Shapes, names and triggers are checked.
    LevelDef *bad = LevelCreate(@{
        @"entities": @[@{ @"id": @"e", @"asset": @"Corvette", @"departure": @{ @"delay": @3 } }],
        @"waves": @[@{ @"id": @"w", @"ship": @"wasp", @"skill": @"legend", @"formation": @"blob", @"mothership": @"nobody",
                       @"reinforcements": @3, @"arrival": @{ @"when": @{ @"eclipse": @YES } } }],
    });
    CHECK(bad->problems.count == 5 && [MissionRunner problemsWithLevel:bad].count == 6);
    LevelRelease(bad);

    // The raid arrives 2 s after the guard dies.
    FakeWorld *w = StartArrivals(level);
    Run(w, 1);
    CHECK(!UnitKeyed(w, @"raider"));
    UnitKeyed(w, @"guard").missionAlive = NO;
    Run(w, 1);
    CHECK(!UnitKeyed(w, @"raider"));
    Run(w, 1.2f);
    CHECK(UnitKeyed(w, @"raider") && [w.runner objectiveNamed:@"kill"].state == MissionObjectiveActive);
    // Wiped out, it is not yet destroyed: one more flight comes a second later.
    UnitKeyed(w, @"raider").missionAlive = NO;
    Run(w, 0.5f);
    CHECK(w.reinforced == 0 && [w.runner objectiveNamed:@"kill"].state == MissionObjectiveActive && [w.runner expecting:@"raid"]);
    Run(w, 0.75f);
    CHECK(w.reinforced == 1 && UnitKeyed(w, @"raider+") && ![w.runner expecting:@"raid"]);
    // The pickets leave at 5 s: the optional objective to catch them fails.
    Run(w, 1.5f);
    CHECK(UnitKeyed(w, @"picket").missionGone && [w.runner objectiveNamed:@"pick"].state == MissionObjectiveFailed);
    UnitKeyed(w, @"raider+").missionAlive = NO;
    Run(w, 10);
    CHECK(w.ended == 1 && w.reinforced == 1);

    // With its carrier lost first, the raid never launches.
    w = StartArrivals(level);
    UnitKeyed(w, @"carrier").missionAlive = NO;
    UnitKeyed(w, @"guard").missionAlive = NO;
    Run(w, 5);
    CHECK(!UnitKeyed(w, @"raider") && w.held[@"raid"] && ![w.runner expecting:@"raid"]);
    LevelRelease(level);
}

// attacked, scanned and disabled read what the world reports about the units
// by a name; scanned and disabled need all of them.
static void CheckUnitStateTriggers(void) {
    NSArray *alternatives = @[@"Taking fire!", @"Cover me!"];
    NSDictionary *radioEvent = @{ @"when": @{ @"time": @0 },
        @"do": @[@{ @"radio": @{ @"from": @"Lancer 2", @"text": alternatives } }] };
    CHECK([MissionEvents problemsWithEvents:@[radioEvent]].count == 0);
    CHECK(([MissionEvents problemsWithEvents:@[@{ @"when": @{ @"time": @0 },
        @"do": @[@{ @"radio": @{ @"from": @"Lancer 2", @"text": @[@"Cover me!", @7] } }] }]].count > 0));
    CHECK(([MissionEvents problemsWithEvents:@[@{ @"when": @{ @"time": @0 },
        @"do": @[@{ @"radio": @{ @"from": @"Lancer 2", @"text": @[] } }] }]].count > 0));
    LevelDef *radioLevel = LevelCreate(@{ @"events": @[radioEvent] });
    FakeWorld *radioWorld = [FakeWorld new];
    radioWorld.runner = [[MissionRunner alloc] initWithLevel:radioLevel world:radioWorld];
    Run(radioWorld, 0.1f);
    CHECK(radioWorld.radio.count == 1 && [alternatives containsObject:radioWorld.radio.firstObject]);
    Run(radioWorld, 0.1f);
    CHECK(radioWorld.radio.count == 1);
    LevelRelease(radioLevel);
    LevelDef *level = LevelCreate(@{
        @"events": @[
            @{ @"when": @{ @"attacked": @"convoy" }, @"do": @[@{ @"set_flag": @"hit" }] },
            @{ @"when": @{ @"scanned": @[@"convoy"] }, @"do": @[@{ @"set_flag": @"scanned" }] },
            @{ @"when": @{ @"disabled": @"convoy" }, @"do": @[@{ @"set_flag": @"disabled" }] },
        ],
    });
    CHECK([MissionRunner problemsWithLevel:level].count == 0);
    FakeWorld *w = [FakeWorld new];
    FakeUnit *a = Unit(@"a", @"convoy", 0), *b = Unit(@"b", @"convoy", 0);
    w.runner = [[MissionRunner alloc] initWithLevel:level world:w];
    Run(w, 0.5f);
    CHECK(![w.runner flag:@"hit"] && ![w.runner flag:@"scanned"] && ![w.runner flag:@"disabled"]);   // nobody has arrived
    [w.units addObjectsFromArray:@[a, b]];
    Run(w, 0.5f);
    CHECK(![w.runner flag:@"hit"]);
    a.missionAttacked = YES;
    Run(w, 0.1f);
    CHECK([w.runner flag:@"hit"]);       // one is enough
    [w missionMarkScanned:a]; a.missionDisabled = YES;
    Run(w, 0.1f);
    CHECK(![w.runner flag:@"scanned"] && ![w.runner flag:@"disabled"]);   // both are needed
    [w missionMarkScanned:b]; b.missionDisabled = YES;
    Run(w, 0.1f);
    CHECK([w.runner flag:@"scanned"] && [w.runner flag:@"disabled"]);
    LevelRelease(level);
}

// The captured trigger needs every unit of the name captured; the capture
// objective completes then, and fails when a target dies first.
static void CheckCapture(void) {
    LevelDef *level = LevelCreate(@{
        @"events": @[@{ @"when": @{ @"captured": @"prize" }, @"do": @[@{ @"set_flag": @"taken" }] }],
        @"objectives": @[
            @{ @"id": @"take", @"type": @"capture", @"targets": @[@"prize"], @"text": @"Capture the prize" },
            @{ @"id": @"lost", @"type": @"capture", @"targets": @[@"other"], @"text": @"Capture the other" },
        ],
    });
    CHECK([MissionRunner problemsWithLevel:level].count == 0);
    CHECK([MissionRunner problemsWithLevel:LevelCreate(@{ @"objectives": @[@{ @"id": @"x", @"type": @"capture", @"text": @"?" }] })].count == 1);
    FakeWorld *w = [FakeWorld new];
    FakeUnit *a = Unit(@"a", @"prize", 0), *b = Unit(@"b", @"prize", 0), *other = Unit(@"o", @"other", 0);
    [w.units addObjectsFromArray:@[a, b, other]];
    w.runner = [[MissionRunner alloc] initWithLevel:level world:w];
    [w.runner noteSpawned:@"prize"]; [w.runner noteSpawned:@"other"];
    Run(w, 0.5f);
    CHECK([w.runner objectiveNamed:@"take"].state == MissionObjectiveActive && ![w.runner flag:@"taken"]);
    a.missionCaptured = YES;
    Run(w, 0.1f);
    CHECK([w.runner objectiveNamed:@"take"].state == MissionObjectiveActive && ![w.runner flag:@"taken"]);   // both are needed
    b.missionCaptured = YES;
    Run(w, 0.1f);
    CHECK([w.runner objectiveNamed:@"take"].state == MissionObjectiveComplete && [w.runner flag:@"taken"]);
    other.missionAlive = NO;
    Run(w, 0.1f);
    CHECK([w.runner objectiveNamed:@"lost"].state == MissionObjectiveFailed);
    LevelRelease(level);
}

// "percent" on destroy and protect, a single craft named by callsign, and the
// level's time limit.
static void CheckQuantifiersAndTimeLimit(void) {
    LevelDef *level = LevelCreate(@{
        @"waves": @[@{ @"id": @"flight", @"ship": @"wasp", @"count": @2, @"reinforcements": @{ @"count": @1, @"delay": @1 } }],
        @"objectives": @[
            @{ @"id": @"half", @"type": @"destroy", @"targets": @[@"flight"], @"percent": @50, @"text": @"Break the flight" },
            @{ @"id": @"ace", @"type": @"destroy", @"targets": @[@"Viper"], @"text": @"Kill Viper" },
            @{ @"id": @"convoy", @"type": @"protect", @"targets": @[@"haulers"], @"percent": @50, @"text": @"Save half the convoy" },
        ],
    });
    CHECK([MissionRunner problemsWithLevel:level].count == 0);
    FakeWorld *w = [FakeWorld new];
    [w.players addObject:Unit(@"player", nil, 0)];
    FakeUnit *a = Unit(@"Viper", @"flight", 0), *b = Unit(@"Cobra", @"flight", 0);
    NSMutableArray<FakeUnit *> *haulers = [NSMutableArray array];
    for (int i = 0; i < 4; i++) [haulers addObject:Unit([NSString stringWithFormat:@"h%d", i], @"haulers", 0)];
    [w.units addObjectsFromArray:@[a, b]];
    [w.units addObjectsFromArray:haulers];
    w.runner = [[MissionRunner alloc] initWithLevel:level world:w];
    for (NSString *n in @[@"flight", @"Viper", @"haulers"]) [w.runner noteSpawned:n];
    Run(w, 0.5f);
    CHECK([w.runner objectiveNamed:@"half"].state == MissionObjectiveActive);
    // Protect: losing two of four is within half, the third is not (before the
    // mission ends in success and settles every ongoing objective).
    haulers[0].missionAlive = NO; haulers[1].missionAlive = NO;
    Run(w, 0.1f);
    CHECK([w.runner objectiveNamed:@"convoy"].state == MissionObjectiveActive);
    haulers[2].missionAlive = NO;
    Run(w, 0.1f);
    CHECK([w.runner objectiveNamed:@"convoy"].state == MissionObjectiveFailed);
    // Four ships in all, one flight still to come: two dead is half. (The failed
    // protect ends the mission, but objectives keep updating until the debrief.)
    a.missionAlive = NO;
    Run(w, 0.1f);
    CHECK([w.runner objectiveNamed:@"half"].state == MissionObjectiveActive && [w.runner objectiveNamed:@"half"].progress.length);
    CHECK([w.runner objectiveNamed:@"ace"].state == MissionObjectiveComplete);   // a callsign alone names the target
    b.missionAlive = NO;
    Run(w, 0.1f);
    CHECK([w.runner objectiveNamed:@"half"].state == MissionObjectiveComplete);
    LevelRelease(level);

    // Bad values are definition problems.
    for (id v in @[@0, @101, @"most"]) {
        LevelDef *bad = LevelCreate(@{ @"objectives": @[@{ @"id": @"x", @"type": @"destroy", @"targets": @[@"t"], @"percent": v, @"text": @"?" }],
                                       @"timeLimit": v, @"onTimeLimit": @"draw" });
        CHECK([MissionRunner problemsWithLevel:bad].count >= 2);
        LevelRelease(bad);
    }

    // The time limit: warnings at a minute and ten seconds, then the outcome.
    for (int succeeds = 0; succeeds < 2; succeeds++) {
        level = LevelCreate(@{ @"timeLimit": @90, @"onTimeLimit": succeeds ? @"success" : @"failure",
                               @"objectives": @[@{ @"id": @"hold", @"type": @"survive", @"seconds": @500, @"text": @"Hold" }] });
        CHECK(level->timeLimit == 90 && level->timeLimitSucceeds == (succeeds == 1) && [MissionRunner problemsWithLevel:level].count == 0);
        w = [FakeWorld new];
        [w.players addObject:Unit(@"player", nil, 0)];
        w.runner = [[MissionRunner alloc] initWithLevel:level world:w];
        Run(w, 25);
        CHECK(w.radio.count == 0 && !w.runner.ending);
        Run(w, 10);
        CHECK([w.radio containsObject:@"{#mission.time_minute}"] && ![w.radio containsObject:@"{#mission.time_ten}"]);
        Run(w, 50);
        CHECK([w.radio containsObject:@"{#mission.time_ten}"] && !w.runner.ending);
        Run(w, 10);
        CHECK(w.runner.ending && w.runner.success == (succeeds == 1) && w.banners.lastObject != nil);
        Run(w, 10);
        CHECK(w.ended == (succeeds ? 1 : 2));
        LevelRelease(level);
    }
}

static void CheckMissionRuntime(void) {
    [MissionObjective registerType:@"test_flag" class:FlagObjective.class];

    // Every campaign level is valid for the runtime.
    for (CampaignMission *m in CampaignMissions()) {
        NSArray *problems = [MissionRunner problemsWithLevel:m.level];
        if (problems.count) fprintf(stderr, "mission %s: %s\n", m.levelName.UTF8String, problems.description.UTF8String);
        CHECK(problems.count == 0);
    }
    // Unknown types, triggers and actions are reported.
    LevelDef *bad = LevelCreate(@{ @"objectives": @[@{ @"id": @"x", @"type": @"teleport", @"text": @"?" }],
                                   @"events": @[@{ @"when": @{ @"moon": @1 }, @"do": @[@{ @"dance": @YES }] }] });
    CHECK([MissionRunner problemsWithLevel:bad].count == 3);
    LevelRelease(bad);
    // Fields of the wrong shape are reported by the level contract itself.
    LevelDef *odd = LevelCreate(@{ @"entities": @[@{ @"id": @"e" }, @"junk"], @"waves": @[@{ @"id": @"w" }],
                                   @"fields": @[@{ @"type": @"nebula" }], @"navs": @{} });
    CHECK(odd->entityCount == 1 && odd->waveCount == 1 && odd->problems.count == 5);
    CHECK(odd->waves[0].count == 1 && odd->waves[0].spread == 80 && [odd->waves[0].order isEqualToString:@"attack"]);
    CHECK(odd->entities[0].invulnerable == -1 && odd->entities[0].hullFraction == 1 && odd->entities[0].facing.z == -1);
    CHECK(odd->torpedoes == -1 && odd->rules.failWhenPlayersDown && odd->fields[0].kind == LevelFieldUnknown);
    LevelRelease(odd);
    LevelDef *escort = LevelCreate(@{ @"waves": @[@{ @"id": @"w", @"ship": @"wasp", @"order": @"escort:layer" }],
                                      @"objectives": @[@{ @"id": @"o", @"type": @"destroy", @"targets": @"layer" }] });
    CHECK([escort->waves[0].order isEqualToString:@"escort"] && [escort->waves[0].orderTarget isEqualToString:@"layer"]);
    CHECK([escort->objectives[0].targets isEqualToArray:@[@"layer"]] && LevelWaveNamed(escort, @"w") == &escort->waves[0]);
    CHECK(escort->problems.count == 1);     // "layer" is no unit here
    LevelRelease(escort);
    // Orders: every verb, its target and the problems with a wrong one.
    NSArray *navs = @[@{ @"id": @"n1" }, @{ @"id": @"n2" }];
    NSArray *units = @[@{ @"id": @"base", @"asset": @"Corvette" }];
    LevelDef *orders = LevelCreate(@{ @"navs": navs, @"entities": units, @"waves": @[
        @{ @"id": @"a", @"ship": @"wasp", @"order": @"attack-fighters" }, @{ @"id": @"b", @"ship": @"wasp", @"order": @"attack-capitals" },
        @{ @"id": @"c", @"ship": @"wasp", @"order": @"disable:base" }, @{ @"id": @"d", @"ship": @"wasp", @"order": @"evade" },
        @{ @"id": @"e", @"ship": @"wasp", @"order": @"ignore" }, @{ @"id": @"f", @"ship": @"wasp", @"order": @"patrol:n1,n2" },
        @{ @"id": @"g", @"ship": @"wasp", @"order": @"strike:a" }, @{ @"id": @"h", @"ship": @"wasp", @"name": @"Red", @"count": @2, @"order": @"escort:Red 2" },
        @{ @"id": @"i", @"ship": @"wasp", @"order": @"board:base", @"dockSeconds": @4 } ] });
    CHECK(orders->problems.count == 0);
    CHECK(orders->waves[8].dockSeconds == 4 && orders->waves[0].dockSeconds == 10);
    CHECK([orders->waves[5].order isEqualToString:@"patrol"] && [orders->waves[5].orderTarget isEqualToString:@"n1,n2"]);
    LevelRelease(orders);
    LevelDef *wrong = LevelCreate(@{ @"navs": navs, @"entities": units, @"waves": @[
        @{ @"id": @"a", @"ship": @"wasp", @"order": @"charge" }, @{ @"id": @"b", @"ship": @"wasp", @"order": @"disable" },
        @{ @"id": @"c", @"ship": @"wasp", @"order": @"disable:nobody" }, @{ @"id": @"d", @"ship": @"wasp", @"order": @"evade:base" },
        @{ @"id": @"e", @"ship": @"wasp", @"order": @"patrol:n1,n9" } ] });
    CHECK(wrong->problems.count == 5);
    LevelRelease(wrong);
    CHECK([MissionRunner problemsWithLevel:TestLevel()].count == 0);

    // Success: reach the nav, the held raiders arrive, destroy them, the
    // event sets the flag the game-registered objective waits for.
    FakeWorld *w = StartTestLevel();
    Run(w, 1);
    CHECK([w.nav isEqualToString:@"n1"] && w.units.count == 1);
    w.players[0].missionPosition = simd_make_float3(0, 0, -950);
    Run(w, 1);
    CHECK(w.units.count == 2 && [w.radio containsObject:@"Raiders!"]);
    CHECK([w.runner objectiveNamed:@"kill"].state == MissionObjectiveActive);
    w.units[1].missionAlive = NO;
    Run(w, 10);
    CHECK(w.ended == 1);
    CHECK([w.results[0] hasPrefix:@"+ Reach"] && [w.results[1] hasPrefix:@"+ Keep"]);   // ongoing protect completes with the mission
    CHECK([w.results[3] hasPrefix:@"- Silence"] && [w.results[3] containsString:@"{#mission.optional_suffix}"]);
    CHECK([w.banners containsObject:@"{#mission.complete}"]);

    // Failure: the protected relay is destroyed.
    w = StartTestLevel();
    Run(w, 1);
    w.units[0].missionAlive = NO;
    Run(w, 10);
    CHECK(w.ended == 2 && [w.radio containsObject:@"Relay lost"] && [w.banners containsObject:@"{#mission.failed}"]);

    // Failure: every player is down.
    w = StartTestLevel();
    w.players[0].missionAlive = NO;
    Run(w, 10);
    CHECK(w.ended == 2);

    // Failure: the only player's ship is disabled, alive but out of the fight.
    w = StartTestLevel();
    w.players[0].missionDisabled = YES;
    Run(w, 10);
    CHECK(w.ended == 2);

    CheckArrivals();
    CheckUnitStateTriggers();
    CheckCapture();
    CheckQuantifiersAndTimeLimit();

    // Tokens expand on the client.
    NSString *scanned = [L10nCatalogs()[@"en"][@"strings"][@"mission.scanned"] stringByReplacingOccurrencesOfString:@"%@" withString:@"Relay"];
    BOOL expanded = [L10nExpand(@"x {#mission.scanned\x1fRelay} y") isEqualToString:[@"x " stringByAppendingString:[scanned stringByAppendingString:@" y"]]];
    CHECK(expanded || ![L10nLocale() isEqualToString:@"en"]);
    CHECK([L10nExpand(@"plain") isEqualToString:@"plain"]);
    CHECK([L10nExpand(@"{#mission.scanned\x1f{#part.engine}}")
        isEqualToString:L10nFormat(@"mission.scanned", L10n(@"part.engine"))]);
    CHECK([L10nExpand(@"{#mission.arrived\x1f{#mission.scanned\x1fRelay}}")
        isEqualToString:L10nFormat(@"mission.arrived", L10nFormat(@"mission.scanned", @"Relay"))]);
    CHECK([L10nExpand(@"unfinished {#mission.scanned") isEqualToString:@"unfinished {#mission.scanned"]);
}

// The catalog lookups the UI relies on: English text, lists, formats, and the
// key itself when nothing has it. (Tools/validate_strings.py checks the files.)
// The story front end's data: every briefing builds pages from the cast and
// rooms in Story/, in the order storyDefaults lists, and a game can add a page kind.
static void CheckStory(void) {
    StoryRoom *plainBoard = [StoryRoom roomWithJSON:@{ @"board": @{ @"style": @"blackboard" } } identifier:@"plain"];
    StoryRoom *legacyBoard = [StoryRoom roomWithJSON:@{ @"board": @{} } identifier:@"legacy"];
    StoryRoom *unknownBoard = [StoryRoom roomWithJSON:@{ @"board": @{ @"style": @"future" } } identifier:@"unknown"];
    CHECK(plainBoard.hasBoard && plainBoard.boardStyle == StoryBoardStyleBlackboard);
    CHECK(legacyBoard.boardStyle == StoryBoardStyleHolographic && unknownBoard.boardStyle == StoryBoardStyleHolographic);
    // The search path: the game's folder over the engine's resources.
    CHECK(FSGames().count >= 1 && [FSGames() containsObject:FSGame()]);
    CHECK(FSURL(@"Data/Ships", @"wasp", @"json") && [FSURL(@"Data/Ships", @"wasp", @"json").path containsString:@"/Games/"]);
    CHECK(FSURL(@"Strings", @"en", @"json") && !FSURL(@"Data/Ships", @"no-such-ship", @"json"));
    NSDictionary *gameStrings = FSJSON(FSURL(@"Strings", @"en", @"json"))[@"strings"];
    if (gameStrings[@"game.title"]) CHECK([L10n(@"game.title") isEqualToString:gameStrings[@"game.title"]]);   // the game's catalog wins
    CHECK([L10n(@"menu.quit") length] > 0 && ![L10n(@"menu.quit") isEqualToString:@"menu.quit"]);               // the engine's still there
    // Levels by name, and the campaign's order over them.
    CHECK(LevelNames().count >= CampaignMissions().count && CampaignMissions().count > 0);
    for (NSUInteger i = 0; i < CampaignMissions().count; i++) {
        NSString *level = CampaignLevelName(i);
        CHECK([LevelNamed(level)->name isEqualToString:level] && CampaignIndexOfLevel(level) == i);
        CHECK([CampaignMissionAt(i).title isEqualToString:LevelNamed(level)->title] && CampaignMissionAt(i).level == LevelNamed(level));
    }
    CHECK(CampaignIndexOfLevel(@"no-such-level") == NSNotFound && !LevelNamed(@"no-such-level"));

    NSString *player = StoryPlayer();
    CHECK(player.length && StoryCharacterNamed(player));
    StoryDefaults *defaults = CampaignStoryDefaults();
    CHECK(StoryCharacterNamed(defaults.officer) && StoryRoomNamed(defaults.room));
    for (NSString *kind in defaults.briefingPages) CHECK([StoryBriefingPageKinds() containsObject:kind]);
    for (CampaignMission *mission in CampaignMissions()) {
        NSArray<BriefingPage *> *pages = StoryBriefingPages(mission);
        StoryRoom *room = StoryRoomNamed(mission.briefingRoom);
        CHECK(room && room.bezelCount >= 3 && room.size.x > 0 && room.size.y > 0);
        CHECK(StoryRoomNamed(mission.debriefRoom));
        CHECK(pages.count > mission.briefing.dialogue.lines.count);
        CHECK(pages.firstObject.dialogue);
        NSString *officer = mission.briefing.officer ?: defaults.officer;
        CHECK([pages.lastObject.portrait isEqualToString:StoryCharacterNamed(officer).portrait]);
        for (BriefingPage *page in pages) CHECK(page.text.length && page.channel.length && page.portrait);
    }
    // A step's camera and labels: ids or [x, z] points; malformed labels are dropped.
    BriefingStep *step = [BriefingStep stepWithJSON:@{
        @"caption": @"c", @"camera": @{ @"center": @"corvette", @"span": @2500 },
        @"labels": @[ @{ @"text": @"Kill zone", @"at": @[@1200, @-3400] }, @{ @"text": @"Lost", @"at": @[@1] }, @{ @"at": @"x" } ] }];
    CHECK([step.camera.center.identifier isEqualToString:@"corvette"] && step.camera.span == 2500);
    CHECK(step.labels.count == 1 && !step.labels[0].at.identifier && step.labels[0].at.position.y == -3400);
    CHECK(![BriefingStep stepWithJSON:@{ @"caption": @"c" }].camera);
    CHECK(![BriefingStep stepWithJSON:@{ @"caption": @"c" }].timed);
    BriefingStep *timed = [BriefingStep stepWithJSON:@{ @"caption": @"c", @"seconds": @3.5 }];
    CHECK(timed.timed && timed.seconds == 3.5f);
    // Keyword marks: removed from the text, ranges count visible characters.
    NSArray<NSValue *> *marks;
    CHECK([StoryPlainText(@"Kill *Corvette Vesk* now, *fast*.", &marks) isEqualToString:@"Kill Corvette Vesk now, fast."]);
    CHECK(marks.count == 2 && NSEqualRanges(marks[0].rangeValue, NSMakeRange(5, 13)) && NSEqualRanges(marks[1].rangeValue, NSMakeRange(24, 4)));
    CHECK([StoryPlainText(@"a ** b *unclosed", &marks) isEqualToString:@"a * b *unclosed"] && marks.count == 0);
    CHECK([StoryPlainText(@"plain", NULL) isEqualToString:@"plain"]);
    // A game-registered page kind, named by a mission's own page order.
    StoryRegisterBriefingPages(@"check_weather", ^NSArray *(CampaignMission *mission, StoryLine *officer) {
        return @[ [BriefingPage pageBy:officer text:@"Fog" channel:@"WX" step:nil readout:nil] ];
    });
    NSArray<BriefingPage *> *pages = StoryBriefingPagesOfKinds(CampaignMissionAt(0), @[ @"check_weather", @"intel" ]);
    CHECK(pages.count == 2 && [pages[0].text isEqualToString:@"Fog"] && pages[1].readout.count > 0);
}

// A game with a base searches its own folder, then the base's, then the
// engine's; the default game is unaffected.
static void CheckGameChain(void) {
    NSString *saved = FSGame();
    CHECK([FSGames() containsObject:@"ZCheckMod"] && ![saved isEqualToString:@"ZCheckMod"]);
    CHECK([FSGameManifest(@"ZCheckMod")[@"base"] isEqualToString:saved]);
    FSSetGame(@"ZCheckMod");
    CHECK([FSGameChain() isEqualToArray:(@[ @"ZCheckMod", saved ])]);
    CHECK([FSURL(@"Levels", @"check", @"json").path containsString:@"/ZCheckMod/"]);           // its own
    CHECK([FSURL(@"Data/Ships", @"wasp", @"json").path containsString:saved]);               // the base's
    // A ship that names none of the durability or secondary fields flies as
    // every fighter did before ships carried their own.
    const ShipDef *plain = ShipDefNamed(@"zcheck-plain");
    CHECK(plain && plain->hull == 1 && plain->shield == 1 && NEAR(plain->shieldRegen, 0.06f, 1e-6f));
    if (plain) {
        const ShipSecondary *w = &plain->secondary;
        CHECK(w->name[0] == 0 && w->projectile[0] == 0 && w->rounds == 0 && w->range == 2500 && w->launchSpeed == 120);
        CHECK(w->acceleration == 260 && w->maxSpeed == 420 && w->turn == 3 && w->life == 9 && NEAR(w->damage, 1.2f, 1e-6f));
        CHECK(w->capitalDamage == 4 && w->fuse == 10);
    }
    // Ion fire is off, and systems 1, unless a ship says so; aiGun inherits "ion" from gun.
    CHECK(plain && !plain->gun.ion && !plain->aiGun.ion && plain->systems == 1);
    const ShipDef *ionBoat = ShipDefNamed(@"zcheck-ionboat");
    CHECK(ionBoat && ionBoat->gun.ion && ionBoat->aiGun.ion && NEAR(ionBoat->systems, 0.4f, 1e-6f));
    CHECK(ionBoat && NEAR(ionBoat->gun.damage, 0.2f, 1e-6f) && NEAR(ionBoat->aiGun.damage, 0.3f, 1e-6f));
    // Its own ship (run-unit-checks.sh writes it) states durability and a secondary.
    const ShipDef *gunship = ShipDefNamed(@"zcheck-gunship");
    CHECK(gunship && NEAR(gunship->hull, 2.5f, 1e-6f) && gunship->shield == 0 && NEAR(gunship->shieldRegen, 0.2f, 1e-6f));
    if (gunship) {
        const ShipSecondary *w = &gunship->secondary;
        CHECK(!strcmp(w->name, "MISSILE") && !strcmp(w->shortName, "MSL") && !strcmp(w->projectile, "torpedo"));
        CHECK(w->rounds == 6 && w->range == 1800 && w->maxSpeed == 600 && NEAR(w->damage, 0.8f, 1e-6f) && w->capitalDamage == 2);
        CHECK(w->life == 9 && w->fuse == 10);   // unnamed fields keep their defaults
    }
    CHECK(FSURL(@"Strings", @"en", @"json") && FSURLsLayered(@"Strings", @"json").count >= 2); // and the engine's
    NSArray<NSURL *> *levels = FSURLs(@"Levels", @"json");
    CHECK([[levels valueForKey:@"lastPathComponent"] containsObject:@"check.json"] && levels.count > 1);
    FSSetGame(saved);
    CHECK([FSGameChain() isEqualToArray:(@[ saved ])]);
}

// Every other game in the bundle: its levels resolve on its own search path
// (its folder, then its base), every ship and capital they place is defined,
// and its campaign names only its levels.
static void CheckOtherGames(void) {
    NSString *saved = FSGame();
    for (NSString *game in FSGames()) {
        if ([game isEqualToString:saved] || [game hasPrefix:@"ZCheck"]) continue;
        FSSetGame(game);
        NSArray<NSURL *> *own = [NSBundle.mainBundle URLsForResourcesWithExtension:@"json"
                                                                     subdirectory:[@"Games" stringByAppendingPathComponent:[game stringByAppendingPathComponent:@"Levels"]]];
        CHECK(own.count > 0);
        for (NSURL *url in own) {
            LevelDef *level = LevelCreate(FSJSON(url));
            CHECK(level != NULL);
            if (!level) continue;
            CHECK(!level->playerShip || ShipDefNamed(level->playerShip) != NULL);
            for (int i = 0; i < level->entityCount; i++) CHECK(CapitalDefNamed(level->entities[i].asset) != NULL);
            for (int i = 0; i < level->waveCount; i++) CHECK(ShipDefNamed(level->waves[i].ship) != NULL);
            NSArray *problems = [MissionRunner problemsWithLevel:level];
            LevelRelease(level);
            if (problems.count) fprintf(stderr, "%s/%s: %s\n", game.UTF8String, url.lastPathComponent.UTF8String,
                                        [problems componentsJoinedByString:@"; "].UTF8String);
            CHECK(problems.count == 0);
        }
        NSDictionary *campaign = FSJSON(FSURL(@"Campaign", @"campaign", @"json"));
        for (NSDictionary *entry in campaign[@"missions"])
            CHECK([[own valueForKey:@"lastPathComponent"] containsObject:[entry[@"level"] stringByAppendingPathExtension:@"json"]]);
    }
    FSSetGame(saved);
}

static void CheckLocalization(void) {
    CHECK(L10nCatalogs()[@"en"] != nil && L10nCatalogs().count >= 2);
    CHECK(L10nLocale().length > 0);
    CHECK([L10n(@"no.such.key") isEqualToString:@"no.such.key"]);
    CHECK(L10nList(@"no.such.key").count == 0);
    CHECK(L10n(@"menu.quit").length > 0 && ![L10n(@"menu.quit") isEqualToString:@"menu.quit"]);
    CHECK(L10nList(@"hud.help").count > 1 && L10nList(@"menu.quit").count == 1);
    NSDictionary *en = L10nCatalogs()[@"en"][@"strings"];
    NSString *expected = [NSString stringWithFormat:en[@"hud.score"], 3, 1];
    if ([L10nLocale() isEqualToString:@"en"]) CHECK([L10nFormat(@"hud.score", 3, 1) isEqualToString:expected]);
    CHECK([expected containsString:@"3"] && [expected containsString:@"1"]);
}

static void CheckLANSettings(void) {
    LANMatchSettings settings = LANMatchSettingsDefault();
    settings.arena=@"arena"; settings.ship=@"executioner"; settings.fragLimit=25; settings.maxPilots=4;
    settings.matchSeconds=600; settings.respawnSeconds=5;
    LANLobbyInfo decoded;
    CHECK(LANLobbyDecode(LANLobbyEncode((LANLobbyInfo){.pilots=@[@"Игорь", @"Mira"], .settings=settings}), &decoded));
    CHECK(([decoded.pilots isEqual:@[@"Игорь", @"Mira"]]));
    CHECK(decoded.settings.fragLimit==25 && decoded.settings.maxPilots==4 && decoded.settings.matchSeconds==600 && decoded.settings.respawnSeconds==5);
    CHECK([decoded.settings.arena isEqual:@"arena"] && [decoded.settings.ship isEqual:@"executioner"]);
    CHECK(!LANLobbyDecode(@"[]", &decoded) && !LANLobbyDecode(@"{\"players\":[3]}", &decoded));
    CHECK(!LANMatchSettingsDecode(@"{\"kills\":\"ten\"}", &settings));
    settings=LANMatchSettingsNormalize((LANMatchSettings){.fragLimit=1000, .maxPilots=1, .matchSeconds=INFINITY, .respawnSeconds=NAN});
    CHECK(settings.fragLimit==100 && settings.maxPilots==2 && isfinite(settings.matchSeconds) && isfinite(settings.respawnSeconds));
}

int main(void) {
    @autoreleasepool {
        CheckShipMove();
        CheckAtmosphericFlight();
        CheckAimAssist();
        CheckEntityDeltas();
        CheckPlayerState();
        CheckEventsAndCommands();
        CheckLANSettings();
        CheckConsole();
        CheckCampaign();
        CheckDefinitions();
        CheckLocalization();
        CheckStory();
        CheckGameChain();
        CheckOtherGames();
        CheckMissionRuntime();
        CheckDawnPatrol();
        if (failures) {
            fprintf(stderr, "%d check(s) failed\n", failures);
            return 1;
        }
        printf("PASS: flight model, wire format, console, campaign, definition data, localization, mission runtime and story data\n");
    }
    return 0;
}
