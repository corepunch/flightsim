// Mission setup from missions.json, arrivals, radio traffic and objectives.
#import "GLocal.h"

static NSValue *Vec3Value(simd_float3 v) { return [NSValue valueWithBytes:&v objCType:"[4f]"]; }

static Team TeamNamed(NSString *s) {
    if ([s isEqualToString:@"enemy"]) return TeamEnemy;
    if ([s isEqualToString:@"neutral"]) return TeamNeutral;
    return TeamFriend;
}

static NSString *const kRed = @"red";
static NSString *const kDefaultPlayerShip = @"executioner";

// What the cockpit calls a fighter of each side.
static NSString *FighterClassName(Team t) {
    return t == TeamFriend ? @"Concord fighter" : (t == TeamEnemy ? @"Skarn fighter" : @"Fighter");
}

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

- (void)spawnMission:(NSUInteger)index {
    CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    [self clearWorld];
    _missionIndex = index;
    _mission = CampaignMission(index);
    NSDictionary *mission = _mission;
    gi.configString(CS_MISSION, [NSString stringWithFormat:@"%lu", (unsigned long)index].UTF8String);
    uint32_t seed = 1337 + (uint32_t)[mission[@"id"] intValue] * 7919;
    gi.configString(CS_SKY, [NSString stringWithFormat:@"%u", seed].UTF8String);
    gi.configString(CS_GAME, "spacefight 1");
    gi.configString(CS_TEAMS, GTeamRelations().UTF8String);
    gi.configString(CS_SECONDARY_NAME, "TORPEDO");
    gi.configString(CS_SECONDARY_SHORT, "TORP");
    for (int i = 0; i < MAX_NAVS; i++) gi.configString(CS_NAVS + i, "");
    for (int t = 0; t < TeamCount; t++) _fighterClassNames[t] = gi.stringIndex(FighterClassName((Team)t).UTF8String);

    _missionTime = 0;
    _endAt = 0;
    _success = NO;
    _startTorpedoes = [mission[@"loadout"][@"torpedoes"] intValue];
    _spawned = [NSMutableSet setWithObject:@"start"];
    _navsVisited = [NSMutableSet set];
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
    NSMutableArray *objectives = [NSMutableArray array];
    for (NSDictionary *d in mission[@"objectives"]) {
        GObjective *o = [GObjective new];
        o.def = d;
        o.state = ObjectiveHidden;
        o.scanTime = [NSMutableDictionary dictionary];
        o.progress = @"";
        [objectives addObject:o];
    }
    _objectives = objectives;
    _pendingEntities = [NSMutableArray array];
    _pendingWaves = [NSMutableArray array];
    _pendingMessages = [mission[@"messages"] mutableCopy] ?: [NSMutableArray array];
    _pendingCasualty = mission[@"casualty"];

    gi.modelIndex(ShipModelName(mission[@"player"][@"ship"] ?: kDefaultPlayerShip).UTF8String);
    for (NSDictionary *e in mission[@"entities"]) {
        if (e[@"at"] || e[@"after"] || e[@"nav"]) {
            [_pendingEntities addObject:e];
            gi.modelIndex(CapitalModelName(e[@"asset"], e[@"style"]).UTF8String);   // precache
        } else {
            [self spawnEntity:e jump:NO];
        }
    }
    for (NSDictionary *f in mission[@"fields"]) [self buildField:f];
    for (NSDictionary *w in mission[@"waves"]) {
        if (w[@"at"] || w[@"after"] || w[@"nav"]) {
            [_pendingWaves addObject:w];
            if (ShipDefNamed(w[@"ship"])) gi.modelIndex(ShipModelName(w[@"ship"]).UTF8String);   // precache
        } else {
            [self spawnWave:w jump:NO];
        }
    }
    _objectivesDirty = YES;
    _running = YES;
    [self buildEntityStates];
    GPrint(@"Mission %@ spawned in %.2f s", mission[@"id"], CFAbsoluteTimeGetCurrent() - t0);
}

- (void)spawnPlayer:(GClient *)cl {
    NSDictionary *pl = _mission[@"player"];
    simd_float3 facing = pl[@"facing"] ? Vec3(pl[@"facing"]) : simd_make_float3(0, 0, -1);
    simd_quatf q = LookRotation(facing, simd_make_float3(0, 1, 0));
    // Wingmen form up to the right of the start point.
    simd_float3 pos = Vec3(pl[@"pos"]) + QuatRight(q) * 30.0f * cl.index;
    GFighter *s = [GFighter fighterWithShip:pl[@"ship"] ?: kDefaultPlayerShip ai:NO] ?: [GFighter fighterWithShip:kDefaultPlayerShip ai:NO];
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
    if (c.identifier) [_spawned addObject:c.identifier];
    if (c.group) [_spawned addObject:c.group];
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
    [_spawned addObject:w[@"id"]];
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
        [_spawned addObject:f[@"group"]];
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

- (NSArray *)unitsFor:(NSString *)name {
    NSMutableArray *u = [NSMutableArray array];
    for (GCapital *c in _capitals) if ([c.identifier isEqualToString:name] || [c.group isEqualToString:name]) [u addObject:c];
    for (GPilot *p in _pilots) if ([p.wave isEqualToString:name]) [u addObject:p.ship];
    return u;
}

- (NSArray *)unitsForAll:(NSArray<NSString *> *)names {
    NSMutableArray *u = [NSMutableArray array];
    for (NSString *n in names) [u addObjectsFromArray:[self unitsFor:n]];
    return u;
}

- (GObjective *)objectiveNamed:(NSString *)name {
    for (GObjective *o in _objectives) if ([o.identifier isEqualToString:name]) return o;
    return nil;
}

- (BOOL)triggered:(NSDictionary *)d {
    if (d[@"at"] && _missionTime < [d[@"at"] doubleValue]) return NO;
    if (d[@"after"] && [self objectiveNamed:d[@"after"]].state != ObjectiveComplete) return NO;
    if (d[@"nav"] && ![_navsVisited containsObject:d[@"nav"]]) return NO;
    if (d[@"spawn"] && ![_spawned containsObject:d[@"spawn"]]) return NO;
    return YES;
}

- (simd_float3)navPosition:(NSString *)nav {
    simd_float3 p = 0;
    [_navs[nav] getValue:&p size:sizeof p];
    return p;
}

// Live player ships within `range` of p.
- (NSArray<GFighter *> *)playersNear:(simd_float3)p range:(float)range {
    NSMutableArray *a = [NSMutableArray array];
    for (GFighter *s in [self playerShips]) if (s.alive && simd_distance(s.position, p) < range) [a addObject:s];
    return a;
}

#pragma mark - Update

- (void)updateCasualty {
    NSDictionary *casualty = _pendingCasualty;
    for (GPilot *pilot in _pilots) {
        GFighter *ship = pilot.ship;
        if (ship.team != TeamFriend || ![pilot.callsign isEqualToString:casualty[@"pilot"]]) continue;
        if (ship.alive && ![self triggered:casualty]) return;
        // Use the regular destruction path if combat hasn't already taken the pilot.
        _pendingCasualty = nil;
        if (ship.alive) [self damageShip:ship amount:ship.shield + ship.hull + 1 by:nil shake:0];
        GCommand(nil, SVC_RADIO, casualty[@"text"], casualty[@"from"], nil);
        return;
    }
}

- (void)updateMission:(float)dt {
    // Arrivals and radio traffic.
    for (NSDictionary *e in [_pendingEntities copy])
        if ([self triggered:e]) { [_pendingEntities removeObject:e]; [self spawnEntity:e jump:YES]; }
    for (NSDictionary *w in [_pendingWaves copy])
        if ([self triggered:w]) { [_pendingWaves removeObject:w]; [self spawnWave:w jump:YES]; }
    for (NSDictionary *m in [_pendingMessages copy])
        if ([self triggered:m]) { [_pendingMessages removeObject:m]; GCommand(nil, SVC_RADIO, m[@"text"], m[@"from"], nil); }
    for (NSString *nav in _navs)
        if ([self playersNear:[self navPosition:nav] range:400].count) [_navsVisited addObject:nav];

    _currentNav = nil;
    for (GClient *c in _clients) c.status = nil;
    for (GObjective *o in _objectives) [self evaluate:o dt:dt];
    if (_pendingCasualty) [self updateCasualty];
    for (GClient *c in _clients) {
        if (!c.inGame || [c.status ?: @"" isEqualToString:c.sentStatus ?: @""]) continue;
        c.sentStatus = c.status;
        GCommand(c, SVC_STATUS, c.status, nil, nil);
    }

    if (_objectivesDirty) {
        _objectivesDirty = NO;
        NSMutableArray *lines = [NSMutableArray array];
        NSMutableString *states = [NSMutableString string];
        _objectiveSummary = nil;
        for (GObjective *o in _objectives) {
            if (o.state == ObjectiveHidden) continue;
            [lines addObject:o.progress.length ? [NSString stringWithFormat:@"%@  %@", o.text, o.progress] : o.text];
            int st = o.state == ObjectiveComplete ? 1 : (o.state == ObjectiveFailed ? 2 : (o.optional ? 3 : 0));
            [states appendFormat:@"%d", st];
            if (o.state == ObjectiveActive && !o.optional && !_objectiveSummary && ![o.type isEqualToString:@"protect"]) _objectiveSummary = o.text;
        }
        GCommand(nil, SVC_OBJECTIVES, [lines componentsJoinedByString:@"\n"], states, _objectiveSummary);
    }

    // Win when every required objective (other than "protect") is done; lose
    // when an objective fails or every pilot is down.
    if (_endAt == 0) {
        BOOL anyAlive = NO;
        NSArray *players = [self playerShips];
        for (GFighter *s in players) if (s.alive) anyAlive = YES;
        BOOL failed = players.count > 0 && !anyAlive, done = YES;
        for (GObjective *o in _objectives) {
            if (o.optional) continue;
            if (o.state == ObjectiveFailed) failed = YES;
            if (![o.type isEqualToString:@"protect"] && o.state != ObjectiveComplete) done = NO;
        }
        if (failed) {
            _endAt = _missionTime + 3.5;
            _success = NO;
            GCommand(nil, SVC_BANNER, @"MISSION FAILED", kRed, nil);
        } else if (done) {
            for (GObjective *o in _objectives)
                if ([o.type isEqualToString:@"protect"] && o.state == ObjectiveActive) o.state = ObjectiveComplete;
            _objectivesDirty = YES;
            _endAt = _missionTime + 4.0;
            _success = YES;
            GCommand(nil, SVC_BANNER, @"MISSION COMPLETE", nil, nil);
        }
    } else if (_missionTime >= _endAt) {
        [self endMission];
    }
}

- (void)endMission {
    int kills = 0;
    for (GClient *c in _clients) kills += c.kills;
    GPrint(@"Mission %@ ended: %@ after %.0f s, kills %d", _mission[@"id"], _success ? @"SUCCESS" : @"FAILED", _missionTime, kills);
    _over = YES;
    NSMutableArray *results = [NSMutableArray array];
    for (GObjective *o in _objectives) {
        NSString *mark = o.state == ObjectiveComplete ? @"+" : (o.state == ObjectiveFailed ? @"x" : @"-");
        [results addObject:[NSString stringWithFormat:@"%@ %@%@", mark, o.text, o.optional ? @" (optional)" : @""]];
    }
    GCommand(nil, SVC_LEVEL_END, _success ? @"1" : @"0", [results componentsJoinedByString:@"\n"], nil);
}

- (void)setObjective:(GObjective *)o state:(ObjectiveState)state {
    if (o.state == state) return;
    o.state = state;
    GPrint(@"Mission %@ t=%.0f: objective '%@' -> %@", _mission[@"id"], _missionTime, o.identifier,
           @[@"hidden", @"active", @"complete", @"FAILED"][state]);
    _objectivesDirty = YES;
    if (state == ObjectiveComplete && ![o.type isEqualToString:@"protect"]) {
        GCommand(nil, SVC_BANNER, @"OBJECTIVE COMPLETE", nil, nil);
        NSDictionary *set = o.def[@"onComplete"][@"setTeam"];
        for (NSString *who in set)
            for (id u in [self unitsFor:who]) {
                if ([u isKindOfClass:[GCapital class]]) ((GCapital *)u).team = TeamNamed(set[who]);
                else ((GFighter *)u).team = TeamNamed(set[who]);
            }
    }
    if (state == ObjectiveFailed && !o.optional) GCommand(nil, SVC_BANNER, @"OBJECTIVE FAILED", kRed, nil);
    if (state == ObjectiveActive && _missionTime > 1)
        GCommand(nil, SVC_RADIO, o.text, o.optional ? @"Optional objective" : @"New objective", nil);
}

- (void)evaluate:(GObjective *)o dt:(float)dt {
    if (o.state == ObjectiveComplete || o.state == ObjectiveFailed) return;
    NSString *type = o.type;
    if (o.state == ObjectiveHidden) {
        for (NSString *a in o.after) if ([self objectiveNamed:a].state != ObjectiveComplete) return;
        for (NSString *t in o.targets) if (![_spawned containsObject:t]) return;
        o.activatedAt = _missionTime;
        [self setObjective:o state:ObjectiveActive];
    }
    NSArray *units = [self unitsForAll:o.targets];
    NSString *oldProgress = o.progress;
    float range = o.def[@"range"] ? [o.def[@"range"] floatValue] : 0;

    if ([type isEqualToString:@"reach"]) {
        while (o.navIndex < o.navs.count) {
            simd_float3 p = [self navPosition:o.navs[o.navIndex]];
            if ([self playersNear:p range:range ?: 300].count) o.navIndex++;
            else break;
        }
        o.progress = o.navs.count > 1 ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)o.navIndex, (unsigned long)o.navs.count] : @"";
        if (o.navIndex >= o.navs.count) { [self setObjective:o state:ObjectiveComplete]; return; }
        if (!_currentNav) _currentNav = o.navs[o.navIndex];
    } else if ([type isEqualToString:@"destroy"]) {
        NSUInteger dead = 0;
        for (id u in units) if (!BodyAlive(u)) dead++;
        if (units.count && dead == units.count) [self setObjective:o state:ObjectiveComplete];
        o.progress = units.count > 1 ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)dead, (unsigned long)units.count] : @"";
    } else if ([type isEqualToString:@"protect"]) {
        for (id u in units) {
            BOOL safe = [u isKindOfClass:[GCapital class]] && (((GCapital *)u).collected || ((GCapital *)u).departed);
            if (!BodyAlive(u) && !safe) { [self setObjective:o state:ObjectiveFailed]; return; }
        }
        float worst = 1;
        for (id u in units) if ([u isKindOfClass:[GCapital class]] && BodyAlive(u)) worst = fminf(worst, ((GCapital *)u).hull / ((GCapital *)u).maxHull);
        o.progress = units.count == 1 || worst < 1 ? [NSString stringWithFormat:@"%d%%", (int)lroundf(worst * 100)] : @"";
    } else if ([type isEqualToString:@"escort"]) {
        NSUInteger arrived = 0;
        simd_float3 nav = [self navPosition:o.navs.firstObject];
        for (GCapital *c in units) {
            if (c.departed) { arrived++; continue; }
            if (!c.alive) { [self setObjective:o state:ObjectiveFailed]; return; }
            if (simd_distance(c.position, nav) < 400) {
                arrived++;
                // At a gate the escortee jumps out; elsewhere it just holds.
                for (GCapital *g in _capitals)
                    if ([g.asset isEqualToString:@"JumpGate"] && simd_distance(g.position, nav) < 700) {
                        c.departed = YES;
                        c.hidden = YES;
                        [self jumpFlashAt:c.position scale:c.radius / 30.0f];
                    }
            }
        }
        if (units.count && arrived == units.count) [self setObjective:o state:ObjectiveComplete];
        if (!_currentNav) _currentNav = o.navs.firstObject;
        if (units.count > 1) {
            o.progress = [NSString stringWithFormat:@"%lu/%lu arrived", (unsigned long)arrived, (unsigned long)units.count];
        } else if (units.count == 1) {
            GCapital *c = units.firstObject;
            o.progress = [NSString stringWithFormat:@"%.1fkm", simd_distance(c.position, nav) / 1000.0f];
        }
    } else if ([type isEqualToString:@"survive"]) {
        double left = [o.def[@"seconds"] doubleValue] - (_missionTime - o.activatedAt);
        if (left <= 0) { [self setObjective:o state:ObjectiveComplete]; return; }
        o.progress = [NSString stringWithFormat:@"%d:%02d", (int)left / 60, (int)left % 60];
    } else if ([type isEqualToString:@"scan"]) {
        NSUInteger done = 0;
        for (GCapital *c in units) {
            NSString *k = c.identifier;
            float t = o.scanTime[k].floatValue;
            if (t >= 2.0f) { done++; continue; }
            if (!c.alive) { [self setObjective:o state:ObjectiveFailed]; return; }
            NSArray *near = [self playersNear:c.position range:(range ?: 150) + c.radius];
            if (near.count) {
                t += dt;
                o.scanTime[k] = @(t);
                NSString *status = [NSString stringWithFormat:@"SCANNING %@  %d%%", [c.name uppercaseString], (int)(fminf(t / 2.0f, 1) * 100)];
                for (GFighter *s in near) s.client.status = status;
                if (t >= 2.0f) {
                    c.scanned = YES;
                    GCommand(nil, SVC_RADIO, [NSString stringWithFormat:@"%@ scanned", c.name], @"", nil);
                }
            }
        }
        if (units.count && done == units.count) [self setObjective:o state:ObjectiveComplete];
        o.progress = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)done, (unsigned long)units.count];
    } else if ([type isEqualToString:@"collect"]) {
        NSUInteger got = 0;
        for (GCapital *c in units) {
            if (c.collected) { got++; continue; }
            if (c.alive && [self playersNear:c.position range:(range ?: 30) + c.radius].count) {
                c.collected = YES;
                c.alive = NO;
                c.hidden = YES;
                [self jumpFlashAt:c.position scale:0.2f];
                GCommand(nil, SVC_RADIO, [NSString stringWithFormat:@"%@ aboard", c.name], @"", nil);
                got++;
            }
        }
        if (units.count && got == units.count) [self setObjective:o state:ObjectiveComplete];
        o.progress = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)got, (unsigned long)units.count];
    } else if ([type isEqualToString:@"disable"]) {
        NSString *kindName = o.def[@"kind"];
        SubsystemKind kind = [kindName isEqualToString:@"Engine"] ? SubsystemEngine : ([kindName isEqualToString:@"Shield"] ? SubsystemShield :
                             ([kindName isEqualToString:@"Core"] ? SubsystemCore : SubsystemTurret));
        NSUInteger left = 0, total = 0;
        for (GCapital *c in units) {
            total += [c totalCount:kind];
            if (c.alive) left += [c aliveCount:kind];
        }
        if (units.count && left == 0) [self setObjective:o state:ObjectiveComplete];
        o.progress = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)(total - left), (unsigned long)total];
    }
    if (![o.progress isEqualToString:oldProgress]) _objectivesDirty = YES;
}

@end
