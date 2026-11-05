#import "Mission.h"

static NSMutableDictionary<NSString *, Class> *Registry(void);

@interface MissionObjective ()
+ (NSArray<NSString *> *)percentProblems:(NSDictionary *)d;
@property (nonatomic, readonly) float percent;      // "percent", 1-100
+ (NSArray<NSString *> *)requireTargets:(NSDictionary *)d navs:(BOOL)navs targets:(BOOL)targets;
@end

static NSArray<NSString *> *Strings(id value) {
    if ([value isKindOfClass:NSString.class]) return @[value];
    if (![value isKindOfClass:NSArray.class]) return @[];
    for (id v in value) if (![v isKindOfClass:NSString.class]) return @[];
    return value;
}

static NSString *Count(NSUInteger a, NSUInteger b) {
    return [NSString stringWithFormat:@"%lu/%lu", (unsigned long)a, (unsigned long)b];
}

@implementation MissionObjective

+ (void)registerType:(NSString *)type class:(Class)cls {
    NSMutableDictionary *r = Registry();
    @synchronized (r) { r[type] = cls; }
}

+ (Class)classForType:(NSString *)type {
    NSMutableDictionary *r = Registry();
    @synchronized (r) { return type ? r[type] : nil; }
}

+ (NSArray<NSString *> *)registeredTypes {
    NSMutableDictionary *r = Registry();
    @synchronized (r) { return [r.allKeys sortedArrayUsingSelector:@selector(compare:)]; }
}

+ (NSArray<NSString *> *)problemsWithDefinition:(NSDictionary *)d {
    NSMutableArray *p = [NSMutableArray array];
    if (![d[@"id"] isKindOfClass:NSString.class]) [p addObject:@"needs an \"id\""];
    if (![d[@"text"] isKindOfClass:NSString.class]) [p addObject:@"needs a \"text\""];
    return p;
}

// Subclasses that need targets or navs say so.
+ (NSArray<NSString *> *)requireTargets:(NSDictionary *)d navs:(BOOL)navs targets:(BOOL)targets {
    NSMutableArray *p = [[MissionObjective problemsWithDefinition:d] mutableCopy];
    if (targets && !Strings(d[@"targets"]).count) [p addObject:@"needs \"targets\""];
    if (navs && !Strings(d[@"navs"]).count) [p addObject:@"needs \"navs\""];
    return p;
}

// "percent" on objectives that count targets: 1-100, 100 when absent.
+ (NSArray<NSString *> *)percentProblems:(NSDictionary *)d {
    id v = d[@"percent"];
    if (!v) return @[];
    if (![v isKindOfClass:NSNumber.class] || [v doubleValue] < 1 || [v doubleValue] > 100)
        return @[@"\"percent\" must be a number from 1 to 100"];
    return @[];
}

+ (BOOL)ongoing { return NO; }

+ (instancetype)objectiveWith:(const LevelObjective *)objective {
    Class cls = [self classForType:objective->type];
    if (!cls) return nil;
    MissionObjective *o = [cls new];
    o->_definition = [objective->definition copy];
    o->_identifier = objective->identifier;
    o->_type = objective->type;
    o->_text = objective->text ?: @"";
    o->_targets = objective->targets;
    o->_navs = objective->navs;
    o->_after = objective->after;
    o->_optional = objective->optional;
    o->_state = MissionObjectiveHidden;
    o->_progress = @"";
    return o;
}

- (float)percent { return fminf(100, fmaxf(1, [self number:@"percent" fallback:100])); }

- (float)number:(NSString *)key fallback:(float)fallback {
    id v = _definition[key];
    return [v isKindOfClass:NSNumber.class] ? [v floatValue] : fallback;
}

- (void)updateIn:(id<MissionContext>)context dt:(float)dt {}

@end

#pragma mark - Built-in types

// Fly through navs in order. "range": metres around each nav (300).
@interface MissionObjectiveReach : MissionObjective { NSUInteger _next; } @end
@implementation MissionObjectiveReach
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d { return [self requireTargets:d navs:YES targets:NO]; }
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    float range = [self number:@"range" fallback:300];
    NSArray *navs = self.navs;
    while (_next < navs.count && [ctx livePlayersNear:[ctx navPosition:navs[_next]] range:range].count) _next++;
    self.progress = navs.count > 1 ? Count(_next, navs.count) : @"";
    if (_next >= navs.count) { [ctx objective:self becomes:MissionObjectiveComplete]; return; }
    [ctx pointAtNav:navs[_next]];
}
@end

// Every target destroyed, reinforcements included; "percent" accepts a share
// of them. A target that gets away (departs) fails it once the share can no
// longer be reached.
@interface MissionObjectiveDestroy : MissionObjective @end
@implementation MissionObjectiveDestroy
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d {
    return [[self requireTargets:d navs:NO targets:YES] arrayByAddingObjectsFromArray:[self percentProblems:d]];
}
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    NSArray<id<MissionUnit>> *units = [ctx unitsNamed:self.targets];
    NSUInteger dead = 0, gone = 0, coming = 0;
    for (id<MissionUnit> u in units) {
        if (u.missionGone) gone++;
        else if (!u.missionAlive) dead++;
    }
    for (NSString *t in self.targets) coming += [ctx reinforcementsFor:t];
    NSUInteger total = units.count + coming;
    NSUInteger needed = (NSUInteger)ceil(total * self.percent / 100 - 1e-6);
    if (gone && total - gone < needed) { [ctx objective:self becomes:MissionObjectiveFailed]; return; }
    if (units.count && dead >= needed) [ctx objective:self becomes:MissionObjectiveComplete];
    self.progress = total > 1 ? Count(MIN(dead, needed), needed) : @"";
}
@end

// No target lost for the whole mission (leaving safely is not a loss);
// "percent" lets the share of 100 - percent be lost.
@interface MissionObjectiveProtect : MissionObjective @end
@implementation MissionObjectiveProtect
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d {
    return [[self requireTargets:d navs:NO targets:YES] arrayByAddingObjectsFromArray:[self percentProblems:d]];
}
+ (BOOL)ongoing { return YES; }
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    NSArray<id<MissionUnit>> *units = [ctx unitsNamed:self.targets];
    NSUInteger lost = 0, coming = 0;
    for (id<MissionUnit> u in units) if (!u.missionAlive && !u.missionGone) lost++;
    for (NSString *t in self.targets) coming += [ctx reinforcementsFor:t];
    NSUInteger total = units.count + coming;
    if (lost * 100 > total * (100 - self.percent) + 1e-6) { [ctx objective:self becomes:MissionObjectiveFailed]; return; }
    if (self.percent < 100) { self.progress = total > 1 ? Count(total - lost, total) : @""; return; }
    float worst = 1;
    for (id<MissionUnit> u in units) if (u.missionAlive) worst = fminf(worst, u.missionHullFraction);
    self.progress = units.count == 1 || worst < 1 ? [NSString stringWithFormat:@"%d%%", (int)lroundf(worst * 100)] : @"";
}
@end

// Bring every target to the first nav (within 400 m). "depart": true makes
// them leave the level there (a jump gate, an airfield).
@interface MissionObjectiveEscort : MissionObjective @end
@implementation MissionObjectiveEscort
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d { return [self requireTargets:d navs:YES targets:YES]; }
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    NSArray<id<MissionUnit>> *units = [ctx unitsNamed:self.targets];
    NSString *navName = self.navs.firstObject;
    simd_float3 nav = [ctx navPosition:navName];
    float range = [self number:@"range" fallback:400];
    BOOL depart = [self.definition[@"depart"] boolValue];
    NSUInteger arrived = 0;
    for (id<MissionUnit> u in units) {
        if (u.missionGone) { arrived++; continue; }
        if (!u.missionAlive) { [ctx objective:self becomes:MissionObjectiveFailed]; return; }
        if (simd_distance(u.missionPosition, nav) < range) {
            arrived++;
            if (depart) [ctx.world missionDepart:u];
        }
    }
    if (units.count && arrived == units.count) [ctx objective:self becomes:MissionObjectiveComplete];
    [ctx pointAtNav:navName];
    if (units.count > 1)
        self.progress = MissionText(@"mission.arrived", @[Count(arrived, units.count)]);
    else if (units.count == 1)
        self.progress = [NSString stringWithFormat:@"%.1fkm", simd_distance(units.firstObject.missionPosition, nav) / 1000.0f];
}
@end

// Hold out for "seconds" after the objective appears.
@interface MissionObjectiveSurvive : MissionObjective @end
@implementation MissionObjectiveSurvive
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d {
    NSMutableArray *p = [[super problemsWithDefinition:d] mutableCopy];
    if (![d[@"seconds"] isKindOfClass:NSNumber.class]) [p addObject:@"needs \"seconds\""];
    return p;
}
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    double left = [self number:@"seconds" fallback:0] - (ctx.time - self.activatedAt);
    if (left <= 0) { [ctx objective:self becomes:MissionObjectiveComplete]; return; }
    self.progress = [NSString stringWithFormat:@"%d:%02d", (int)left / 60, (int)left % 60];
}
@end

// Stay close to each target for "seconds" (2) to scan it. "range": metres
// beyond the target's radius (150). A target destroyed unscanned fails it.
@interface MissionObjectiveScan : MissionObjective { NSMutableDictionary<NSString *, NSNumber *> *_time; } @end
@implementation MissionObjectiveScan
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d { return [self requireTargets:d navs:NO targets:YES]; }
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    if (!_time) _time = [NSMutableDictionary dictionary];
    NSArray<id<MissionUnit>> *units = [ctx unitsNamed:self.targets];
    float needed = [self number:@"seconds" fallback:2], range = [self number:@"range" fallback:150];
    NSUInteger done = 0;
    for (id<MissionUnit> u in units) {
        float t = _time[u.missionKey].floatValue;
        if (t >= needed) { done++; continue; }
        if (!u.missionAlive) { [ctx objective:self becomes:MissionObjectiveFailed]; return; }
        NSArray *near = [ctx livePlayersNear:u.missionPosition range:range + u.missionRadius];
        if (!near.count) continue;
        t += dt;
        _time[u.missionKey] = @(t);
        NSString *pct = [NSString stringWithFormat:@"%d", (int)(fminf(t / needed, 1) * 100)];
        NSString *status = MissionText(@"mission.scanning", @[u.missionName.uppercaseString ?: @"", pct]);
        for (id<MissionUnit> p in near) [ctx.world missionStatus:status forPlayer:p];
        if (t >= needed) {
            [ctx.world missionMarkScanned:u];
            [ctx.world missionRadio:MissionText(@"mission.scanned", @[u.missionName ?: @""]) from:@""];
        }
    }
    if (units.count && done == units.count) [ctx objective:self becomes:MissionObjectiveComplete];
    self.progress = Count(done, units.count);
}
@end

// Touch each target to take it aboard. "range": metres beyond its radius (30).
@interface MissionObjectiveCollect : MissionObjective @end
@implementation MissionObjectiveCollect
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d { return [self requireTargets:d navs:NO targets:YES]; }
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    NSArray<id<MissionUnit>> *units = [ctx unitsNamed:self.targets];
    float range = [self number:@"range" fallback:30];
    NSUInteger got = 0;
    for (id<MissionUnit> u in units) {
        if (u.missionGone) { got++; continue; }
        if (u.missionAlive && [ctx livePlayersNear:u.missionPosition range:range + u.missionRadius].count) {
            [ctx.world missionCollect:u];
            [ctx.world missionRadio:MissionText(@"mission.collected", @[u.missionName ?: @""]) from:@""];
            got++;
        }
    }
    if (units.count && got == units.count) [ctx objective:self becomes:MissionObjectiveComplete];
    self.progress = Count(got, units.count);
}
@end

// Destroy every part of a "kind" ("Turret", "Engine", "Shield", "Core") on the targets.
@interface MissionObjectiveDisable : MissionObjective @end
@implementation MissionObjectiveDisable
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d { return [self requireTargets:d navs:NO targets:YES]; }
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    NSArray<id<MissionUnit>> *units = [ctx unitsNamed:self.targets];
    NSString *kind = self.definition[@"kind"] ?: @"Turret";
    NSUInteger left = 0, total = 0;
    for (id<MissionUnit> u in units) {
        total += [u missionPartsOfKind:kind alive:NO];
        if (u.missionAlive) left += [u missionPartsOfKind:kind alive:YES];
    }
    if (units.count && left == 0) [ctx objective:self becomes:MissionObjectiveComplete];
    self.progress = Count(total - left, total);
}
@end

// Every target captured by boarders (a wave's "board" order). A target
// destroyed before it is captured fails it.
@interface MissionObjectiveCapture : MissionObjective @end
@implementation MissionObjectiveCapture
+ (NSArray *)problemsWithDefinition:(NSDictionary *)d { return [self requireTargets:d navs:NO targets:YES]; }
- (void)updateIn:(id<MissionContext>)ctx dt:(float)dt {
    NSArray<id<MissionUnit>> *units = [ctx unitsNamed:self.targets];
    NSUInteger done = 0;
    for (id<MissionUnit> u in units) {
        if (u.missionCaptured) done++;
        else if (!u.missionAlive) { [ctx objective:self becomes:MissionObjectiveFailed]; return; }
    }
    if (units.count && done == units.count) [ctx objective:self becomes:MissionObjectiveComplete];
    self.progress = Count(done, units.count);
}
@end

static NSMutableDictionary<NSString *, Class> *Registry(void) {
    static NSMutableDictionary *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        registry = [@{
            @"reach": MissionObjectiveReach.class, @"destroy": MissionObjectiveDestroy.class,
            @"protect": MissionObjectiveProtect.class, @"escort": MissionObjectiveEscort.class,
            @"survive": MissionObjectiveSurvive.class, @"scan": MissionObjectiveScan.class,
            @"collect": MissionObjectiveCollect.class, @"disable": MissionObjectiveDisable.class,
            @"capture": MissionObjectiveCapture.class,
        } mutableCopy];
    });
    return registry;
}
