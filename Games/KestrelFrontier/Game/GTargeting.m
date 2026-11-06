// Per-player target selection: cycling, automatic pick and the subsystem the
// torpedo aims at.
#import "Game.h"

@implementation GWorld (Targeting)

- (BOOL)capital:(GCapital *)c visibleTo:(GFighter *)ship {
    return c.stealthRange <= 0 || simd_distance(c.position, ship.position) < c.stealthRange;
}

- (NSArray *)targetablesFor:(GClient *)cl {
    NSMutableArray *list = [NSMutableArray array];
    if (GIsDeathmatch()) for (GClient *other in _clients)
        if (other != cl && other.inGame && other.ship.alive && TeamsHostile(cl.ship.team, other.ship.team)) [list addObject:other.ship];
    for (GPilot *p in _pilots) if (p.ship.alive && TeamsHostile(cl.ship.team, p.ship.team)) [list addObject:p.ship];
    for (GCapital *c in _capitals) {
        if (!c.alive || c.departed || c.isAsteroid) continue;
        if (![self capital:c visibleTo:cl.ship]) continue;
        if (TeamsHostile(cl.ship.team, c.team)) [list addObject:c];
    }
    return list;
}

- (void)cycleTargetFor:(GClient *)cl {
    GFighter *me = cl.ship;
    if (!me.alive) return;
    cl.targetIsManual = NO;
    NSArray *list = [[self targetablesFor:cl] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        float da = simd_distance(BodyPosition(a), me.position), db = simd_distance(BodyPosition(b), me.position);
        return da < db ? NSOrderedAscending : (da > db ? NSOrderedDescending : NSOrderedSame);
    }];
    if (!list.count) {
        cl.selected = nil;
        GCommand(cl, SVC_RADIO, MissionText(@"combat.no_targets", nil), @"", nil);
        return;
    }
    NSUInteger i = cl.selected ? [list indexOfObject:cl.selected] : NSNotFound;
    cl.selected = list[i == NSNotFound ? 0 : (i + 1) % list.count];
    cl.targetIsManual = YES;
}

- (void)autoTargetFor:(GClient *)cl {
    GFighter *me = cl.ship;
    NSArray *targets = [self targetablesFor:cl];
    if (cl.targetIsManual && cl.selected && [targets containsObject:cl.selected]) return;
    cl.selected = nil;
    cl.targetIsManual = NO;
    float degrees = GCvar("g_autoTargetCone");
    float cone = clampf(isfinite(degrees) ? degrees : 8, 0, 45) * (float)M_PI / 180;
    float bestAlignment = cosf(cone), bestDistance = FLT_MAX;
    // Angular proximity wins; distance only breaks a tie along the same ray.
    // Automatic locks follow the crosshair instead of sticking to an old foe.
    for (id u in targets) {
        simd_float3 rel = BodyPosition(u) - me.position;
        float d = simd_length(rel);
        if (d < 1e-5f) continue;
        float alignment = simd_dot(me.forward, rel / d);
        if (alignment > bestAlignment || (alignment == bestAlignment && d < bestDistance)) {
            bestAlignment = alignment; bestDistance = d; cl.selected = u;
        }
    }
}

// A player's shot leaves along the nose unless the selected hostile target
// (its aimed subsystem, on a capital) is inside the gun's assist cone; then it
// goes to the lead point. g_aimAssist scales the cone; 0 turns it off.
- (simd_float3)shotDirectionFor:(GClient *)cl from:(simd_float3)muzzle {
    GFighter *s = cl.ship;
    ShipGun gun = s.gun;
    id sel = cl.selected;
    float cone = gun.assist * fmaxf(0, GCvar("g_aimAssist")) * (float)M_PI / 180.0f;
    if (cone <= 0 || !BodyAlive(sel) || !TeamsHostile(s.team, BodyTeam(sel))) return s.forward;
    simd_float3 point = BodyPosition(sel);
    if ([sel isKindOfClass:[GCapital class]] && cl.aimSubsystem.alive) point = [(GCapital *)sel worldPoint:cl.aimSubsystem.local];
    return AimAssist(s.forward, muzzle, s.velocity, point, BodyVelocity(sel), gun.speed, gun.speed * gun.life, cone);
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
