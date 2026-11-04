// Bolts, torpedoes, damage, destruction and ramming.
#import "GLocal.h"

@implementation GWorld (Weapons)

- (GBolt *)fireFrom:(simd_float3)pos velocity:(simd_float3)v direction:(simd_float3)dir speed:(float)speed team:(Team)team
             damage:(float)damage capDamage:(float)capDamage owner:(GClient *)owner {
    for (int i = 0; i < MAX_BOLTS; i++) {
        if (_bolts[i].active) continue;
        GBolt *b = &_bolts[i];
        if (++_nextBoltId == 0) _nextBoltId = 1;
        *b = (GBolt){ .position = pos, .velocity = v + dir * speed, .life = BOLT_LIFE, .damage = damage,
                      .capDamage = capDamage, .team = team, .owner = owner, .id = _nextBoltId, .active = YES };
        GEvent((GameEvent){ .type = EV_BOLT, .id = b->id, .team = team, .entity = owner.ship.number, .pos = b->position, .vel = b->velocity });
        return b;
    }
    return NULL;
}

- (void)muzzleFlash:(GFighter *)s {
    GEvent((GameEvent){ .type = EV_MUZZLE, .entity = s.number, .team = s.team, .pos = s.lastGunLocal });
}

- (void)destroyShip:(GFighter *)s {
    s.alive = NO;
    s.deathTime = _time;
    GEvent((GameEvent){ .type = EV_EXPLOSION, .pos = s.position, .vel = s.velocity, .scale = 1, .model = s.model, .radius = 300 });
}

- (void)damageShip:(GFighter *)s amount:(float)amount by:(GClient *)attacker shake:(float)shake {
    if (!s.alive) return;
    if (s.client && getenv("SF_GOD")) amount = 0;   // debug: invulnerable players
    BOOL shielded = [s takeDamage:amount];
    GEvent((GameEvent){ .type = EV_DAMAGE, .entity = s.number, .flags = shielded ? EVF_SHIELDED : 0, .scale = shake });
    if (!s.alive) {
        if (s.client) s.client.deaths++;
        else if (attacker && s.team == TeamEnemy) attacker.kills++;
        [self destroyShip:s];
    }
}

- (void)updateBolts:(float)dt {
    NSArray<GFighter *> *fighters = [self fighters];
    for (int i = 0; i < MAX_BOLTS; i++) {
        GBolt *b = &_bolts[i];
        if (!b->active) continue;
        simd_float3 p0 = b->position;
        simd_float3 p1 = p0 + b->velocity * dt;
        b->position = p1;
        b->life -= dt;
        BOOL hit = NO;
        for (GFighter *s in fighters) {
            if (!s.alive || s.team == b->team) continue;
            if (SegmentHits(p0, p1, s.position, s.radius * (s.client ? 0.8f : 0.85f))) {
                BOOL shielded = s.shield > 0.02f;
                GEvent((GameEvent){ .type = EV_IMPACT, .id = b->id, .team = b->team, .pos = p1, .flags = shielded ? EVF_SHIELDED : 0 });
                [self damageShip:s amount:b->damage by:b->owner shake:0.35f];
                // A hit makes AI pilots jink.
                for (GPilot *p in _pilots)
                    if (p.ship == s && p.mode == AIModeAttack && frand() < 0.35f) {
                        p.mode = AIModeEvade;
                        p.modeUntil = _time + 1.5 + frand() * 1.5;
                        p.evadePoint = s.position + (randomUnit() + s.right * (frand() < 0.5f ? -1.0f : 1.0f)) * 500.0f;
                    }
                hit = YES;
                break;
            }
        }
        if (!hit) {
            for (GCapital *c in _capitals) {
                if (!c.alive || c.departed || c.team == b->team) continue;
                if (!SegmentHits(p0, p1, c.position, c.radius)) continue;
                simd_float3 point;
                GSubsystem *sub = nil;
                if (![c hitSegmentFrom:p0 to:p1 point:&point subsystem:&sub]) continue;
                [self hitCapital:c subsystem:sub amount:b->capDamage at:point by:b->owner team:b->team bolt:b->id];
                hit = YES;
                break;
            }
        }
        if (hit || b->life <= 0) b->active = NO;
    }
}

- (void)hitCapital:(GCapital *)c subsystem:(GSubsystem *)sub amount:(float)amount at:(simd_float3)point
                by:(GClient *)attacker team:(Team)team bolt:(uint16_t)boltId {
    BOOL subAlive = sub.alive;
    BOOL absorbed = [c damage:amount subsystem:sub];
    GEvent((GameEvent){ .type = EV_IMPACT, .id = boltId, .team = team, .pos = point,
                        .flags = absorbed && !c.invulnerable ? EVF_SHIELDED : 0 });
    if (sub && subAlive && !sub.alive) {
        float scale = sub.kind == SubsystemTurret ? 0.5f : (sub.kind == SubsystemCore ? 2.0f : 1.2f);
        GEvent((GameEvent){ .type = EV_EXPLOSION, .pos = [c worldPoint:sub.local], .vel = c.velocity, .model = c.model, .scale = scale });
        if (attacker)
            GCommand(attacker, SVC_RADIO, [NSString stringWithFormat:@"%@ %@ destroyed", c.name,
                                           [[GSubsystem nameForKind:sub.kind] lowercaseString]], @"", nil);
    }
    if (!c.alive && !c.collected) {
        if (attacker && c.team == TeamEnemy && !c.isProp) attacker.kills++;
        [self destroyCapital:c];
    }
}

- (void)destroyCapital:(GCapital *)c {
    c.alive = NO;
    c.deathTime = _time;
    if (c.isProp || c.radius < 20) {
        GEvent((GameEvent){ .type = EV_EXPLOSION, .pos = c.position, .vel = c.velocity, .model = c.model,
                            .scale = clampf(c.radius / 8.0f, 0.4f, 1.5f) });
        c.hidden = YES;
        return;
    }
    // Big ships break up: a chain of blasts over the hull, then the final one.
    int blasts = 5 + (int)(c.radius / 40);
    for (int i = 0; i < blasts; i++) [_explosionQueue addObject:@[@(_time + i * 0.35 + frand() * 0.2), c, @NO]];
    [_explosionQueue addObject:@[@(_time + blasts * 0.35 + 0.4), c, @YES]];
}

- (void)updateExplosions {
    for (NSArray *e in [_explosionQueue copy]) {
        if ([e[0] doubleValue] > _time) continue;
        [_explosionQueue removeObject:e];
        GCapital *c = e[1];
        if ([e[2] boolValue]) {
            GEvent((GameEvent){ .type = EV_EXPLOSION, .pos = c.position, .vel = c.velocity, .model = c.model,
                                .scale = c.radius / 18.0f, .radius = c.radius * 6 });
            c.hidden = YES;
        } else {
            simd_float3 p = c.position + randomUnit() * c.radius * 0.5f;
            GEvent((GameEvent){ .type = EV_EXPLOSION, .pos = p, .vel = c.velocity, .model = c.model,
                                .scale = clampf(c.radius / 60.0f, 1.0f, 4.0f) });
        }
    }
}

- (void)collidePlayer:(GClient *)cl from:(simd_float3)before {
    GFighter *s = cl.ship;
    if (!s.alive || cl.cmdTime - cl.lastBump < 0.5) return;
    simd_float3 now = s.position;
    for (GCapital *c in _capitals) {
        if (!c.alive || c.departed || simd_distance(now, c.position) > c.radius + 10) continue;
        simd_float3 point;
        GSubsystem *sub = nil;
        simd_float3 ahead = now + simd_normalize(s.velocity + 1e-3f) * 4.0f;
        if (![c hitSegmentFrom:before to:ahead point:&point subsystem:&sub]) continue;
        cl.lastBump = cl.cmdTime;
        float speed = simd_length(s.velocity);
        [self damageShip:s amount:0.08f + speed * 0.0025f by:nil shake:0.8f];
        s.position = before - simd_normalize(s.velocity + 1e-3f) * 2.0f;
        s.velocity = -s.velocity * 0.35f;
        GEvent((GameEvent){ .type = EV_IMPACT, .team = TeamNeutral, .pos = point, .flags = EVF_SHIELDED });
        if (c.isMine) [self checkMine:c];
        return;
    }
}

#pragma mark - Torpedoes

- (void)fireTorpedoFor:(GClient *)cl {
    GFighter *s = cl.ship;
    id target = cl.selected;
    if (!s.alive) return;
    if (cl.torpedoes <= 0 || !BodyAlive(target)) {
        GCommand(cl, SVC_RADIO, cl.torpedoes <= 0 ? @"No torpedoes left" : @"Select a target to launch a torpedo", @"", nil);
        return;
    }
    if (simd_distance(BodyPosition(target), s.position) > 2500) {
        GCommand(cl, SVC_RADIO, @"Target out of torpedo range", @"", nil);
        return;
    }
    cl.torpedoes--;
    GTorpedo *t = [GTorpedo new];
    t.number = [self allocEntity];
    t.position = s.position + s.forward * 6 - s.up * 1.0f;
    t.velocity = s.velocity + s.forward * 120;
    t.life = 9;
    t.team = TeamFriend;
    t.owner = cl;
    t.target = target;
    t.aim = cl.aimSubsystem;
    [_torpedoes addObject:t];
}

- (void)updateTorpedoes:(float)dt {
    for (GTorpedo *t in [_torpedoes copy]) {
        t.life -= dt;
        id target = t.target;
        if (BodyAlive(target)) {
            simd_float3 goal = BodyPosition(target);
            if (t.aim.alive && [target isKindOfClass:[GCapital class]]) goal = [(GCapital *)target worldPoint:t.aim.local];
            float speed = simd_length(t.velocity);
            simd_float3 want = simd_normalize(goal + BodyVelocity(target) * (simd_distance(goal, t.position) / fmaxf(speed, 1)) - t.position);
            simd_float3 dir = simd_normalize(t.velocity);
            dir = simd_normalize(dir + (want - dir) * fminf(1, 3.0f * dt));
            speed = fminf(speed + 260 * dt, 420);
            t.velocity = dir * speed;
        }
        simd_float3 p0 = t.position, p1 = p0 + t.velocity * dt;
        t.position = p1;
        BOOL boom = t.life <= 0;
        if ([target isKindOfClass:[GFighter class]] && BodyAlive(target) && simd_distance(p1, BodyPosition(target)) < 10) {
            [self damageShip:target amount:1.2f by:t.owner shake:0.35f];
            boom = YES;
        }
        if (!boom)
            for (GCapital *c in _capitals) {
                if (!c.alive || c.team == t.team || !SegmentHits(p0, p1, c.position, c.radius)) continue;
                simd_float3 point;
                GSubsystem *sub = nil;
                if (![c hitSegmentFrom:p0 to:p1 point:&point subsystem:&sub]) continue;
                // Torpedoes are proximity-fused against the subsystem they were aimed at.
                if (!sub && t.aim.alive && simd_distance(point, [c worldPoint:t.aim.local]) < 25) sub = t.aim;
                [self hitCapital:c subsystem:sub amount:4.0f at:point by:t.owner team:t.team bolt:0];
                boom = YES;
                break;
            }
        if (boom) {
            GEvent((GameEvent){ .type = EV_EXPLOSION, .pos = p1, .scale = 0.7f });
            [_torpedoes removeObject:t];
        }
    }
}

@end
