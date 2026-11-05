#import "GLocal.h"

#pragma mark - Fighter

@implementation GFighter {
    FighterSpec _spec;
    NSUInteger _gunIndex;
}

+ (instancetype)fighterWithClass:(ShipClass)shipClass { return [[self alloc] initWithClass:shipClass]; }

- (instancetype)initWithClass:(ShipClass)shipClass {
    if ((self = [super init])) {
        _shipClass = shipClass;
        _spec = FighterSpecFor(shipClass);
        _radius = _spec.radius;
        _model = gi.modelIndex(FighterModelName(shipClass).UTF8String);
        params.maxSpeed = 150;
        params.turnRate = 1;
        move.orientation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
        move.boostEnergy = 1;
        _laserEnergy = 1;
    _hull = 1;
        _shield = 1;
        _alive = YES;
    }
    return self;
}

- (simd_float3)position { return move.origin; }
- (void)setPosition:(simd_float3)p { move.origin = p; }
- (simd_float3)velocity { return move.velocity; }
- (void)setVelocity:(simd_float3)v { move.velocity = v; }
- (simd_quatf)orientation { return move.orientation; }
- (simd_float3)forward { return QuatForward(move.orientation); }
- (simd_float3)up { return QuatUp(move.orientation); }
- (simd_float3)right { return QuatRight(move.orientation); }
- (float)boostEnergy { return move.boostEnergy; }
- (BOOL)boosting { return move.boosting; }

- (void)resetAt:(simd_float3)position facing:(simd_quatf)orientation {
    ShipMoveReset(&move, position, orientation);
    _laserEnergy = 1;
    _hull = 1;
    _shield = 1;
    _alive = YES;
}

- (void)step:(ShipInput)input dt:(float)dt {
    if (!_alive) return;
    ShipMove(&move, &params, input, dt);
    _laserEnergy = fminf(1, _laserEnergy + LASER_RECHARGE_RATE * dt);
    _shield = fminf(1, _shield + 0.06f * dt);   // shields regenerate slowly
}

- (simd_float3)nextGunWorldPosition {
    simd_float3 local = _spec.guns[_gunIndex % _spec.gunCount];
    _gunIndex++;
    _lastGunLocal = local;
    return move.origin + simd_act(move.orientation, local);
}

- (BOOL)takeDamage:(float)amount {
    BOOL shielded = _shield > 0.02f;
    float absorbed = fminf(_shield, amount);
    _shield -= absorbed;
    _hull -= amount - absorbed;
    if (_hull <= 0) { _hull = 0; _alive = NO; }
    return shielded;
}

@end

#pragma mark - Capital

@implementation GSubsystem
+ (NSString *)nameForKind:(SubsystemKind)kind {
    switch (kind) {
        case SubsystemTurret: return @"TURRET";
        case SubsystemEngine: return @"ENGINE";
        case SubsystemShield: return @"SHIELD GEN";
        case SubsystemCore: return @"REACTOR";
    }
    return @"";
}
@end

@implementation GCapital {
    NSMutableArray<GSubsystem *> *_subs;
    NSUInteger _pathIndex;
    float _currentSpeed, _baseRadius;
    BOOL _hadEngines;
}

+ (instancetype)capitalWithAsset:(NSString *)asset style:(NSString *)style team:(Team)team {
    return [[self alloc] initWithAsset:asset style:style team:team];
}

- (instancetype)initWithAsset:(NSString *)asset style:(NSString *)style team:(Team)team {
    if ((self = [super init])) {
        NSDictionary *info = AssetInfo(asset) ?: @{ @"hp": @10, @"class": asset, @"style": @"concord" };
        _asset = [asset copy];
        _team = team;
        _className = info[@"class"];
        _maxHull = _hull = [info[@"hp"] floatValue];
        _invulnerable = [info[@"invulnerable"] boolValue];
        _isProp = [info[@"prop"] boolValue];
        _isMine = [info[@"mine"] boolValue];
        _isAsteroid = [_className isEqualToString:@"Asteroid"];
        _isBuoy = [asset isEqualToString:@"NavBuoy"];
        _alive = YES;
        _scale = 1;
        _orientation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
        _model = gi.modelIndex(CapitalModelName(asset, style).UTF8String);
        const GameModelInfo *mi = gi.modelInfo(_model);
        _baseRadius = _radius = mi ? mi->radius : 30;
        _subs = [NSMutableArray array];
        for (int i = 0; mi && i < mi->numParts; i++) {
            GSubsystem *s = [GSubsystem new];
            s.kind = (SubsystemKind)mi->parts[i].kind;
            s.part = i;
            float hp[] = { 1.2f, 3.0f, 4.0f, fmaxf(4.0f, _maxHull * 0.12f) };
            s.maxHp = s.hp = hp[s.kind];
            s.alive = YES;
            s.local = mi->parts[i].center;
            s.muzzle = simd_length(s.local) > 1e-3f ? simd_normalize(s.local) : simd_make_float3(0, 1, 0);
            s.lastShot = -(double)arc4random_uniform(1000) / 1000.0;
            [_subs addObject:s];
        }
        _hadEngines = [self totalCount:SubsystemEngine] > 0;
    }
    return self;
}

- (NSArray<GSubsystem *> *)subsystems { return _subs; }

- (uint64_t)deadParts {
    uint64_t m = 0;
    for (GSubsystem *s in _subs) if (!s.alive) m |= 1ull << s.part;
    return m;
}

- (void)setUniformScale:(float)scale {
    _scale = scale;
    _radius = _baseRadius * scale;
}

- (simd_float3)forward { return QuatForward(_orientation); }
- (simd_float3)velocity { return self.forward * _currentSpeed; }
- (simd_float3)worldPoint:(simd_float3)local { return simd_act(_orientation, local) + _position; }
- (simd_float3)worldDirection:(simd_float3)local { return simd_act(_orientation, local); }

- (NSUInteger)aliveCount:(SubsystemKind)kind {
    NSUInteger n = 0;
    for (GSubsystem *s in _subs) if (s.kind == kind && s.alive) n++;
    return n;
}
- (NSUInteger)totalCount:(SubsystemKind)kind {
    NSUInteger n = 0;
    for (GSubsystem *s in _subs) if (s.kind == kind) n++;
    return n;
}
- (BOOL)shielded { return [self aliveCount:SubsystemShield] > 0; }
- (BOOL)enginesDead { return _hadEngines && [self aliveCount:SubsystemEngine] == 0; }

- (void)update:(float)dt {
    if (!_alive) return;
    if (_spin != 0) {
        simd_quatf q = simd_quaternion(_spin * (float)M_PI / 180.0f * dt, simd_make_float3(0, 1, 0));
        _orientation = simd_normalize(simd_mul(_orientation, q));
    }
    float target = (_path.count && !_arrived && !self.enginesDead) ? _speed : 0;
    _currentSpeed += (target - _currentSpeed) * (1.0f - expf(-0.4f * dt));
    if (_path.count && !_arrived) {
        simd_float3 wp;
        [_path[_pathIndex] getValue:&wp size:sizeof wp];
        simd_float3 to = wp - _position;
        float d = simd_length(to);
        if (d < fmaxf(40.0f, _speed * 2.0f)) {
            if (_pathIndex + 1 < _path.count) _pathIndex++;
            else if (_loop) _pathIndex = 0;
            else _arrived = YES;
        } else if (_spin == 0) {
            // Big ships turn slowly toward the next waypoint.
            simd_quatf want = LookRotation(to / d, simd_make_float3(0, 1, 0));
            float rate = clampf(18.0f / fmaxf(_radius, 10.0f), 0.02f, 0.6f);
            _orientation = simd_slerp(_orientation, want, 1.0f - expf(-rate * dt));
        }
    }
    _position += self.velocity * dt;
}

- (BOOL)hitSegmentFrom:(simd_float3)a to:(simd_float3)b point:(simd_float3 *)point
             subsystem:(GSubsystem * __autoreleasing *)subsystem {
    GameTrace tr;
    if (!gi.trace(_model, _position, _orientation, _scale, self.deadParts, a, b, &tr)) return NO;
    *point = tr.point;
    *subsystem = tr.part >= 0 && tr.part < (int)_subs.count && _subs[tr.part].alive ? _subs[tr.part] : nil;
    return YES;
}

- (BOOL)damage:(float)amount subsystem:(GSubsystem *)s {
    if (!_alive || _invulnerable) return YES;
    BOOL shielded = self.shielded;
    if (s && s.alive) {
        if (shielded && s.kind != SubsystemShield) return YES;
        s.hp -= amount;
        if (s.hp <= 0) {
            s.alive = NO;
            if (s.kind == SubsystemCore) _hull = 0;
        }
        if (!_noHullDamage) _hull -= amount * 0.25f;
    } else {
        if (shielded || _noHullDamage) return YES;
        _hull -= amount;
    }
    if (_hull <= 0) {
        _hull = 0;
        _alive = NO;
    }
    return NO;
}

@end

#pragma mark - Small things

@implementation GPilot
@end

@implementation GTorpedo
@end

@implementation GObjective
- (NSString *)identifier { return _def[@"id"]; }
- (NSString *)type { return _def[@"type"]; }
- (NSString *)text { return _def[@"text"]; }
- (NSArray<NSString *> *)targets { return _def[@"targets"] ?: @[]; }
- (NSArray<NSString *> *)navs { return _def[@"navs"] ?: @[]; }
- (NSArray<NSString *> *)after { return _def[@"after"] ?: @[]; }
- (BOOL)optional { return [_def[@"optional"] boolValue]; }
@end

@implementation GClient
@end
