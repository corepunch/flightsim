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
#import "MissionRunner.h"
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

#pragma mark - Mission runtime

// A stand-in world for the mission runtime: units at positions, players that
// can be moved, and a record of what the runtime asked for.
@interface FakeUnit : NSObject <MissionUnit>
@property (nonatomic, strong) NSString *missionKey, *missionName, *group;
@property (nonatomic) simd_float3 missionPosition;
@property (nonatomic) float missionRadius, missionHullFraction;
@property (nonatomic) BOOL missionAlive, missionGone;
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
- (void)missionSetTeam:(NSString *)team ofUnits:(NSArray *)units {}
- (void)missionDepart:(id<MissionUnit>)unit { ((FakeUnit *)unit).missionGone = YES; ((FakeUnit *)unit).missionAlive = NO; }
- (void)missionCollect:(id<MissionUnit>)unit { ((FakeUnit *)unit).missionGone = YES; ((FakeUnit *)unit).missionAlive = NO; }
- (void)missionMarkScanned:(id<MissionUnit>)unit {}
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

// A game-registered objective type (the escape hatch): complete once a flag is set.
@interface FlagObjective : MissionObjective @end
@implementation FlagObjective
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    if ([(id<MissionEventContext>)ctx flag:self.definition[@"flag"]]) [ctx objective:self becomes:MissionObjectiveComplete];
}
@end

static NSDictionary *TestLevel(void) {
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

static void CheckMissionRuntime(void) {
    [MissionObjective registerType:@"test_flag" class:FlagObjective.class];

    // Every campaign level is valid for the runtime.
    for (NSDictionary *m in CampaignMissions()) {
        NSArray *problems = [MissionRunner problemsWithLevel:m];
        if (problems.count) fprintf(stderr, "mission %s: %s\n", [m[@"id"] description].UTF8String, problems.description.UTF8String);
        CHECK(problems.count == 0);
    }
    // Unknown types, triggers and actions are reported.
    NSArray *bad = [MissionRunner problemsWithLevel:@{ @"objectives": @[@{ @"id": @"x", @"type": @"teleport", @"text": @"?" }],
                                                       @"events": @[@{ @"when": @{ @"moon": @1 }, @"do": @[@{ @"dance": @YES }] }] }];
    CHECK(bad.count == 3);
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

    // Tokens expand on the client.
    NSString *scanned = [L10nCatalogs()[@"en"][@"strings"][@"mission.scanned"] stringByReplacingOccurrencesOfString:@"%@" withString:@"Relay"];
    BOOL expanded = [L10nExpand(@"x {#mission.scanned\x1fRelay} y") isEqualToString:[@"x " stringByAppendingString:[scanned stringByAppendingString:@" y"]]];
    CHECK(expanded || ![L10nLocale() isEqualToString:@"en"]);
    CHECK([L10nExpand(@"plain") isEqualToString:@"plain"]);
}

// The catalog lookups the UI relies on: English text, lists, formats, and the
// key itself when nothing has it. (Tools/validate_strings.py checks the files.)
// The story front end's data: every briefing builds pages from the cast and
// rooms in Story/, in the order storyDefaults lists, and a game can add a page kind.
static void CheckStory(void) {
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
        CHECK([LevelNamed(level)[@"name"] isEqualToString:level] && CampaignIndexOfLevel(level) == i);
        CHECK([CampaignMission(i)[@"title"] isEqualToString:LevelNamed(level)[@"title"]] && CampaignMission(i)[@"briefing"]);
        CHECK(!LevelNamed(level)[@"briefing"]);   // the game module never sees the campaign's half
    }
    CHECK(CampaignIndexOfLevel(@"no-such-level") == NSNotFound && !LevelNamed(@"no-such-level"));

    NSString *player = StoryPlayer();
    CHECK(player.length && StoryCharacter(player));
    NSDictionary *defaults = CampaignData()[@"storyDefaults"];
    CHECK(StoryCharacter(defaults[@"officer"]) && StoryRoom(defaults[@"room"]));
    for (NSString *kind in defaults[@"briefingPages"]) CHECK([StoryBriefingPageKinds() containsObject:kind]);
    for (NSDictionary *mission in CampaignMissions()) {
        NSArray<NSDictionary *> *pages = StoryBriefingPages(mission);
        NSDictionary *room = StoryRoom(StoryBriefingRoom(mission));
        CHECK(room && [room[@"bezel"] count] >= 3 && [room[@"size"] count] == 2);
        CHECK(StoryRoom(StoryDebriefRoom(mission)));
        CHECK(pages.count > [mission[@"briefing"][@"dialogue"][@"lines"] count]);
        CHECK([pages.firstObject[@"dialogue"] boolValue]);
        NSString *officer = mission[@"briefing"][@"officer"] ?: defaults[@"officer"];
        CHECK([pages.lastObject[@"portrait"] isEqualToString:StoryCharacter(officer)[@"portrait"]]);
        for (NSDictionary *page in pages) CHECK([page[@"text"] length] && [page[@"channel"] length] && page[@"portrait"]);
    }
    // A game-registered page kind, named by a mission's own page order.
    StoryRegisterBriefingPages(@"check_weather", ^NSArray *(NSDictionary *mission, NSDictionary *officer) {
        return @[ @{ @"speaker": officer[@"speaker"], @"portrait": officer[@"portrait"], @"text": @"Fog", @"channel": @"WX" } ];
    });
    NSMutableDictionary *mission = [CampaignMission(0) mutableCopy];
    NSMutableDictionary *brief = [mission[@"briefing"] mutableCopy];
    brief[@"pages"] = @[ @"check_weather", @"intel" ];
    mission[@"briefing"] = brief;
    NSArray<NSDictionary *> *pages = StoryBriefingPages(mission);
    CHECK(pages.count == 2 && [pages[0][@"text"] isEqualToString:@"Fog"] && [pages[1][@"readout"] count] > 0);
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
            NSDictionary *level = FSJSON(url);
            NSString *player = level[@"player"][@"ship"];
            CHECK(!player || ShipDefNamed(player) != NULL);
            for (NSDictionary *e in level[@"entities"]) CHECK(CapitalDefNamed(e[@"asset"]) != NULL);
            for (NSDictionary *w in level[@"waves"]) CHECK(ShipDefNamed(w[@"ship"]) != NULL);
            NSArray *problems = [MissionRunner problemsWithLevel:level];
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
        CheckStory();
        CheckGameChain();
        CheckOtherGames();
        CheckMissionRuntime();
        if (failures) {
            fprintf(stderr, "%d check(s) failed\n", failures);
            return 1;
        }
        printf("PASS: flight model, wire format, console, campaign, definition data, localization, mission runtime and story data\n");
    }
    return 0;
}
