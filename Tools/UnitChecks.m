// Headless checks of the engine's shared core: the flight model, the wire
// format, the console and the campaign data. No window, no GPU, no game
// module: it links the Shared, Common and Net sources and runs anywhere a
// Mac can compile. Tools/run-unit-checks.sh builds and runs it.
#import <Foundation/Foundation.h>
#include "Protocol.h"
#include "ShipMove.h"
#include "SharedMath.h"
#import "Assets.h"
#import "Cvar.h"
#import "Cmd.h"
#import "NetProtocol.h"
#import "Localization.h"

static int failures;

// Resources/<directory>/<name>.json as a dictionary, from the check's own bundle.
static NSDictionary *DefinitionJSON(NSString *directory, NSString *name) {
    NSURL *url = [NSBundle.mainBundle URLForResource:name withExtension:@"json" subdirectory:directory];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
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
        CHECK([ShipModelName(name) isEqualToString:[@"ship:" stringByAppendingString:name]] && ShipDefForModel(ShipModelName(name)) == def);
    }
    CHECK(ShipDefNamed(@"no-such-ship") == NULL && ShipDefForModel(@"cap:Carrier:concord") == NULL);
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
    CHECK(back.entity == ps.entity && back.alive == ps.alive && back.hull == ps.hull && back.shield == ps.shield);
    CHECK(back.missionTime == ps.missionTime && back.commandTime == ps.commandTime && back.lastCommand == ps.lastCommand);
    CHECK(memcmp(back.stats, ps.stats, sizeof ps.stats) == 0);
}

static void CheckEventsAndCommands(void) {
    GameEvent events[3] = {
        { .type = EV_BOLT, .team = 1, .entity = 5, .id = 9, .pos = { 1, 2, 3 }, .vel = { 4, 5, 6 } },
        { .type = EV_EXPLOSION, .model = 2, .pos = { -1, -2, -3 }, .vel = { 0, 1, 0 }, .scale = 1.5f, .radius = 300 },
        { .type = EV_IMPACT, .flags = EVF_SHIELDED, .id = 9, .pos = { 7, 8, 9 } },
    };
    MsgWriter *w = [MsgWriter new];
    WriteEvents(w, events, 3);
    MsgReader *r = [[MsgReader alloc] initWithData:w.data];
    NSData *back = ReadEvents(r);
    CHECK(!r.overflow && back.length == 3 * sizeof(GameEvent));
    const GameEvent *e = back.bytes;
    CHECK(e[0].type == EV_BOLT && e[0].entity == 5 && simd_equal(e[0].vel, events[0].vel));
    CHECK(e[1].type == EV_EXPLOSION && e[1].scale == 1.5f && e[1].radius == 300 && e[1].model == 2);
    CHECK(e[2].type == EV_IMPACT && e[2].flags == EVF_SHIELDED && simd_equal(e[2].pos, events[2].pos));

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
    for (NSDictionary *m in missions) {
        CHECK([m[@"title"] isKindOfClass:NSString.class] && [m[@"objectives"] count] > 0);
        for (NSDictionary *e in m[@"entities"]) {
            [assets addObject:e[@"asset"]];
            CHECK(CapitalDefNamed(e[@"asset"]) != NULL);   // every capital the campaign places has a definition
        }
    }
    CHECK(assets.count > 10);
    CHECK([CapitalModelName(@"Carrier", nil) isEqualToString:@"cap:Carrier:concord"]);
    CHECK([CapitalModelName(@"Carrier", @"skarn") isEqualToString:@"cap:Carrier:skarn"]);
}

// Every capital definition is complete and names a hull style that exists;
// the default style covers every material slot the models use; the
// projectile the game fires is defined.
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
    NSDictionary *defaults = DefinitionJSON(@"Styles", @"default");
    for (NSString *slot in @[@"Hull", @"HullDark", @"Glow", @"Lights", @"ShieldGen", @"Windows", @"Trim", @"Rock"])
        CHECK([defaults[slot] isKindOfClass:NSDictionary.class]);
    for (NSString *style in styles) {
        NSDictionary *d = DefinitionJSON(@"Styles", style);
        CHECK(d != nil);
        for (NSString *slot in d) {
            NSDictionary *spec = d[slot];
            CHECK([spec isKindOfClass:NSDictionary.class] && (spec[@"textures"] || spec[@"emissive"] || spec[@"color"]));
        }
    }
    const ProjectileDef *torpedo = ProjectileDefNamed(@"torpedo");
    CHECK(torpedo && torpedo->size > 0 && strlen(torpedo->glow) > 0);
    CHECK(ProjectileDefForModel(ProjectileModelName(@"torpedo")) == torpedo && ProjectileDefForModel(@"ship:wasp") == NULL);
}

// The catalog lookups the UI relies on: English text, lists, formats, and the
// key itself when nothing has it. (Tools/validate_strings.py checks the files.)
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

int main(void) {
    @autoreleasepool {
        CheckShipMove();
        CheckEntityDeltas();
        CheckPlayerState();
        CheckEventsAndCommands();
        CheckConsole();
        CheckCampaign();
        CheckDefinitions();
        CheckLocalization();
        if (failures) {
            fprintf(stderr, "%d check(s) failed\n", failures);
            return 1;
        }
        printf("PASS: flight model, wire format, console, campaign, definition data and localization\n");
    }
    return 0;
}
