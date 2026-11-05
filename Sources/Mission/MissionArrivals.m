#import "Mission.h"

// One entity or wave's comings and goings. Times are mission seconds; a
// negative time means nothing is scheduled.
@interface MissionSchedule : NSObject {
@public
    NSString *_name, *_mothership;
    LevelCue _arrival, _departure;
    int _flightSize;
    int _reinforcements;            // flights still to come after the one there now
    float _reinforcementDelay;
    double _arriveAt, _reinforceAt, _departAt;
    BOOL _arrivalCued, _departureCued, _departed;
}
- (BOOL)expecting;
@end

@implementation MissionSchedule

- (instancetype)initWithName:(NSString *)name arrival:(LevelCue)arrival departure:(LevelCue)departure {
    if ((self = [super init])) {
        _name = name;
        _arrival = arrival;
        _departure = departure;
        _arriveAt = _reinforceAt = _departAt = -1;
    }
    return self;
}

static BOOL AnyAlive(NSArray<id<MissionUnit>> *units) {
    for (id<MissionUnit> u in units) if (u.missionAlive) return YES;
    return NO;
}

// The mothership a wave needs to arrive; YES when it has none.
- (BOOL)carrierReadyIn:(id<MissionEventContext>)ctx {
    if (!_mothership) return YES;
    if (AnyAlive([ctx.world missionUnitsNamed:_mothership])) return YES;
    [ctx.world missionLog:[NSString stringWithFormat:@"Mission t=%.0f: %@ stays aboard, its mothership %@ is lost",
                           ctx.time, _name, _mothership]];
    _reinforcements = 0;
    return NO;
}

- (void)updateIn:(id<MissionEventContext>)ctx {
    double now = ctx.time;
    if (_arrival.when && !_arrivalCued && [MissionEvents condition:_arrival.when holdsIn:ctx]) {
        _arrivalCued = YES;
        _arriveAt = now + _arrival.delay;
    }
    if (_arriveAt >= 0 && now >= _arriveAt) {
        _arriveAt = -1;
        if ([self carrierReadyIn:ctx]) [ctx.world missionSpawn:_name];
    }
    if (![ctx hasSpawned:_name] || _departed) return;

    // A flight that is wiped out (dead, not departed) comes back.
    if (_reinforcements > 0 && _reinforceAt < 0) {
        NSArray<id<MissionUnit>> *units = [ctx.world missionUnitsNamed:_name];
        BOOL wiped = units.count > 0;
        for (id<MissionUnit> u in units) if (u.missionAlive || u.missionGone) wiped = NO;
        if (wiped) _reinforceAt = now + _reinforcementDelay;
    }
    if (_reinforceAt >= 0 && now >= _reinforceAt) {
        _reinforceAt = -1;
        if ([self carrierReadyIn:ctx]) {
            _reinforcements--;
            [ctx.world missionReinforce:_name];
        }
    }

    if (_departure.when && !_departureCued && [MissionEvents condition:_departure.when holdsIn:ctx]) {
        _departureCued = YES;
        _departAt = now + _departure.delay;
    }
    if (_departAt >= 0 && now >= _departAt) {
        _departed = YES;
        _reinforcements = 0;
        _reinforceAt = -1;
        for (id<MissionUnit> u in [ctx.world missionUnitsNamed:_name]) if (u.missionAlive) [ctx.world missionDepart:u];
    }
}

- (BOOL)expecting { return _reinforcements > 0 || _reinforceAt >= 0; }

@end

@implementation MissionArrivals {
    NSArray<MissionSchedule *> *_schedules;
}

+ (NSArray<NSString *> *)problemsWithLevel:(const LevelDef *)level {
    NSMutableArray *problems = [NSMutableArray array];
    void (^check)(NSString *, LevelCue, NSString *) = ^(NSString *what, LevelCue cue, NSString *key) {
        if (cue.when) [problems addObjectsFromArray:[MissionEvents problemsWithCondition:cue.when
                                                                                        at:[NSString stringWithFormat:@"%@ %@", what, key]]];
    };
    for (int i = 0; i < level->entityCount; i++) {
        const LevelEntity *e = &level->entities[i];
        NSString *what = [NSString stringWithFormat:@"entity %@", e->identifier ?: @"?"];
        if ((e->arrival.when || e->departure.when) && !e->identifier) [problems addObject:[what stringByAppendingString:@": arrivals need an id"]];
        check(what, e->arrival, @"arrival");
        check(what, e->departure, @"departure");
    }
    for (int i = 0; i < level->waveCount; i++) {
        const LevelWave *w = &level->waves[i];
        NSString *what = [NSString stringWithFormat:@"wave %@", w->identifier ?: @"?"];
        check(what, w->arrival, @"arrival");
        check(what, w->departure, @"departure");
    }
    return problems;
}

- (instancetype)initWithLevel:(const LevelDef *)level {
    if ((self = [super init])) {
        NSMutableArray *schedules = [NSMutableArray array];
        for (int i = 0; i < level->entityCount; i++) {
            const LevelEntity *e = &level->entities[i];
            if (!e->identifier || (!e->arrival.when && !e->departure.when)) continue;
            [schedules addObject:[[MissionSchedule alloc] initWithName:e->identifier arrival:e->arrival departure:e->departure]];
        }
        for (int i = 0; i < level->waveCount; i++) {
            const LevelWave *w = &level->waves[i];
            if (!w->identifier || (!w->arrival.when && !w->departure.when && !w->reinforcements && !w->mothership)) continue;
            MissionSchedule *s = [[MissionSchedule alloc] initWithName:w->identifier arrival:w->arrival departure:w->departure];
            s->_mothership = w->mothership;
            s->_reinforcements = w->reinforcements;
            s->_flightSize = w->count;
            s->_reinforcementDelay = w->reinforcementDelay;
            [schedules addObject:s];
        }
        _schedules = schedules;
    }
    return self;
}

- (void)updateIn:(id<MissionEventContext>)context {
    for (MissionSchedule *s in _schedules) [s updateIn:context];
}

- (NSUInteger)reinforcementsFor:(NSString *)name {
    for (MissionSchedule *s in _schedules) if ([s->_name isEqualToString:name]) return s->_reinforcements * s->_flightSize;
    return 0;
}

- (BOOL)expecting:(NSString *)name {
    for (MissionSchedule *s in _schedules) if ([s->_name isEqualToString:name] && [s expecting]) return YES;
    return NO;
}

@end
