// The level in this game's world: spawning entities, waves and fields from
// the level (LevelDef), and the adapter the engine's mission runtime
// (Sources/Mission) runs objectives, events and rules through.
#import "Game.h"

static NSValue *Vec3Value(simd_float3 v) { return [NSValue valueWithBytes:&v objCType:"[4f]"]; }

// An empty level, for a name that has none.
static const LevelDef *EmptyLevel(NSString *name) {
    static LevelDef *empty;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ empty = LevelCreate(@{}); });
    return empty;
}

static Team TeamNamed(NSString *s) {
    if ([s isEqualToString:@"enemy"]) return TeamEnemy;
    if ([s isEqualToString:@"neutral"]) return TeamNeutral;
    return TeamFriend;
}

static NSString *const kRed = @"red";
// Data/rules.json: the content this module names, so a game built on it
// (game.json "base") can rename its sides, ships and secondary weapon. A ship
// whose definition names its own secondary overrides the weapon here.
//   { "defaultShip": "<ship>",
//     "secondary": { "projectile": "<projectile>", "name": "TORPEDO", "short": "TORP" },
//     "fighterClass": { "friend": "…", "enemy": "…", "neutral": "…" } }
const GameRules *GRules(void) {
    static GameRules rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *json = FSJSON(FSURL(@"Data", @"rules", @"json"));
        NSDictionary *secondary = JSONObject(json, @"secondary"), *fighters = JSONObject(json, @"fighterClass");
        rules = (GameRules){
            .defaultShip = JSONString(json, @"defaultShip") ?: ShipDefNames().firstObject ?: @"",
            .secondaryProjectile = JSONString(secondary, @"projectile") ?: @"torpedo",
            .secondaryName = JSONString(secondary, @"name") ?: @"SECONDARY",
            .secondaryShort = JSONString(secondary, @"short") ?: @"SEC",
        };
        NSString *sides[TeamCount];
        sides[TeamFriend] = @"friend"; sides[TeamEnemy] = @"enemy"; sides[TeamNeutral] = @"neutral";
        for (int t = 0; t < TeamCount; t++) rules.fighterClass[t] = JSONString(fighters, sides[t]) ?: @"Fighter";
    });
    return &rules;
}

static NSString *DefaultPlayerShip(void) { return GRules()->defaultShip; }

static NSString *PartKindName(SubsystemKind kind) {
    switch (kind) {
        case SubsystemTurret: return @"Turret";
        case SubsystemEngine: return @"Engine";
        case SubsystemShield: return @"Shield";
        case SubsystemCore: return @"Core";
    }
    return @"";
}

#pragma mark - Units

@interface GFighter (Mission) <MissionUnit>
@end
@implementation GFighter (Mission)
- (NSString *)missionKey { return [NSString stringWithFormat:@"e%u", self.number]; }
- (NSString *)missionName {
    for (GPilot *p in level->_pilots) if (p.ship == self && p.callsign) return p.callsign;
    return self.client.name ?: @(self.definition->displayName);
}
- (simd_float3)missionPosition { return self.position; }
- (float)missionRadius { return self.radius; }
- (BOOL)missionAlive { return self.alive; }
- (BOOL)missionGone { return self.departed; }
- (float)missionHullFraction { return self.hullFraction; }
- (BOOL)missionAttacked { return self.attacked; }
- (BOOL)missionScanned { return NO; }       // only capitals carry cargo to scan
- (BOOL)missionDisabled { return self.disabled; }
- (NSUInteger)missionPartsOfKind:(NSString *)kind alive:(BOOL)aliveOnly { return 0; }
@end

@interface GCapital (Mission) <MissionUnit>
@end
@implementation GCapital (Mission)
- (NSString *)missionKey { return self.identifier ?: [NSString stringWithFormat:@"e%u", self.number]; }
- (NSString *)missionName { return self.name; }
- (simd_float3)missionPosition { return self.position; }
- (float)missionRadius { return self.radius; }
- (BOOL)missionAlive { return self.alive && !self.departed; }
- (BOOL)missionGone { return self.departed || self.collected; }
- (float)missionHullFraction { return self.maxHull > 0 ? clampf(self.hull / self.maxHull, 0, 1) : 1; }
- (BOOL)missionAttacked { return self.attacked; }
- (BOOL)missionScanned { return self.scanned; }
- (BOOL)missionDisabled { return self.enginesDead; }
- (NSUInteger)missionPartsOfKind:(NSString *)kind alive:(BOOL)aliveOnly {
    for (SubsystemKind k = SubsystemTurret; k <= SubsystemCore; k++)
        if ([PartKindName(k) isEqualToString:kind]) return aliveOnly ? [self aliveCount:k] : [self totalCount:k];
    return 0;
}
@end

@interface GWorld (MissionWorld) <MissionWorld>
@end

@implementation GWorld (Mission)

#pragma mark - Setup

- (void)clearWorld {
    [_pilots removeAllObjects];
    [_capitals removeAllObjects];
    [_torpedoes removeAllObjects];
    [_explosionQueue removeAllObjects];
    for (int i = 0; i < MAX_BOLTS; i++) _bolts[i].active = NO;
    for (GClient *c in _clients) [c leaveLevel];
    _running = NO;
    _over = NO;
    _runner = nil;
    _currentNav = nil;
    _entityStates.length = 0;
}

// Where new arrivals point: the first player, or the mission start before
// anyone has spawned.
- (simd_float3)referencePosition {
    GFighter *p = [self leadPlayer];
    return p ? p.position : _level->playerPos;
}

- (simd_float3)referenceForward {
    GFighter *p = [self leadPlayer];
    return p ? p.forward : _level->playerFacing;
}

- (void)spawnLevel:(NSString *)name {
    CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    [self clearWorld];
    _level = LevelNamed(name) ?: EmptyLevel(name);
    const LevelDef *level = _level;
    NSString *levelName = level->name.length ? level->name : name ?: @"";
    for (NSString *p in [MissionRunner problemsWithLevel:level]) GPrint(@"Mission %@: %@", levelName, p);
    gi.configString(CS_LEVEL, levelName.UTF8String);
    uint32_t seed = 1337 + (uint32_t)level->seed * 7919;
    gi.configString(CS_SKY, [NSString stringWithFormat:@"%u", seed].UTF8String);
    gi.configString(CS_GAME, ShipDataIdentity().UTF8String);
    gi.configString(CS_TEAMS, GTeamRelations().UTF8String);
    // Every player flies the level's ship, so its secondary names the readouts.
    const ShipDef *playerShip = ShipDefNamed(level->playerShip ?: DefaultPlayerShip()) ?: ShipDefNamed(DefaultPlayerShip());
    gi.configString(CS_SECONDARY_NAME, GSecondaryName(playerShip).UTF8String);
    gi.configString(CS_SECONDARY_SHORT, GSecondaryShort(playerShip).UTF8String);
    for (int i = 0; i < MAX_NAVS; i++) gi.configString(CS_NAVS + i, "");
    for (int t = 0; t < TeamCount; t++) _fighterClassNames[t] = gi.stringIndex(GRules()->fighterClass[t].UTF8String);

    _missionTime = 0;
    _startTorpedoes = level->torpedoes >= 0 ? level->torpedoes : (playerShip ? playerShip->secondary.rounds : 0);
    _navOrder = [NSMutableArray array];
    for (int i = 0; i < level->navCount && _navOrder.count < MAX_NAVS; i++) {
        const LevelNav *n = &level->navs[i];
        gi.configString(CS_NAVS + (int)_navOrder.count,
                        [NSString stringWithFormat:@"%@|%g|%g|%g", n->name ?: @"", n->pos.x, n->pos.y, n->pos.z].UTF8String);
        [_navOrder addObject:n->identifier];
    }
    _runner = [[MissionRunner alloc] initWithLevel:level world:self];
    _heldEntities = [NSMutableDictionary dictionary];
    _heldWaves = [NSMutableDictionary dictionary];

    gi.modelIndex(ShipModelName(level->playerShip ?: DefaultPlayerShip()).UTF8String);
    gi.modelIndex(ProjectileModelName(GSecondaryProjectile(playerShip)).UTF8String);
    // Units marked "hold" arrive when an event spawns them; precache them now.
    for (int i = 0; i < level->entityCount; i++) {
        const LevelEntity *e = &level->entities[i];
        if (e->hold) {
            if (e->identifier) _heldEntities[e->identifier] = [NSValue valueWithPointer:e];
            gi.modelIndex(CapitalModelName(e->asset, e->style).UTF8String);
        } else {
            [self spawnEntity:e jump:NO];
        }
    }
    for (int i = 0; i < level->fieldCount; i++) [self buildField:&level->fields[i]];
    for (int i = 0; i < level->waveCount; i++) {
        const LevelWave *w = &level->waves[i];
        if (w->hold) {
            _heldWaves[w->identifier] = [NSValue valueWithPointer:w];
            if (ShipDefNamed(w->ship)) gi.modelIndex(ShipModelName(w->ship).UTF8String);
        } else {
            [self spawnWave:w jump:NO];
        }
    }
    _running = YES;
    [self buildEntityStates];
    GPrint(@"Mission %@ spawned in %.2f s", levelName, CFAbsoluteTimeGetCurrent() - t0);
}

- (void)spawnPlayer:(GClient *)cl {
    simd_quatf q = LookRotation(_level->playerFacing, simd_make_float3(0, 1, 0));
    // Wingmen form up to the right of the start point.
    simd_float3 pos = _level->playerPos + QuatRight(q) * 30.0f * cl.index;
    GFighter *s = [GFighter fighterWithShip:_level->playerShip ?: DefaultPlayerShip() ai:NO] ?: [GFighter fighterWithShip:DefaultPlayerShip() ai:NO];
    s.number = [self allocEntity];
    s.team = TeamFriend;
    s.client = cl;
    [s resetAt:pos facing:q];
    s->move.throttle = 0.5f;
    cl.ship = s;
    cl.torpedoes = _startTorpedoes;
    cl.kills = 0;
    cl.cmdTime = 0;
    cl.lastBump = -1;

    NSString *warp = GCvarString("g_warp");   // cheat: start next to an entity, looking at it
    if (warp.length && cl.index == 0)
        for (GCapital *c in _capitals)
            if ([c.identifier isEqualToString:warp]) {
                float k = GCvar("g_warpDistance");
                simd_float3 from = c.position + simd_normalize(simd_make_float3(0.8f, 0.35f, 1.0f)) * fmaxf(c.radius * k, 60);
                [s resetAt:from facing:LookRotation(c.position - from, simd_make_float3(0, 1, 0))];
                s->move.throttle = 0;
                s.velocity = 0;
            }
    if (GCvar("g_autopilot") && cl.index == 0) {
        GPilot *ap = [GPilot new];
        ap.ship = s;
        ap.order = @"attack";
        ap.skill = (PilotSkill){ .aimError = 0.3f, .jinkChance = 0.35f, .fireJitter = 0.25f, .reaction = 1.5f };
        cl.autopilot = ap;
    }
    [_runner resendObjectives];
}

- (GCapital *)spawnEntity:(const LevelEntity *)e jump:(BOOL)jump {
    GCapital *c = [GCapital capitalWithAsset:e->asset style:e->style team:TeamNamed(e->team)];
    c.number = [self allocEntity];
    c.identifier = e->identifier;
    c.name = e->name ?: c.className;
    c.cargo = e->cargo;
    c.group = e->group;
    c.position = e->pos;
    c.orientation = LookRotation(e->facing, simd_make_float3(0, 1, 0));
    NSMutableArray *path = [NSMutableArray array];
    for (int i = 0; i < e->pathCount; i++) [path addObject:Vec3Value(e->path[i])];
    c.path = path;
    c.speed = e->speed;
    c.loop = e->loop;
    c.spin = e->spin;
    c.stealthRange = e->stealth;
    if (e->invulnerable >= 0) c.invulnerable = e->invulnerable;
    c.noHullDamage = e->noHullDamage;
    if (e->hull > 0) c.maxHull = c.hull = e->hull;
    if (e->hullFraction != 1) c.hull = c.maxHull * e->hullFraction;
    [_capitals addObject:c];
    [_runner noteSpawned:c.identifier];
    [_runner noteSpawned:c.group];
    if (jump) [self jumpFlashAt:c.position scale:c.radius / 30.0f];
    return c;
}

// A formation slot in units of kFormationSpacing: x to the lead's right,
// y up, z behind. Slots past a pattern's end repeat it further back.
static const float kFormationSpacing = 40;
static simd_float3 FormationSlot(LevelFormation f, int i) {
    float side = i % 2 ? -1 : 1, rank = (i + 1) / 2;     // 0, 1 left, 1 right, 2 left, …
    switch (f) {
        case LevelFormationVic: return simd_make_float3(side * rank, 0, rank);
        case LevelFormationFingerFour: {
            static const simd_float3 four[4] = { { 0, 0, 0 }, { -1, 0, 1 }, { 1.5f, 0, 0.5f }, { 2.5f, 0, 1.5f } };
            return four[i % 4] + simd_make_float3(0, 0, 3.0f * (i / 4));
        }
        case LevelFormationLineAbreast: return simd_make_float3(side * rank, 0, 0);
        case LevelFormationLineAstern: return simd_make_float3(0, 0.25f * (i % 2), i);
        case LevelFormationEchelonLeft: return simd_make_float3(-i, 0, i);
        case LevelFormationEchelonRight: return simd_make_float3(i, 0, i);
        case LevelFormationDiamond: {
            static const simd_float3 diamond[4] = { { 0, 0, 0 }, { -1, 0, 1 }, { 1, 0, 1 }, { 0, 0, 2 } };
            return diamond[i % 4] + simd_make_float3(0, 0.5f * (i / 4), 2.5f * (i / 4));
        }
        case LevelFormationScatter: break;
    }
    return 0;
}

- (GCapital *)capitalNamed:(NSString *)identifier {
    for (GCapital *c in _capitals) if ([c.identifier isEqualToString:identifier]) return c;
    return nil;
}

// Below the hull, clear of it: there is no hangar in the models to aim for.
- (simd_float3)launchPointOf:(GCapital *)m {
    return m.position - [m worldDirection:simd_make_float3(0, 1, 0)] * (m.radius * 0.6f + 30);
}

- (void)spawnWave:(const LevelWave *)w jump:(BOOL)jump {
    int count = w->count;
    Team team = TeamNamed(w->team);
    simd_float3 ref = [self referencePosition];
    GCapital *carrier = w->mothership ? [self capitalNamed:w->mothership] : nil;
    if (carrier && !BodyAlive(carrier)) carrier = nil;
    // Where the lead arrives and which way the flight points: out of the
    // mothership's bay along its heading, or at pos toward the action
    // (enemies face the players, friends fly the players' way).
    simd_float3 origin = carrier ? [self launchPointOf:carrier] : w->pos;
    simd_float3 heading = carrier ? carrier.forward
                        : team == TeamFriend ? [self referenceForward]
                        : simd_length(ref - origin) > 1 ? simd_normalize(ref - origin) : simd_make_float3(0, 0, -1);
    simd_quatf flight = LookRotation(heading, simd_make_float3(0, 1, 0));
    BOOL scatter = w->formation == LevelFormationScatter;
    for (int i = 0; i < count; i++) {
        GPilot *p = [GPilot new];
        GFighter *s = [GFighter fighterWithShip:w->ship ai:YES];
        if (!s) break;
        s.number = [self allocEntity];
        s.team = team;
        s->params.maxSpeed += s.definition->aiSpeedSpread * (i % 3);   // a little variety within a wave
        simd_float3 pos, toward = heading;
        if (scatter && !carrier) {
            pos = origin + randomUnit() * w->spread * (i == 0 ? 0.2f : 1.0f);
            if (team != TeamFriend && simd_length(ref - pos) > 1) toward = simd_normalize(ref - pos);
            toward += randomUnit() * 0.2f;
        } else {
            simd_float3 slot = scatter ? simd_make_float3(0, 0, 1.5f * i) : FormationSlot(w->formation, i);
            pos = origin + simd_act(flight, simd_make_float3(slot.x, slot.y, slot.z) * kFormationSpacing);
        }
        [s resetAt:pos facing:LookRotation(toward, simd_make_float3(0, 1, 0))];
        s.velocity = s.forward * 100 + (carrier ? carrier.velocity : 0);
        p.ship = s;
        p.mode = AIModeAttack;
        p.skill = PilotSkillFor(w->skill, team);
        p.order = w->order;
        p.orderTarget = w->orderTarget;
        p.mothership = w->mothership;
        p.home = pos;
        p.wave = w->identifier;
        if (i < w->callsigns.count) p.callsign = w->callsigns[i];
        else if (w->name) p.callsign = count > 1 ? [NSString stringWithFormat:@"%@ %d", w->name, i + 2] : w->name;
        if (p.callsign) s.nameIndex = gi.stringIndex(p.callsign.UTF8String);
        [_pilots addObject:p];
        if (jump && !carrier) [self jumpFlashAt:pos scale:0.4f];
    }
    [_runner noteSpawned:w->identifier];
}

- (void)fighterLeaves:(GFighter *)s jump:(BOOL)jump {
    if (!s.alive) return;
    if (jump) [self jumpFlashAt:s.position scale:0.4f];
    s.alive = NO;
    s.departed = YES;
}

- (void)buildField:(const LevelField *)f {
    srand48(f->seed * 101 + 7);
    switch (f->kind) {
    case LevelFieldAsteroids:
        for (int i = 0; i < f->count; i++) {
            NSString *asset = f->small ? @"AsteroidC" : @[@"AsteroidA", @"AsteroidB", @"AsteroidC"][(int)(drand48() * 3)];
            GCapital *c = [GCapital capitalWithAsset:asset style:@"rock" team:TeamNeutral];
            c.number = [self allocEntity];
            c.identifier = [NSString stringWithFormat:@"rock%d", i];
            c.name = @"Asteroid";
            simd_float3 p;
            do { p = simd_make_float3(drand48() * 2 - 1, (drand48() * 2 - 1) * 0.45, drand48() * 2 - 1); } while (simd_length(p) > 1);
            c.position = f->center + p * f->radius;
            c.orientation = simd_quaternion((float)(drand48() * 6.28), simd_normalize(simd_make_float3(drand48() - 0.5, drand48() - 0.5, drand48() - 0.5) + 0.01f));
            [c setUniformScale:0.6f + (float)drand48() * 1.6f];
            c.spin = (float)(drand48() * 2 - 1) * 6;
            [_capitals addObject:c];
        }
        break;
    case LevelFieldMines:
        for (int i = 0; i < f->count; i++) {
            GCapital *c = [GCapital capitalWithAsset:@"Mine" style:nil team:TeamEnemy];
            c.number = [self allocEntity];
            c.identifier = [NSString stringWithFormat:@"mine%d", i];
            c.name = @"Mine";
            c.group = f->group;
            c.position = f->center + simd_make_float3(drand48() - 0.5, drand48() - 0.5, drand48() - 0.5) * f->size;
            c.spin = 20;
            [_capitals addObject:c];
        }
        [_runner noteSpawned:f->group];
        break;
    case LevelFieldBuoys:
        for (NSString *nav in f->navs) {
            GCapital *c = [GCapital capitalWithAsset:@"NavBuoy" style:nil team:TeamNeutral];
            c.number = [self allocEntity];
            c.identifier = [@"buoy_" stringByAppendingString:nav];
            const LevelNav *n = LevelNavNamed(_level, nav);
            c.name = n ? n->name : nav;
            c.invulnerable = YES;
            c.position = [self navPosition:nav] + simd_make_float3(0, -25, 0);
            c.spin = 10;
            [_capitals addObject:c];
        }
        break;
    case LevelFieldUnknown:
        break;
    }
}

- (void)jumpFlashAt:(simd_float3)p scale:(float)scale {
    GEvent((GameEvent){ .type = EV_JUMP, .pos = p, .scale = scale });
}

#pragma mark - Queries

// Units by entity id, group, wave id or pilot callsign.
- (NSArray *)unitsFor:(NSString *)name {
    NSMutableArray *u = [NSMutableArray array];
    if (!name) return u;
    for (GCapital *c in _capitals) if ([c.identifier isEqualToString:name] || [c.group isEqualToString:name]) [u addObject:c];
    for (GPilot *p in _pilots) if ([p.wave isEqualToString:name] || [p.callsign isEqualToString:name]) [u addObject:p.ship];
    return u;
}

- (simd_float3)navPosition:(NSString *)nav {
    const LevelNav *n = LevelNavNamed(_level, nav);
    return n ? n->pos : 0;
}

#pragma mark - Update

- (void)updateMission:(float)dt {
    for (GClient *c in _clients) c.status = nil;
    [_runner update:dt];
    _missionTime = _runner.time;
    for (GClient *c in _clients) {
        if (!c.inGame || [c.status ?: @"" isEqualToString:c.sentStatus ?: @""]) continue;
        c.sentStatus = c.status;
        GCommand(c, SVC_STATUS, c.status, nil, nil);
    }
}

@end

#pragma mark - MissionWorld

@implementation GWorld (MissionWorld)

- (NSArray<id<MissionUnit>> *)missionUnitsNamed:(NSString *)name { return [self unitsFor:name]; }
- (NSArray<id<MissionUnit>> *)missionPlayers { return [self playerShips]; }
- (NSArray<NSString *> *)missionNavs {
    NSMutableArray *navs = [NSMutableArray array];
    for (int i = 0; i < _level->navCount; i++) if (_level->navs[i].identifier) [navs addObject:_level->navs[i].identifier];
    return navs;
}

- (BOOL)missionNav:(NSString *)nav position:(simd_float3 *)position {
    const LevelNav *n = LevelNavNamed(_level, nav);
    if (n) *position = n->pos;
    return n != NULL;
}

- (void)missionSpawn:(NSString *)name {
    NSValue *wave = _heldWaves[name], *entity = _heldEntities[name];
    if (!wave && !entity) { GPrint(@"Mission: nothing held as \"%@\" to spawn", name); return; }
    [_heldWaves removeObjectForKey:name];
    [_heldEntities removeObjectForKey:name];
    if (wave) [self spawnWave:wave.pointerValue jump:YES];
    else [self spawnEntity:entity.pointerValue jump:YES];
}

- (void)missionReinforce:(NSString *)name {
    const LevelWave *w = LevelWaveNamed(_level, name);
    if (w) [self spawnWave:w jump:YES];
}

- (void)missionSetTeam:(NSString *)team ofUnits:(NSArray<id<MissionUnit>> *)units {
    for (id u in units) {
        if ([u isKindOfClass:GCapital.class]) ((GCapital *)u).team = TeamNamed(team);
        else ((GFighter *)u).team = TeamNamed(team);
    }
}

- (void)missionDepart:(id<MissionUnit>)unit {
    if ([(id)unit isKindOfClass:GFighter.class]) {
        for (GPilot *p in _pilots)
            if (p.ship == unit && p.leaving == PilotStaying) {
                p.leaving = BodyAlive([self capitalNamed:p.mothership]) ? PilotDocking : PilotJumping;
                p.leavingSince = _time;
            }
        return;
    }
    if (![(id)unit isKindOfClass:GCapital.class]) return;
    GCapital *c = (GCapital *)unit;
    if (c.departed) return;
    c.departed = YES;
    c.hidden = YES;
    [self jumpFlashAt:c.position scale:c.radius / 30.0f];
}

- (void)missionCollect:(id<MissionUnit>)unit {
    if (![(id)unit isKindOfClass:GCapital.class]) return;
    GCapital *c = (GCapital *)unit;
    c.collected = YES;
    c.alive = NO;
    c.hidden = YES;
    [self jumpFlashAt:c.position scale:0.2f];
}

- (void)missionMarkScanned:(id<MissionUnit>)unit {
    if ([(id)unit isKindOfClass:GCapital.class]) ((GCapital *)unit).scanned = YES;
}

- (void)missionDestroy:(id<MissionUnit>)unit {
    if ([(id)unit isKindOfClass:GFighter.class]) {
        GFighter *s = (GFighter *)unit;
        if (s.alive) [self harmShip:s amount:s.shield + s.hull + 1 by:nil shake:0];
    } else if ([(id)unit isKindOfClass:GCapital.class]) {
        GCapital *c = (GCapital *)unit;
        if (c.alive) [self destroyCapital:c];
    }
}

- (void)missionRadio:(NSString *)text from:(NSString *)from { GCommand(nil, SVC_RADIO, text, from, nil); }
- (void)missionBanner:(NSString *)text alert:(BOOL)alert { GCommand(nil, SVC_BANNER, text, alert ? kRed : nil, nil); }

- (void)missionStatus:(NSString *)status forPlayer:(id<MissionUnit>)player {
    if ([(id)player isKindOfClass:GFighter.class]) ((GFighter *)player).client.status = status;
}

- (void)missionObjectives:(NSArray<NSString *> *)lines states:(NSString *)states summary:(NSString *)summary {
    GCommand(nil, SVC_OBJECTIVES, [lines componentsJoinedByString:@"\n"], states, summary);
}

- (void)missionCurrentNav:(NSString *)nav { _currentNav = nav; }

- (void)missionEnded:(BOOL)success results:(NSArray<NSString *> *)results {
    int kills = 0;
    for (GClient *c in _clients) kills += c.kills;
    GPrint(@"Mission %@ ended: %@ after %.0f s, kills %d", _level->name, success ? @"SUCCESS" : @"FAILED", _runner.time, kills);
    _over = YES;
    GCommand(nil, SVC_LEVEL_END, success ? @"1" : @"0", [results componentsJoinedByString:@"\n"], nil);
}

- (void)missionLog:(NSString *)line { GPrint(@"Mission %@: %@", _level->name, line); }

@end
