// AI fighters, capital ship turrets and mines.
#import "Game.h"

// Capital ship turret rounds.
static const float kTurretBoltSpeed = 700, kTurretBoltLife = 1.6f;
// Departing fighters: how close to the launch point counts as aboard, and how
// long a ship with nowhere to dock flies clear before it jumps.
static const float kDockRange = 45, kJumpOutAfter = 3;
// Orders: how near a hostile must be for an evading pilot to break away and for
// a patrolling one to engage, and how close counts as reaching a patrol nav.
static const float kEvadeRange = 1500, kPatrolRange = 1200, kNavReached = 300;

@implementation GWorld (AI)

- (BOOL)isPlayerShip:(GFighter *)f { return f.client != nil; }

static BOOL Orders(GPilot *p, NSString *verb) { return [p.order isEqualToString:verb]; }
// Orders that never shoot.
static BOOL Peaceful(GPilot *p) { return Orders(p, @"evade") || Orders(p, @"ignore") || Orders(p, @"board"); }

// Down for a "disable" order: a fighter's systems, a capital's engines.
static BOOL UnitDisabled(id u) {
    return [u isKindOfClass:[GFighter class]] ? ((GFighter *)u).disabled : ((GCapital *)u).enginesDead;
}

- (id)pickTargetFor:(GPilot *)p {
    GFighter *s = p.ship;
    if (Peaceful(p)) return nil;
    id best = nil;
    float bestD = FLT_MAX;
    BOOL disable = Orders(p, @"disable");
    if ((Orders(p, @"strike") || disable) && p.orderTarget) {
        for (id u in [self unitsFor:p.orderTarget]) {
            if (!BodyAlive(u) || BodyTeam(u) == s.team || (disable && UnitDisabled(u))) continue;
            float d = simd_distance(BodyPosition(u), s.position);
            if (d < bestD) { bestD = d; best = u; }
        }
        if (best || disable) return best;
    }
    simd_float3 anchor = s.position;
    float leash = FLT_MAX;
    if (Orders(p, @"escort") && p.orderTarget) {
        NSArray *units = [self unitsFor:p.orderTarget];
        for (id u in units) if (BodyAlive(u)) { anchor = BodyPosition(u); leash = 1600; break; }
    }
    float reach = Orders(p, @"patrol") ? kPatrolRange : FLT_MAX;
    if (!Orders(p, @"attack-capitals"))
        for (GFighter *f in [self fighters]) {
            if (f == s || !f.alive || f.disabled || !TeamsHostile(s.team, f.team)) continue;
            if (simd_distance(f.position, anchor) > leash) continue;
            float d = simd_distance(f.position, s.position);
            if (d > reach) continue;
            if ([self isPlayerShip:f]) d *= 0.85f;   // players draw a little extra attention
            if (d < bestD) { bestD = d; best = f; }
        }
    if (best || leash < FLT_MAX || Orders(p, @"attack-fighters")) return best;
    for (GCapital *c in _capitals) {
        if (!c.alive || c.isProp || !TeamsHostile(s.team, c.team)) continue;
        float d = simd_distance(c.position, s.position);
        if (d - c.radius > reach) continue;
        if (d < bestD) { bestD = d; best = c; }
    }
    return best;
}

// The nearest hostile that can hurt: a fighter not disabled, or a capital that is no prop.
- (id)nearestHostileTo:(GFighter *)s within:(float)range {
    id best = nil;
    float bestD = range;
    for (GFighter *f in [self fighters]) {
        if (f == s || !f.alive || f.disabled || !TeamsHostile(s.team, f.team)) continue;
        float d = simd_distance(f.position, s.position);
        if (d < bestD) { bestD = d; best = f; }
    }
    for (GCapital *c in _capitals) {
        if (!c.alive || c.isProp || !TeamsHostile(s.team, c.team)) continue;
        float d = simd_distance(c.position, s.position) - c.radius;
        if (d < bestD) { bestD = d; best = c; }
    }
    return best;
}

// Orders forbid some targets, and a disabled fighter is spared unless the
// pilot was ordered to destroy it.
- (BOOL)pilot:(GPilot *)p mayAttack:(id)target {
    BOOL capital = [target isKindOfClass:[GCapital class]];
    if (Peaceful(p)) return NO;
    if (Orders(p, @"attack-fighters") && capital) return NO;
    if (Orders(p, @"attack-capitals") && !capital) return NO;
    if (Orders(p, @"disable") && UnitDisabled(target)) return NO;
    if (capital || !((GFighter *)target).disabled) return YES;
    return Orders(p, @"strike") && p.orderTarget && [[self unitsFor:p.orderTarget] containsObject:target];
}

- (void)thinkPilot:(GPilot *)p dt:(float)dt {
    GFighter *s = p.ship;
    if (!s.alive || s.disabled) {
        if (p.dockSince > 0) [self boarderLost:p];
        if (s.alive) [s step:(ShipInput){0} dt:dt];    // coasts, does not think
        return;
    }
    if (p.leaving != PilotStaying) { [self flyOut:p dt:dt]; return; }
    if (Orders(p, @"evade") || Orders(p, @"ignore")) { p.target = nil; [self idle:p dt:dt]; return; }
    if (Orders(p, @"board")) { p.target = nil; [self board:p dt:dt]; return; }
    if (_time > p.retargetAt || !BodyAlive(p.target) || ![self pilot:p mayAttack:p.target] || (p.target && !TeamsHostile(s.team, BodyTeam(p.target)) && BodyTeam(p.target) != TeamNeutral)) {
        p.target = [self pickTargetFor:p];
        p.retargetAt = _time + p.skill.reaction + frand();
    }
    id target = p.target;
    if (!target) { [self idle:p dt:dt]; return; }
    BOOL capital = [target isKindOfClass:[GCapital class]];
    simd_float3 aimPoint, tp = BodyPosition(target), toT = tp - s.position;
    float throttle = 0.85f, dist = simd_length(toT);
    BOOL boost = NO;
    float breakoff = capital ? BodyRadius(target) + 140 : 70;
    if (p.mode == AIModeAttack && dist < breakoff) {
        p.mode = AIModeEvade;
        p.modeUntil = _time + 2.0 + frand() * 2.0;
        p.evadePoint = s.position + (randomUnit() + s.forward + simd_normalize(s.position - tp)) * (capital ? 900.0f : 600.0f);
    } else if (p.mode != AIModeAttack && _time > p.modeUntil) {
        p.mode = AIModeAttack;
    }
    if (p.mode == AIModeAttack) {
        float tLead = dist / s.gun.speed;
        simd_float3 wobble = simd_make_float3(sinf(_time * 1.3f + s.radius), cosf(_time * 0.9f), sinf(_time * 0.7f)) * p.skill.aimError * 6.0f;
        aimPoint = tp + BodyVelocity(target) * tLead + (capital ? 0 : wobble);
        float facing = simd_dot(s.forward, toT / fmaxf(dist, 1));
        if (facing < -0.2f && dist < 400) boost = s.boostEnergy > 0.5f;
        if (!capital && dist < 220 && facing > 0.7f) throttle = 0.55f;
        if (dist > 900) boost = s.boostEnergy > 0.3f;
    } else {
        aimPoint = p.evadePoint;
        throttle = 1.0f;
        boost = s.boostEnergy > 0.4f;
    }

    [self steer:s to:aimPoint throttle:throttle boost:boost target:target docking:NO dt:dt];

    float range = capital ? 900 + BodyRadius(target) : 750;
    if (target && p.mode == AIModeAttack && dist < range) {
        simd_float3 leadDir = simd_normalize(aimPoint - s.position);
        float cone = capital ? 0.97f : 0.985f;
        ShipGun gun = s.gun;
        if (simd_dot(s.forward, leadDir) > cone && _time - s.lastShot > gun.interval + frand() * p.skill.fireJitter) {
            s.lastShot = _time;
            [self fireFrom:[s nextGunWorldPosition] velocity:s.velocity direction:simd_normalize(s.forward + randomUnit() * 0.008f)
                     speed:gun.speed life:gun.life team:s.team damage:gun.damage capDamage:gun.capitalDamage ion:gun.ion owner:s.client];
            [self muzzleFlash:s];
        }
    }
}

// Nothing to shoot: the order says where to wait. Patrols fly their navs;
// evaders break away from danger; the passive ones loiter where they
// arrived; the rest form up on their charge or drift about the players.
- (void)idle:(GPilot *)p dt:(float)dt {
    GFighter *s = p.ship;
    p.mode = AIModeReposition;
    if (Orders(p, @"patrol")) { [self patrol:p dt:dt]; return; }
    BOOL passive = Orders(p, @"evade") || Orders(p, @"ignore");
    id threat = Orders(p, @"evade") ? [self nearestHostileTo:s within:kEvadeRange] : nil;
    if (threat) {
        simd_float3 away = simd_normalize(s.position - BodyPosition(threat));
        [self steer:s to:s.position + away * 1000 + s.up * 100 throttle:1 boost:s.boostEnergy > 0.3f target:nil docking:NO dt:dt];
        return;
    }
    GFighter *lead = [self leadPlayer];
    simd_float3 anchor = passive ? p.home : lead ? lead.position : s.position;
    if (!passive && p.orderTarget) for (id u in [self unitsFor:p.orderTarget]) if (BodyAlive(u)) { anchor = BodyPosition(u); break; }
    [self loiter:p around:anchor radius:250 dt:dt];
}

// Circles a point at some distance.
- (void)loiter:(GPilot *)p around:(simd_float3)anchor radius:(float)radius dt:(float)dt {
    GFighter *s = p.ship;
    p.mode = AIModeReposition;
    simd_float3 aimPoint = anchor + simd_make_float3(sinf(_time * 0.3f + s.radius) * radius, 120, cosf(_time * 0.3f) * radius);
    [self steer:s to:aimPoint throttle:simd_distance(aimPoint, s.position) > 400 ? 1.0f : 0.5f boost:NO target:nil docking:NO dt:dt];
}

// How near a boarder must be to its target to be docked: 60 m from a fighter,
// 40 m off a capital's hull.
static float DockRange(id target) {
    return [target isKindOfClass:[GCapital class]] ? BodyRadius(target) + 40 : 60;
}

static BOOL UnitCaptured(id u) {
    return [u isKindOfClass:[GCapital class]] ? ((GCapital *)u).captured : ((GFighter *)u).captured;
}

// Boarders fly to the nearest of their targets and wait near it until it is
// disabled; then they close in, stop alongside and, once a boarder has held
// there for dockSeconds, capture it.
- (void)board:(GPilot *)p dt:(float)dt {
    GFighter *s = p.ship;
    id target = nil;
    float bestD = FLT_MAX;
    for (id u in [self unitsFor:p.orderTarget]) {
        if (!BodyAlive(u) || UnitCaptured(u)) continue;
        float d = simd_distance(BodyPosition(u), s.position);
        if (d < bestD) { bestD = d; target = u; }
    }
    if (!target) { p.dockSince = 0; [self loiter:p around:p.home radius:250 dt:dt]; return; }
    simd_float3 tp = BodyPosition(target);
    if (!UnitDisabled(target)) {
        p.dockSince = 0;
        [self loiter:p around:tp radius:BodyRadius(target) + 200 dt:dt];
        return;
    }
    p.mode = AIModeReposition;
    float d = simd_distance(tp, s.position);
    float standoff = [target isKindOfClass:[GCapital class]] ? BodyRadius(target) + 30 : 30;
    if (d < DockRange(target)) {
        if (p.dockSince <= 0) p.dockSince = _time;
        if (_time - p.dockSince >= p.dockSeconds) { [self captureUnit:target by:s]; p.dockSince = 0; return; }
    } else {
        p.dockSince = 0;
    }
    // Close in and match the target's drift; the throttle falls to that drift at the stand-off.
    simd_float3 v = BodyVelocity(target);
    float throttle = clampf((d - standoff) / 300, 0, 1) + simd_length(v) / fmaxf(s->params.maxSpeed, 1);
    [self steer:s to:tp + v throttle:clampf(throttle, 0, 1) boost:NO target:target docking:YES dt:dt];
}

// A docking boarder is gone: everyone else holding alongside starts the count again.
- (void)boarderLost:(GPilot *)p {
    p.dockSince = 0;
    for (GPilot *o in _pilots) if (Orders(o, @"board") && [o.orderTarget isEqualToString:p.orderTarget]) o.dockSince = 0;
}

// Flies the patrol's navs in turn, round and round.
- (void)patrol:(GPilot *)p dt:(float)dt {
    GFighter *s = p.ship;
    NSArray<NSString *> *navs = [p.orderTarget componentsSeparatedByString:@","];
    p.patrolIndex %= navs.count;
    simd_float3 nav = [self navPosition:navs[p.patrolIndex]];
    if (simd_distance(nav, s.position) < kNavReached) p.patrolIndex = (p.patrolIndex + 1) % navs.count;
    [self steer:s to:nav throttle:0.8f boost:NO target:nil docking:NO dt:dt];
}

// A departing pilot holds fire and heads for its mothership's launch point
// to go aboard; with no mothership left it flies clear and jumps out.
- (void)flyOut:(GPilot *)p dt:(float)dt {
    GFighter *s = p.ship;
    p.mode = AIModeReposition;
    p.target = nil;
    GCapital *home = p.leaving == PilotDocking ? [self capitalNamed:p.mothership] : nil;
    if (p.leaving == PilotDocking && !BodyAlive(home)) {
        p.leaving = PilotJumping;
        p.leavingSince = _time;
    }
    if (p.leaving == PilotDocking) {
        simd_float3 bay = [self launchPointOf:home];
        float d = simd_distance(s.position, bay);
        if (d < kDockRange) { [self fighterLeaves:s jump:NO]; return; }
        [self steer:s to:bay throttle:clampf(d / 300, 0.3f, 1) boost:d > 1500 && s.boostEnergy > 0.3f target:home docking:YES dt:dt];
    } else {
        if (_time - p.leavingSince > kJumpOutAfter) { [self fighterLeaves:s jump:YES]; return; }
        [self steer:s to:s.position + s.forward * 1000 + s.up * 80 throttle:1 boost:s.boostEnergy > 0.2f target:nil docking:NO dt:dt];
    }
}

// Flies the ship toward a point, clear of big hulls and rocks. It may close
// on its target but not ram it, unless it is docking with it.
- (void)steer:(GFighter *)s to:(simd_float3)aimPoint throttle:(float)throttle boost:(BOOL)boost target:(id)target
      docking:(BOOL)docking dt:(float)dt {
    if (s->params.gravity > 0) {
        // An aircraft cannot stop to turn, and needs room to recover above the ground.
        throttle = fmaxf(throttle, s->params.stallSpeed * 1.3f / s->params.maxSpeed);
        if (s.position.y < 100) aimPoint = s.position + s.forward * 200 + simd_make_float3(0, 300, 0);
        aimPoint.y = fmaxf(aimPoint.y, 160);
    }
    for (GCapital *c in _capitals) {
        if (!c.alive || c.radius < 15) continue;
        if (docking && c == target) continue;
        simd_float3 away = s.position - c.position;
        float d = simd_length(away) - c.radius;
        if (d < 110 && simd_dot(s.velocity, -away) > 0 && c != target) {
            aimPoint = s.position + simd_normalize(away) * 400 + s.up * 150;
            break;
        }
        if (c == target && d < 60) aimPoint = s.position + simd_normalize(away) * 400;
    }

    simd_float3 local = simd_act(simd_inverse(s.orientation), simd_normalize(aimPoint - s.position));
    float yawErr = atan2f(local.x, -local.z);
    float pitchErr = atan2f(local.y, -local.z);
    float offAxis = acosf(clampf(-local.z, -1, 1));
    float rollErr = atan2f(local.x, local.y);
    ShipInput c = {0};
    c.throttle = throttle;
    c.boost = boost;
    float bankWeight = clampf((offAxis - 0.15f) * 2.0f, 0, 1);
    c.roll = clampf(rollErr * 1.8f * bankWeight, -1, 1);
    c.pitch = clampf(pitchErr * 2.5f, -1, 1);
    c.yaw = clampf(yawErr * 1.5f, -1, 1);
    [s step:c dt:dt];
}

- (void)fireTurrets:(GCapital *)c {
    if (!c.alive || c.isProp || c.team == TeamNeutral) return;
    NSArray<GFighter *> *fighters = nil;
    for (GSubsystem *t in c.subsystems) {
        if (t.kind != SubsystemTurret || !t.alive) continue;
        if (_time - t.lastShot < 1.1 + frand() * 0.6) continue;
        simd_float3 pos = [c worldPoint:t.local];
        simd_float3 out = [c worldDirection:t.muzzle];
        id best = nil;
        float bestD = FLT_MAX;
        if (!fighters) fighters = [self fighters];
        for (GFighter *f in fighters) {
            if (!f.alive || f.disabled || !TeamsHostile(c.team, f.team)) continue;
            float d = simd_distance(f.position, pos);
            if (d < 1100 && d < bestD && simd_dot(simd_normalize(f.position - pos), out) > -0.15f) { bestD = d; best = f; }
        }
        if (!best)
            for (GCapital *o in _capitals) {
                if (!o.alive || o.isProp || !TeamsHostile(c.team, o.team)) continue;
                float d = simd_distance(o.position, pos) - o.radius;
                if (d < 1400 && d < bestD) { bestD = d; best = o; }
            }
        if (!best) continue;
        t.lastShot = _time;
        simd_float3 tp = BodyPosition(best), tv = BodyVelocity(best);
        float tHit = simd_distance(tp, pos) / kTurretBoltSpeed;
        simd_float3 aim = tp + (tv - c.velocity) * tHit;
        simd_float3 dir = simd_normalize(simd_normalize(aim - pos) + randomUnit() * 0.015f);
        BOOL vsCap = [best isKindOfClass:[GCapital class]];
        [self fireFrom:pos + out * 4 velocity:c.velocity direction:dir speed:kTurretBoltSpeed life:kTurretBoltLife team:c.team
                damage:0.05f capDamage:vsCap ? 0.18f : 0.1f ion:NO owner:nil];
    }
}

- (void)checkMine:(GCapital *)m {
    NSArray<GFighter *> *fighters = [self fighters];
    for (GFighter *f in fighters) {
        if (!f.alive || f.team == m.team) continue;
        if (simd_distance(f.position, m.position) < 60) {
            [self destroyCapital:m];
            for (GFighter *g in fighters) {
                float d = simd_distance(g.position, m.position);
                if (g.alive && d < 90) [self damageShip:g amount:0.75f * (1 - d / 120) from:m.position by:nil shake:0.35f];
            }
            return;
        }
    }
}

@end
