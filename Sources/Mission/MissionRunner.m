#import "Mission.h"

static const float kNavVisitRange = 400;            // metres: a nav counts as visited
static const double kFailedPause = 3.5, kSuccessPause = 4.0;   // seconds between the banner and the debrief

@implementation MissionRunner {
    LevelRules _rules;
    NSArray<MissionObjective *> *_objectives;
    MissionEvents *_events;
    MissionArrivals *_arrivals;
    NSMutableSet<NSString *> *_spawned, *_navsVisited, *_flags;
    double _time, _endAt;
    BOOL _dirty;
    NSString *_currentNav, *_sentNav;
}

@synthesize world = _world;

+ (NSArray<NSString *> *)problemsWithLevel:(const LevelDef *)level {
    if (!level) return @[@"no level"];
    NSMutableArray *problems = [level->problems mutableCopy];
    NSMutableSet *ids = [NSMutableSet set];
    for (int i = 0; i < level->objectiveCount; i++) {
        const LevelObjective *o = &level->objectives[i];
        NSString *where = [NSString stringWithFormat:@"objective %@", o->identifier ?: @"?"];
        Class cls = [MissionObjective classForType:o->type];
        if (!cls) { [problems addObject:[NSString stringWithFormat:@"%@: unknown type \"%@\"", where, o->type]]; continue; }
        for (NSString *p in [cls problemsWithDefinition:o->definition]) [problems addObject:[NSString stringWithFormat:@"%@: %@", where, p]];
        if (o->identifier && [ids containsObject:o->identifier]) [problems addObject:[where stringByAppendingString:@": duplicate id"]];
        if (o->identifier) [ids addObject:o->identifier];
    }
    for (int i = 0; i < level->objectiveCount; i++)
        for (NSString *a in level->objectives[i].after) if (![ids containsObject:a])
            [problems addObject:[NSString stringWithFormat:@"objective %@: \"after\" names unknown objective \"%@\"",
                                 level->objectives[i].identifier, a]];
    [problems addObjectsFromArray:[MissionEvents problemsWithEvents:level->events]];
    [problems addObjectsFromArray:[MissionArrivals problemsWithLevel:level]];
    return problems;
}

- (instancetype)initWithLevel:(const LevelDef *)level world:(id<MissionWorld>)world {
    if ((self = [super init])) {
        _world = world;
        _rules = level->rules;
        NSMutableArray *objectives = [NSMutableArray array];
        for (int i = 0; i < level->objectiveCount; i++) {
            const LevelObjective *d = &level->objectives[i];
            MissionObjective *o = [MissionObjective objectiveWith:d];
            if (o) [objectives addObject:o];
            else [world missionLog:[NSString stringWithFormat:@"Mission: unknown objective type \"%@\" (%@)", d->type, d->identifier]];
        }
        _objectives = objectives;
        _events = [[MissionEvents alloc] initWithEvents:level->events];
        _arrivals = [[MissionArrivals alloc] initWithLevel:level];
        _spawned = [NSMutableSet setWithObject:@"start"];
        _navsVisited = [NSMutableSet set];
        _flags = [NSMutableSet set];
        _dirty = YES;
    }
    return self;
}

#pragma mark - MissionEventContext

- (double)time { return _time; }

- (NSArray<id<MissionUnit>> *)unitsNamed:(NSArray<NSString *> *)names {
    NSMutableArray *units = [NSMutableArray array];
    for (NSString *n in names) [units addObjectsFromArray:[_world missionUnitsNamed:n]];
    return units;
}

- (NSArray<id<MissionUnit>> *)livePlayersNear:(simd_float3)point range:(float)range {
    NSMutableArray *near = [NSMutableArray array];
    for (id<MissionUnit> p in [_world missionPlayers])
        if (p.missionAlive && simd_distance(p.missionPosition, point) < range) [near addObject:p];
    return near;
}

- (simd_float3)navPosition:(NSString *)nav {
    simd_float3 p = 0;
    [_world missionNav:nav position:&p];
    return p;
}

- (void)pointAtNav:(NSString *)nav { if (!_currentNav) _currentNav = nav; }

- (MissionObjective *)objectiveNamed:(NSString *)identifier {
    for (MissionObjective *o in _objectives) if ([o.identifier isEqualToString:identifier]) return o;
    return nil;
}

- (BOOL)hasSpawned:(NSString *)name { return [_spawned containsObject:name]; }
- (BOOL)expecting:(NSString *)name { return [_arrivals expecting:name]; }
- (BOOL)navVisited:(NSString *)nav { return [_navsVisited containsObject:nav]; }
- (BOOL)flag:(NSString *)name { return [_flags containsObject:name]; }
- (void)setFlag:(NSString *)name { [_flags addObject:name]; }

- (void)endMission:(BOOL)success {
    if (_endAt > 0) return;
    [self decide:success];
}

- (void)objective:(MissionObjective *)o becomes:(MissionObjectiveState)state {
    if (o.state == state) return;
    o.state = state;
    if (state == MissionObjectiveActive) o.activatedAt = _time;
    [_world missionLog:[NSString stringWithFormat:@"Mission t=%.0f: objective '%@' -> %@", _time, o.identifier,
                        @[@"hidden", @"active", @"complete", @"FAILED"][state]]];
    _dirty = YES;
    if (state == MissionObjectiveComplete && ![o.class ongoing])
        [_world missionBanner:MissionText(@"mission.objective_complete", nil) alert:NO];
    if (state == MissionObjectiveFailed && !o.optional)
        [_world missionBanner:MissionText(@"mission.objective_failed", nil) alert:YES];
    if (state == MissionObjectiveActive && _time > 1)
        [_world missionRadio:o.text from:MissionText(o.optional ? @"mission.optional_objective" : @"mission.new_objective", nil)];
}

#pragma mark - Frame

- (void)noteSpawned:(NSString *)name { if (name) [_spawned addObject:name]; }
- (void)resendObjectives { _dirty = YES; }

- (void)update:(float)dt {
    if (_over) return;
    _time += dt;
    for (NSString *nav in [_world missionNavs])
        if (![_navsVisited containsObject:nav] && [self livePlayersNear:[self navPosition:nav] range:kNavVisitRange].count)
            [_navsVisited addObject:nav];
    [_events updateIn:self];
    [_arrivals updateIn:self];

    _currentNav = nil;
    for (MissionObjective *o in _objectives) [self updateObjective:o dt:dt];
    if (![_currentNav ?: @"" isEqualToString:_sentNav ?: @""]) {
        _sentNav = _currentNav;
        [_world missionCurrentNav:_currentNav];
    }
    if (_dirty) [self sendObjectives];

    if (_endAt == 0) [self checkRules];
    else if (_time >= _endAt) [self finish];
}

- (void)updateObjective:(MissionObjective *)o dt:(float)dt {
    if (o.state == MissionObjectiveComplete || o.state == MissionObjectiveFailed) return;
    if (o.state == MissionObjectiveHidden) {
        for (NSString *a in o.after) if ([self objectiveNamed:a].state != MissionObjectiveComplete) return;
        for (NSString *t in o.targets) if (![_spawned containsObject:t]) return;
        [self objective:o becomes:MissionObjectiveActive];
    }
    NSString *before = o.progress;
    [o updateIn:self dt:dt];
    if (![o.progress ?: @"" isEqualToString:before ?: @""]) _dirty = YES;
}

- (void)sendObjectives {
    _dirty = NO;
    NSMutableArray *lines = [NSMutableArray array];
    NSMutableString *states = [NSMutableString string];
    NSString *summary = nil;
    for (MissionObjective *o in _objectives) {
        if (o.state == MissionObjectiveHidden) continue;
        [lines addObject:o.progress.length ? [NSString stringWithFormat:@"%@  %@", o.text, o.progress] : o.text];
        int st = o.state == MissionObjectiveComplete ? 1 : (o.state == MissionObjectiveFailed ? 2 : (o.optional ? 3 : 0));
        [states appendFormat:@"%d", st];
        if (o.state == MissionObjectiveActive && !o.optional && !summary && ![o.class ongoing]) summary = o.text;
    }
    [_world missionObjectives:lines states:states summary:summary];
}

- (void)checkRules {
    BOOL failed = NO, done = YES;
    if (_rules.failWhenPlayersDown) {
        NSArray<id<MissionUnit>> *players = [_world missionPlayers];
        BOOL anyAlive = NO;
        for (id<MissionUnit> p in players) if (p.missionAlive) anyAlive = YES;
        if (players.count && !anyAlive) failed = YES;
    }
    for (MissionObjective *o in _objectives) {
        if (o.optional) continue;
        if (o.state == MissionObjectiveFailed && _rules.failOnObjectiveFailed) failed = YES;
        if (![o.class ongoing] && o.state != MissionObjectiveComplete) done = NO;
    }
    if (failed) [self decide:NO];
    else if (done && _rules.succeedWhenObjectivesDone) [self decide:YES];
}

- (void)decide:(BOOL)success {
    _success = success;
    _endAt = _time + (success ? kSuccessPause : kFailedPause);
    if (success) {
        for (MissionObjective *o in _objectives)
            if ([o.class ongoing] && o.state == MissionObjectiveActive) o.state = MissionObjectiveComplete;
        _dirty = YES;
        [self sendObjectives];
    }
    [_world missionBanner:MissionText(success ? @"mission.complete" : @"mission.failed", nil) alert:!success];
}

- (BOOL)ending { return _endAt > 0; }

- (void)finish {
    _over = YES;
    NSMutableArray *results = [NSMutableArray array];
    for (MissionObjective *o in _objectives) {
        NSString *mark = o.state == MissionObjectiveComplete ? @"+" : (o.state == MissionObjectiveFailed ? @"x" : @"-");
        [results addObject:[NSString stringWithFormat:@"%@ %@%@", mark, o.text, o.optional ? MissionText(@"mission.optional_suffix", nil) : @""]];
    }
    [_world missionLog:[NSString stringWithFormat:@"Mission ended: %@ after %.0f s", _success ? @"SUCCESS" : @"FAILED", _time]];
    [_world missionEnded:_success results:results];
}

@end
