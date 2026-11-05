// The level in this game's world: spawning entities, waves and fields from
// the level JSON, and the adapter the engine's mission runtime
// (Sources/Engine/Mission) runs objectives, events and rules through.
#import "Game.h"

static NSValue *Vec3Value(simd_float3 v) { return [NSValue valueWithBytes:&v objCType:"[4f]"]; }

static Team TeamNamed(NSString *s) {
    if ([s isEqualToString:@"enemy"]) return TeamEnemy;
    if ([s isEqualToString:@"neutral"]) return TeamNeutral;
    return TeamFriend;
}

static NSString *const kRed = @"red";
// Data/rules.json: the content this module names, so a game built on it
// (game.json "base") can rename its sides, ships and secondary weapon.
NSDictionary *GRules(void) {
    static NSDictionary *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id json = FSJSON(FSURL(@"Data", @"rules", @"json"));
        rules = [json isKindOfClass:NSDictionary.class] ? json : @{};
    });
    return rules;
}

static NSString *DefaultPlayerShip(void) { return GRules()[@"defaultShip"] ?: ShipDefNames().firstObject ?: @""; }

// What the cockpit calls a fighter of each side.
static NSString *FighterClassName(Team t) {
    NSString *side = t == TeamFriend ? @"friend" : (t == TeamEnemy ? @"enemy" : @"neutral");
    return GRules()[@"fighterClass"][side] ?: @"Fighter";
}

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
- (BOOL)missionGone { return NO; }
- (float)missionHullFraction { return clampf(self.hull, 0, 1); }
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
    for (GClient *c in _clients) {
        c.ship = nil;
        c.autopilot = nil;
        c.selected = nil;
        c.aimSubsystem = nil;
        c.inGame = NO;
        c.status = c.sentStatus = nil;
    }
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
    return p ? p.position : Vec3(_mission[@"player"][@"pos"]);
}

- (simd_float3)referenceForward {
    GFighter *p = [self leadPlayer];
    if (p) return p.forward;
    NSArray *f = _mission[@"player"][@"facing"];
    return f ? simd_normalize(Vec3(f)) : simd_make_float3(0, 0, -1);
}

- (void)spawnLevel:(NSString *)name {
    CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    [self clearWorld];
    _mission = LevelNamed(name) ?: @{ @"name": name ?: @"" };
    NSDictionary *mission = _mission;
    NSArray *problems = [MissionRunner problemsWithLevel:mission];
    for (NSString *p in problems) GPrint(@"Mission %@: %@", mission[@"name"], p);
    gi.configString(CS_LEVEL, [mission[@"name"] ?: name UTF8String]);
    uint32_t seed = 1337 + (uint32_t)[mission[@"seed"] intValue] * 7919;
    gi.configString(CS_SKY, [NSString stringWithFormat:@"%u", seed].UTF8String);
    gi.configString(CS_GAME, ShipDataIdentity().UTF8String);
    gi.configString(CS_TEAMS, GTeamRelations().UTF8String);
    NSDictionary *secondary = GRules()[@"secondary"];
    gi.configString(CS_SECONDARY_NAME, [secondary[@"name"] ?: @"SECONDARY" UTF8String]);
    gi.configString(CS_SECONDARY_SHORT, [secondary[@"short"] ?: @"SEC" UTF8String]);
    for (int i = 0; i < MAX_NAVS; i++) gi.configString(CS_NAVS + i, "");
    for (int t = 0; t < TeamCount; t++) _fighterClassNames[t] = gi.stringIndex(FighterClassName((Team)t).UTF8String);

    _missionTime = 0;
    _startTorpedoes = [mission[@"loadout"][@"torpedoes"] intValue];
    _navs = [NSMutableDictionary dictionary];
    _navNames = [NSMutableDictionary dictionary];
    _navOrder = [NSMutableArray array];
    for (NSDictionary *n in mission[@"navs"]) {
        simd_float3 p = Vec3(n[@"pos"]);
        _navs[n[@"id"]] = Vec3Value(p);
        _navNames[n[@"id"]] = n[@"name"];
        if (_navOrder.count < MAX_NAVS) {
            gi.configString(CS_NAVS + (int)_navOrder.count,
                            [NSString stringWithFormat:@"%@|%g|%g|%g", n[@"name"] ?: @"", p.x, p.y, p.z].UTF8String);
            [_navOrder addObject:n[@"id"]];
        }
    }
    _runner = [[MissionRunner alloc] initWithLevel:mission world:self];
    _held = [NSMutableDictionary dictionary];

    gi.modelIndex(ShipModelName(mission[@"player"][@"ship"] ?: DefaultPlayerShip()).UTF8String);
    gi.modelIndex(ProjectileModelName(GTorpedoProjectile()).UTF8String);
    // Units marked "hold" arrive when an event spawns them; precache them now.
    for (NSDictionary *e in mission[@"entities"]) {
        if ([e[@"hold"] boolValue]) {
            if (e[@"id"]) _held[e[@"id"]] = e;
            gi.modelIndex(CapitalModelName(e[@"asset"], e[@"style"]).UTF8String);
        } else {
            [self spawnEntity:e jump:NO];
        }
    }
    for (NSDictionary *f in mission[@"fields"]) [self buildField:f];
    for (NSDictionary *w in mission[@"waves"]) {
        if ([w[@"hold"] boolValue]) {
            _held[w[@"id"]] = w;
            if (ShipDefNamed(w[@"ship"])) gi.modelIndex(ShipModelName(w[@"ship"]).UTF8String);
        } else {
            [self spawnWave:w jump:NO];
        }
    }
    _running = YES;
    [self buildEntityStates];
    GPrint(@"Mission %@ spawned in %.2f s", mission[@"name"], CFAbsoluteTimeGetCurrent() - t0);
}

- (void)spawnPlayer:(GClient *)cl {
    NSDictionary *pl = _mission[@"player"];
    simd_float3 facing = pl[@"facing"] ? Vec3(pl[@"facing"]) : simd_make_float3(0, 0, -1);
    simd_quatf q = LookRotation(facing, simd_make_float3(0, 1, 0));
    // Wingmen form up to the right of the start point.
    simd_float3 pos = Vec3(pl[@"pos"]) + QuatRight(q) * 30.0f * cl.index;
    GFighter *s = [GFighter fighterWithShip:pl[@"ship"] ?: DefaultPlayerShip() ai:NO] ?: [GFighter fighterWithShip:DefaultPlayerShip() ai:NO];
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
        ap.aimError = 0.3f;
        cl.autopilot = ap;
    }
    [_runner resendObjectives];
}

- (GCapital *)spawnEntity:(NSDictionary *)e jump:(BOOL)jump {
    Team team = TeamNamed(e[@"team"]);
    GCapital *c = [GCapital capitalWithAsset:e[@"asset"] style:e[@"style"] team:team];
    c.number = [self allocEntity];
    c.identifier = e[@"id"];
    c.name = e[@"name"] ?: c.className;
    c.cargo = e[@"cargo"];
    c.group = e[@"group"];
    c.position = Vec3(e[@"pos"]);
    simd_float3 facing = e[@"facing"] ? Vec3(e[@"facing"]) : simd_make_float3(0, 0, -1);
    c.orientation = LookRotation(facing, simd_make_float3(0, 1, 0));
    NSMutableArray *path = [NSMutableArray array];
    for (NSArray *p in e[@"path"]) [path addObject:Vec3Value(Vec3(p))];
    c.path = path;
    c.speed = [e[@"speed"] floatValue];
    c.loop = [e[@"loop"] boolValue];
    c.spin = [e[@"spin"] floatValue];
    c.stealthRange = [e[@"stealth"] floatValue];
    if (e[@"invulnerable"]) c.invulnerable = [e[@"invulnerable"] boolValue];
    c.noHullDamage = [e[@"noHullDamage"] boolValue];
    if (e[@"hull"]) c.maxHull = c.hull = [e[@"hull"] floatValue];
    if (e[@"hullFraction"]) c.hull = c.maxHull * [e[@"hullFraction"] floatValue];
    [_capitals addObject:c];
    [_runner noteSpawned:c.identifier];
    [_runner noteSpawned:c.group];
    if (jump) [self jumpFlashAt:c.position scale:c.radius / 30.0f];
    return c;
}

- (void)spawnWave:(NSDictionary *)w jump:(BOOL)jump {
    int count = [w[@"count"] intValue] ?: 1;
    Team team = TeamNamed(w[@"team"]);
    simd_float3 centre = Vec3(w[@"pos"]);
    float spread = w[@"spread"] ? [w[@"spread"] floatValue] : 80;
    NSString *order = w[@"order"] ?: @"attack";
    NSArray<NSString *> *callsigns = w[@"callsigns"];
    NSRange colon = [order rangeOfString:@":"];
    simd_float3 ref = [self referencePosition];
    for (int i = 0; i < count; i++) {
        GPilot *p = [GPilot new];
        GFighter *s = [GFighter fighterWithShip:w[@"ship"] ai:YES];
        if (!s) break;
        s.number = [self allocEntity];
        s.team = team;
        s->params.maxSpeed += s.definition->aiSpeedSpread * (i % 3);   // a little variety within a wave
        simd_float3 pos = centre + randomUnit() * spread * (i == 0 ? 0.2f : 1.0f);
        simd_float3 toward = simd_length(ref - pos) > 1 ? simd_normalize(ref - pos) : simd_make_float3(0, 0, -1);
        if (team == TeamFriend) toward = [self referenceForward];
        [s resetAt:pos facing:LookRotation(toward + randomUnit() * 0.2f, simd_make_float3(0, 1, 0))];
        s.velocity = s.forward * 100;
        p.ship = s;
        p.mode = AIModeAttack;
        p.aimError = team == TeamFriend ? 0.5f : 0.6f + frand() * 0.8f;
        p.order = colon.location == NSNotFound ? order : [order substringToIndex:colon.location];
        p.orderTarget = colon.location == NSNotFound ? nil : [order substringFromIndex:colon.location + 1];
        p.wave = w[@"id"];
        if (i < callsigns.count) p.callsign = callsigns[i];
        else if (w[@"name"]) p.callsign = count > 1 ? [NSString stringWithFormat:@"%@ %d", w[@"name"], i + 2] : w[@"name"];
        if (p.callsign) s.nameIndex = gi.stringIndex(p.callsign.UTF8String);
        [_pilots addObject:p];
        if (jump) [self jumpFlashAt:pos scale:0.4f];
    }
    [_runner noteSpawned:w[@"id"]];
}

- (void)buildField:(NSDictionary *)f {
    NSString *type = f[@"type"];
    srand48([f[@"seed"] intValue] * 101 + 7);
    if ([type isEqualToString:@"asteroids"]) {
        simd_float3 centre = Vec3(f[@"center"]);
        float r = [f[@"radius"] floatValue];
        BOOL small = [f[@"small"] boolValue];
        for (int i = 0, n = [f[@"count"] intValue]; i < n; i++) {
            NSString *asset = small ? @"AsteroidC" : @[@"AsteroidA", @"AsteroidB", @"AsteroidC"][(int)(drand48() * 3)];
            GCapital *c = [GCapital capitalWithAsset:asset style:@"rock" team:TeamNeutral];
            c.number = [self allocEntity];
            c.identifier = [NSString stringWithFormat:@"rock%d", i];
            c.name = @"Asteroid";
            simd_float3 p;
            do { p = simd_make_float3(drand48() * 2 - 1, (drand48() * 2 - 1) * 0.45, drand48() * 2 - 1); } while (simd_length(p) > 1);
            c.position = centre + p * r;
            c.orientation = simd_quaternion((float)(drand48() * 6.28), simd_normalize(simd_make_float3(drand48() - 0.5, drand48() - 0.5, drand48() - 0.5) + 0.01f));
            [c setUniformScale:0.6f + (float)drand48() * 1.6f];
            c.spin = (float)(drand48() * 2 - 1) * 6;
            [_capitals addObject:c];
        }
    } else if ([type isEqualToString:@"mines"]) {
        simd_float3 centre = Vec3(f[@"center"]), size = Vec3(f[@"size"]);
        for (int i = 0, n = [f[@"count"] intValue]; i < n; i++) {
            GCapital *c = [GCapital capitalWithAsset:@"Mine" style:nil team:TeamEnemy];
            c.number = [self allocEntity];
            c.identifier = [NSString stringWithFormat:@"mine%d", i];
            c.name = @"Mine";
            c.group = f[@"group"];
            c.position = centre + simd_make_float3(drand48() - 0.5, drand48() - 0.5, drand48() - 0.5) * size;
            c.spin = 20;
            [_capitals addObject:c];
        }
        [_runner noteSpawned:f[@"group"]];
    } else if ([type isEqualToString:@"buoys"]) {
        for (NSString *nav in f[@"navs"]) {
            GCapital *c = [GCapital capitalWithAsset:@"NavBuoy" style:nil team:TeamNeutral];
            c.number = [self allocEntity];
            c.identifier = [@"buoy_" stringByAppendingString:nav];
            c.name = _navNames[nav];
            c.invulnerable = YES;
            c.position = [self navPosition:nav] + simd_make_float3(0, -25, 0);
            c.spin = 10;
            [_capitals addObject:c];
        }
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
    simd_float3 p = 0;
    [_navs[nav] getValue:&p size:sizeof p];
    return p;
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
- (NSArray<NSString *> *)missionNavs { return _navs.allKeys; }

- (BOOL)missionNav:(NSString *)nav position:(simd_float3 *)position {
    NSValue *v = nav ? _navs[nav] : nil;
    if (!v) return NO;
    [v getValue:position size:sizeof *position];
    return YES;
}

- (void)missionSpawn:(NSString *)name {
    NSDictionary *def = _held[name];
    if (!def) { GPrint(@"Mission: nothing held as \"%@\" to spawn", name); return; }
    [_held removeObjectForKey:name];
    if (def[@"ship"]) [self spawnWave:def jump:YES];
    else [self spawnEntity:def jump:YES];
}

- (void)missionSetTeam:(NSString *)team ofUnits:(NSArray<id<MissionUnit>> *)units {
    for (id u in units) {
        if ([u isKindOfClass:GCapital.class]) ((GCapital *)u).team = TeamNamed(team);
        else ((GFighter *)u).team = TeamNamed(team);
    }
}

- (void)missionDepart:(id<MissionUnit>)unit {
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
        if (s.alive) [self damageShip:s amount:s.shield + s.hull + 1 by:nil shake:0];
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
    GPrint(@"Mission %@ ended: %@ after %.0f s, kills %d", _mission[@"name"], success ? @"SUCCESS" : @"FAILED", _runner.time, kills);
    _over = YES;
    GCommand(nil, SVC_LEVEL_END, success ? @"1" : @"0", [results componentsJoinedByString:@"\n"], nil);
}

- (void)missionLog:(NSString *)line { GPrint(@"Mission %@: %@", _mission[@"name"], line); }

@end
