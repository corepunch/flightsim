// Per-player target selection: cycling, automatic pick and the subsystem the
// torpedo aims at.
#import "GLocal.h"

@implementation GWorld (Targeting)

- (BOOL)capital:(GCapital *)c visibleTo:(GFighter *)ship {
    return c.stealthRange <= 0 || simd_distance(c.position, ship.position) < c.stealthRange;
}

- (NSArray *)targetablesFor:(GClient *)cl {
    NSMutableArray *list = [NSMutableArray array];
    for (GPilot *p in _pilots) if (p.ship.alive && p.ship.team == TeamEnemy) [list addObject:p.ship];
    NSMutableSet *objectiveIds = [NSMutableSet set];
    for (GObjective *o in _objectives) if (o.state == ObjectiveActive) [objectiveIds addObjectsFromArray:o.targets];
    for (GCapital *c in _capitals) {
        if (!c.alive || c.departed || c.isAsteroid) continue;
        if (![self capital:c visibleTo:cl.ship]) continue;
        BOOL objective = [objectiveIds containsObject:c.identifier ?: @""] || [objectiveIds containsObject:c.group ?: @""];
        if (c.team == TeamEnemy || objective) [list addObject:c];
    }
    return list;
}

- (void)cycleTargetFor:(GClient *)cl {
    GFighter *me = cl.ship;
    if (!me) return;
    NSArray *list = [[self targetablesFor:cl] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        float da = simd_distance(BodyPosition(a), me.position), db = simd_distance(BodyPosition(b), me.position);
        return da < db ? NSOrderedAscending : (da > db ? NSOrderedDescending : NSOrderedSame);
    }];
    if (!list.count) { cl.selected = nil; return; }
    NSUInteger i = cl.selected ? [list indexOfObject:cl.selected] : NSNotFound;
    cl.selected = list[i == NSNotFound ? 0 : (i + 1) % list.count];
}

- (void)autoTargetFor:(GClient *)cl {
    GFighter *me = cl.ship;
    id sel = cl.selected;
    if (BodyAlive(sel) && (![sel isKindOfClass:[GCapital class]] || [self capital:sel visibleTo:me])) return;
    cl.selected = nil;
    float best = FLT_MAX;
    for (id u in [self targetablesFor:cl]) {
        simd_float3 rel = BodyPosition(u) - me.position;
        float d = simd_length(rel);
        float off = acosf(clampf(simd_dot(me.forward, rel / fmaxf(d, 1)), -1, 1));
        float score = off + d / 3000.0f;
        if (score < best) { best = score; cl.selected = u; }
    }
}

// On a capital, aim at the live subsystem closest to the nose (shield
// generators first while they are up).
- (void)updateTargetingFor:(GClient *)cl {
    if (!cl.ship) return;
    [self autoTargetFor:cl];
    cl.aimSubsystem = nil;
    id sel = cl.selected;
    if (![sel isKindOfClass:[GCapital class]]) return;
    GCapital *c = sel;
    GFighter *me = cl.ship;
    BOOL shielded = c.shielded;
    float best = FLT_MAX;
    for (GSubsystem *s in c.subsystems) {
        if (!s.alive || (shielded && s.kind != SubsystemShield)) continue;
        simd_float3 rel = [c worldPoint:s.local] - me.position;
        float off = acosf(clampf(simd_dot(me.forward, simd_normalize(rel)), -1, 1));
        if (off < best) { best = off; cl.aimSubsystem = s; }
    }
}

@end
