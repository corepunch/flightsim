#import "Mission.h"

MissionObjectiveState MissionObjectiveStateNamed(NSString *name) {
    if ([name isEqualToString:@"failed"]) return MissionObjectiveFailed;
    if ([name isEqualToString:@"active"]) return MissionObjectiveActive;
    if ([name isEqualToString:@"hidden"]) return MissionObjectiveHidden;
    return MissionObjectiveComplete;
}

static NSArray<NSString *> *Names(id value) {
    if ([value isKindOfClass:NSString.class]) return @[value];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSMutableDictionary<NSString *, MissionTrigger> *Triggers(void);
static NSMutableDictionary<NSString *, MissionAction> *Actions(void);

@implementation MissionEvents {
    NSArray<NSDictionary *> *_events;
    NSMutableIndexSet *_fired;       // once-only events that have fired
    NSMutableIndexSet *_holding;     // repeat events whose condition held last frame
}

+ (void)registerTrigger:(NSString *)name block:(MissionTrigger)block {
    NSMutableDictionary *t = Triggers();
    @synchronized (t) { t[name] = [block copy]; }
}

+ (void)registerAction:(NSString *)name block:(MissionAction)block {
    NSMutableDictionary *a = Actions();
    @synchronized (a) { a[name] = [block copy]; }
}

+ (NSArray<NSString *> *)registeredTriggers {
    NSMutableDictionary *t = Triggers();
    @synchronized (t) { return [t.allKeys sortedArrayUsingSelector:@selector(compare:)]; }
}

+ (NSArray<NSString *> *)registeredActions {
    NSMutableDictionary *a = Actions();
    @synchronized (a) { return [a.allKeys sortedArrayUsingSelector:@selector(compare:)]; }
}

static MissionTrigger TriggerNamed(NSString *name) {
    NSMutableDictionary *t = Triggers();
    @synchronized (t) { return t[name]; }
}

static MissionAction ActionNamed(NSString *name) {
    NSMutableDictionary *a = Actions();
    @synchronized (a) { return a[name]; }
}

// Keys that qualify another key rather than name a trigger.
static NSSet *Qualifiers(void) { return [NSSet setWithObjects:@"state", nil]; }

+ (void)collectProblemsInCondition:(id)when at:(NSString *)where into:(NSMutableArray *)problems {
    if (![when isKindOfClass:NSDictionary.class] || ![when count]) { [problems addObject:[where stringByAppendingString:@": \"when\" must be an object"]]; return; }
    for (NSString *key in when) {
        if ([Qualifiers() containsObject:key]) continue;
        if ([key isEqualToString:@"all"] || [key isEqualToString:@"any"]) {
            for (id c in when[key]) [self collectProblemsInCondition:c at:where into:problems];
        } else if ([key isEqualToString:@"not"]) {
            [self collectProblemsInCondition:when[key] at:where into:problems];
        } else if (!TriggerNamed(key)) {
            [problems addObject:[NSString stringWithFormat:@"%@: unknown trigger \"%@\"", where, key]];
        }
    }
}

+ (NSArray<NSString *> *)problemsWithEvents:(id)events {
    NSMutableArray *problems = [NSMutableArray array];
    if (!events) return problems;
    if (![events isKindOfClass:NSArray.class]) return @[@"\"events\" must be a list"];
    NSUInteger i = 0;
    for (NSDictionary *e in events) {
        NSString *where = [NSString stringWithFormat:@"event %lu", (unsigned long)i++];
        if (![e isKindOfClass:NSDictionary.class]) { [problems addObject:[where stringByAppendingString:@" is not an object"]]; continue; }
        [self collectProblemsInCondition:e[@"when"] at:where into:problems];
        NSArray *actions = e[@"do"];
        if (![actions isKindOfClass:NSArray.class] || !actions.count) { [problems addObject:[where stringByAppendingString:@": \"do\" must be a non-empty list"]]; continue; }
        for (NSDictionary *a in actions) {
            if (![a isKindOfClass:NSDictionary.class] || a.count != 1) { [problems addObject:[where stringByAppendingString:@": each action is an object with one key"]]; continue; }
            if (!ActionNamed(a.allKeys.firstObject)) [problems addObject:[NSString stringWithFormat:@"%@: unknown action \"%@\"", where, a.allKeys.firstObject]];
        }
    }
    return problems;
}

- (instancetype)initWithEvents:(NSArray<NSDictionary *> *)events {
    if ((self = [super init])) {
        _events = [events isKindOfClass:NSArray.class] ? [events copy] : @[];
        _fired = [NSMutableIndexSet indexSet];
        _holding = [NSMutableIndexSet indexSet];
    }
    return self;
}

+ (BOOL)condition:(NSDictionary *)when holdsIn:(id<MissionEventContext>)ctx {
    if (![when isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in when) {
        if ([Qualifiers() containsObject:key]) continue;
        id value = when[key];
        BOOL holds;
        if ([key isEqualToString:@"all"]) {
            holds = YES;
            for (NSDictionary *c in value) if (![self condition:c holdsIn:ctx]) { holds = NO; break; }
        } else if ([key isEqualToString:@"any"]) {
            holds = NO;
            for (NSDictionary *c in value) if ([self condition:c holdsIn:ctx]) { holds = YES; break; }
        } else if ([key isEqualToString:@"not"]) {
            holds = ![self condition:value holdsIn:ctx];
        } else {
            MissionTrigger trigger = TriggerNamed(key);
            // "objective" reads its sibling "state".
            holds = trigger && trigger([key isEqualToString:@"objective"] ? when : value, ctx);
        }
        if (!holds) return NO;   // keys of one object all have to hold
    }
    return YES;
}

- (void)updateIn:(id<MissionEventContext>)ctx {
    for (NSUInteger i = 0; i < _events.count; i++) {
        NSDictionary *e = _events[i];
        BOOL repeat = [e[@"repeat"] boolValue];
        if (!repeat && [_fired containsIndex:i]) continue;
        BOOL holds = [MissionEvents condition:e[@"when"] holdsIn:ctx];
        if (repeat) {
            BOOL held = [_holding containsIndex:i];
            if (holds) [_holding addIndex:i]; else [_holding removeIndex:i];
            if (!holds || held) continue;
        } else {
            if (!holds) continue;
            [_fired addIndex:i];
        }
        for (NSDictionary *a in e[@"do"]) {
            if (![a isKindOfClass:NSDictionary.class]) continue;
            NSString *name = a.allKeys.firstObject;
            MissionAction action = ActionNamed(name);
            if (action) action(a[name], ctx);
        }
    }
}

@end

#pragma mark - Built-ins

static NSMutableDictionary<NSString *, MissionTrigger> *Triggers(void) {
    static NSMutableDictionary *triggers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        triggers = [NSMutableDictionary dictionary];
        triggers[@"time"] = ^BOOL(id v, id<MissionEventContext> c) { return c.time >= [v doubleValue]; };
        triggers[@"objective"] = ^BOOL(NSDictionary *when, id<MissionEventContext> c) {
            MissionObjective *o = [c objectiveNamed:when[@"objective"]];
            MissionObjectiveState want = MissionObjectiveStateNamed(when[@"state"]);
            if (want == MissionObjectiveActive) return o.state == MissionObjectiveActive || o.state == MissionObjectiveComplete || o.state == MissionObjectiveFailed;
            return o.state == want;
        };
        triggers[@"spawned"] = ^BOOL(id v, id<MissionEventContext> c) {
            for (NSString *n in Names(v)) if (![c hasSpawned:n]) return NO;
            return YES;
        };
        triggers[@"destroyed"] = ^BOOL(id v, id<MissionEventContext> c) {
            for (NSString *n in Names(v)) {
                NSArray<id<MissionUnit>> *units = [c.world missionUnitsNamed:n];
                if (!units.count) return NO;
                for (id<MissionUnit> u in units) if (u.missionAlive || u.missionGone) return NO;
            }
            return YES;
        };
        triggers[@"nav"] = ^BOOL(id v, id<MissionEventContext> c) {
            for (NSString *n in Names(v)) if (![c navVisited:n]) return NO;
            return YES;
        };
        triggers[@"flag"] = ^BOOL(id v, id<MissionEventContext> c) {
            for (NSString *n in Names(v)) if (![c flag:n]) return NO;
            return YES;
        };
    });
    return triggers;
}

static NSMutableDictionary<NSString *, MissionAction> *Actions(void) {
    static NSMutableDictionary *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        actions = [NSMutableDictionary dictionary];
        actions[@"spawn"] = ^(id v, id<MissionEventContext> c) { for (NSString *n in Names(v)) [c.world missionSpawn:n]; };
        actions[@"radio"] = ^(NSDictionary *v, id<MissionEventContext> c) { [c.world missionRadio:v[@"text"] ?: @"" from:v[@"from"] ?: @""]; };
        actions[@"banner"] = ^(NSDictionary *v, id<MissionEventContext> c) {
            if ([v isKindOfClass:NSString.class]) [c.world missionBanner:(NSString *)v alert:NO];
            else [c.world missionBanner:v[@"text"] ?: @"" alert:[v[@"alert"] boolValue]];
        };
        actions[@"set_team"] = ^(NSDictionary *v, id<MissionEventContext> c) {
            for (NSString *name in v) [c.world missionSetTeam:v[name] ofUnits:[c.world missionUnitsNamed:name]];
        };
        actions[@"destroy"] = ^(id v, id<MissionEventContext> c) {
            for (NSString *n in Names(v))
                for (id<MissionUnit> u in [c.world missionUnitsNamed:n]) if (u.missionAlive) [c.world missionDestroy:u];
        };
        actions[@"objective"] = ^(NSDictionary *v, id<MissionEventContext> c) {
            MissionObjective *o = [c objectiveNamed:v[@"id"]];
            if (o) [c objective:o becomes:MissionObjectiveStateNamed(v[@"state"])];
        };
        actions[@"set_flag"] = ^(id v, id<MissionEventContext> c) { for (NSString *n in Names(v)) [c setFlag:n]; };
        actions[@"end"] = ^(id v, id<MissionEventContext> c) { [c endMission:![v isEqual:@"failure"]]; };
    });
    return actions;
}
