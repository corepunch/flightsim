#import "Ship.h"

typedef struct {
    NSString *mesh;
    NSString *texture;
    float radius;
    int nozzleCount;
    simd_float4 nozzles[6];  // in OBJ space: +Z is the nose
    int gunCount;
    simd_float3 guns[2];
    simd_float3 exhaustColor;
} ShipSpec;

// Nozzle spots measured from the meshes (rear-facing vertex clusters) and
// cross-checked with the exhaust placements of the Godot port of the pack.
static ShipSpec SpecFor(ShipClass c) {
    switch (c) {
        case ShipClassExecutioner:
            return (ShipSpec){ @"Executioner", @"Executioner_Blue", 5.0f, 4,
                { {0.937f, -0.155f, -2.85f, 0.42f}, {-0.937f, -0.155f, -2.85f, 0.42f},
                  {4.379f, 0.161f, -3.0f, 0.55f}, {-4.379f, 0.161f, -3.0f, 0.55f} },
                2, { {4.38f, 0.1f, 2.5f}, {-4.38f, 0.1f, 2.5f} },
                {0.25f, 0.55f, 1.0f} };
        case ShipClassSpitfire:
            return (ShipSpec){ @"Spitfire", @"Spitfire_Red", 5.0f, 4,
                { {4.506f, 0.135f, -2.2f, 0.6f}, {-4.506f, 0.135f, -2.2f, 0.6f},
                  {4.506f, -1.27f, -2.2f, 0.6f}, {-4.506f, -1.27f, -2.2f, 0.6f} },
                2, { {1.2f, -0.2f, 3.5f}, {-1.2f, -0.2f, 3.5f} },
                {1.0f, 0.38f, 0.18f} };
        case ShipClassInsurgent:
            return (ShipSpec){ @"Insurgent", @"Insurgent_Red", 4.5f, 6,
                { {0.758f, 0.273f, -3.2f, 0.5f}, {-0.758f, 0.273f, -3.2f, 0.5f},
                  {2.37f, -0.17f, -2.9f, 0.2f}, {-2.37f, -0.17f, -2.9f, 0.2f},
                  {1.686f, 0.699f, -3.0f, 0.16f}, {-1.686f, 0.699f, -3.0f, 0.16f} },
                2, { {2.4f, -0.2f, 3.0f}, {-2.4f, -0.2f, 3.0f} },
                {1.0f, 0.3f, 0.55f} };
    }
}

// OBJ space (+Z nose) -> ship space (-Z nose): rotate 180 degrees about Y.
static simd_float3 ToShip(simd_float3 p) { return simd_make_float3(-p.x, p.y, -p.z); }

// Shield bubble: fresnel rim with a scrolling hex-ish ripple, additive.
static NSString *const kShieldFragment =
    @"#pragma arguments\n"
     "float level;\n"
     "#pragma body\n"
     "float f = 1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view)));\n"
     "float3 p = _surface.position * 1.7;\n"
     "float ripple = 0.6 + 0.4 * sin(p.x * 3.0 + scn_frame.time * 9.0) * sin(p.y * 3.0 - scn_frame.time * 7.0) * sin(p.z * 3.0);\n"
     "float a = (pow(f, 2.5) * 1.6 + 0.12) * ripple * level;\n"
     "_output.color = float4(float3(0.35, 0.65, 1.0) * a * 2.5, 1.0);\n";

@implementation Ship {
    ShipSpec _spec;
    SCNNode *_shieldNode;
    SCNMaterial *_shieldMaterial;
    float _shieldFlash;
    SCNParticleSystem *_damageFire, *_damageSmoke;
}

+ (SCNGeometry *)geometryForSpec:(ShipSpec)spec {
    static NSMutableDictionary<NSString *, SCNGeometry *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    SCNGeometry *g = cache[spec.texture];
    if (g) return g;

    NSURL *url = [[NSBundle mainBundle] URLForResource:spec.mesh withExtension:@"obj" subdirectory:@"Models"];
    SCNScene *scene = [SCNScene sceneWithURL:url options:nil error:nil];
    __block SCNGeometry *found = nil;
    [scene.rootNode enumerateHierarchyUsingBlock:^(SCNNode *child, BOOL *stop) {
        if (child.geometry) { found = child.geometry; *stop = YES; }
    }];
    g = [found copy] ?: [SCNBox boxWithWidth:4 height:1 length:6 chamferRadius:0];

    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelPhysicallyBased;
    m.diffuse.contents = [[NSBundle mainBundle] URLForResource:spec.texture withExtension:@"png" subdirectory:@"Models"];
    m.diffuse.mipFilter = SCNFilterModeLinear;
    m.diffuse.maxAnisotropy = 8;
    m.metalness.contents = @0.55;
    m.roughness.contents = @0.42;
    g.materials = @[m];
    cache[spec.texture] = g;
    return g;
}

+ (SCNGeometry *)geometryForClass:(ShipClass)shipClass {
    return [self geometryForSpec:SpecFor(shipClass)];
}

+ (NSString *)nameForClass:(ShipClass)shipClass { return SpecFor(shipClass).mesh; }

+ (instancetype)shipWithClass:(ShipClass)shipClass smoke:(BOOL)smoke {
    return [[self alloc] initWithClass:shipClass smoke:smoke];
}

- (instancetype)initWithClass:(ShipClass)shipClass smoke:(BOOL)smoke {
    if ((self = [super init])) {
        _shipClass = shipClass;
        _spec = SpecFor(shipClass);
        _radius = _spec.radius;
        _node = [SCNNode node];
        _model = [SCNNode nodeWithGeometry:[Ship geometryForSpec:_spec]];
        _model.eulerAngles = SCNVector3Make(0, M_PI, 0);
        _model.castsShadow = YES;
        [_node addChildNode:_model];

        simd_float4 nz[6];
        for (int i = 0; i < _spec.nozzleCount; i++)
            nz[i] = simd_make_float4(ToShip(_spec.nozzles[i].xyz), _spec.nozzles[i].w);
        _exhaust = [[Exhaust alloc] initWithNozzles:nz count:_spec.nozzleCount
                                              color:_spec.exhaustColor parent:_node smoke:smoke];
        [self buildShield];
        [self buildDamageFx];
        _maxSpeed = 150;
        _turnRate = 1;
        _boostEnergy = 1;
        _hull = 1;
        _shield = 1;
        _alive = YES;
    }
    return self;
}

- (void)buildShield {
    SCNSphere *sphere = [SCNSphere sphereWithRadius:1];
    sphere.segmentCount = 32;
    _shieldMaterial = [SCNMaterial material];
    _shieldMaterial.lightingModelName = SCNLightingModelConstant;
    _shieldMaterial.blendMode = SCNBlendModeAdd;
    _shieldMaterial.writesToDepthBuffer = NO;
    _shieldMaterial.doubleSided = NO;
    _shieldMaterial.shaderModifiers = @{ SCNShaderModifierEntryPointFragment : kShieldFragment };
    [_shieldMaterial setValue:@0 forKey:@"level"];
    sphere.firstMaterial = _shieldMaterial;
    _shieldNode = [SCNNode nodeWithGeometry:sphere];
    _shieldNode.scale = SCNVector3Make(_radius * 1.15, _radius * 0.5, _radius * 1.05);
    _shieldNode.castsShadow = NO;
    _shieldNode.renderingOrder = 90;
    _shieldNode.hidden = YES;
    [_node addChildNode:_shieldNode];
}

- (void)buildDamageFx {
    // A damaged ship trails fire and black smoke, more the worse it gets.
    SCNNode *spot = [SCNNode node];
    spot.position = SCNVector3Make(_radius * 0.35, 0.4, 0.8);
    [_node addChildNode:spot];
    _damageFire = [SCNParticleSystem particleSystem];
    _damageFire.particleImage = [Exhaust particleTexture:@"fire_01"];
    _damageFire.blendMode = SCNParticleBlendModeAdditive;
    _damageFire.birthRate = 0;
    _damageFire.particleLifeSpan = 0.3;
    _damageFire.particleSize = 1.1;
    _damageFire.particleSizeVariation = 0.4;
    _damageFire.particleAngleVariation = 180;
    _damageFire.particleIntensity = 2;
    _damageFire.particleVelocity = 3;
    _damageFire.spreadingAngle = 40;
    _damageFire.emittingDirection = SCNVector3Make(0, 1, 0);
    CAKeyframeAnimation *fc = [CAKeyframeAnimation animationWithKeyPath:@"color"];
    fc.values = @[[NSColor colorWithRed:1 green:0.85 blue:0.5 alpha:1], [NSColor colorWithRed:1 green:0.35 blue:0.08 alpha:0]];
    fc.keyTimes = @[@0, @1];
    _damageFire.propertyControllers = @{ SCNParticlePropertyColor : [SCNParticlePropertyController controllerWithAnimation:fc] };
    [spot addParticleSystem:_damageFire];

    _damageSmoke = [SCNParticleSystem particleSystem];
    _damageSmoke.particleImage = [Exhaust particleTexture:@"smoke_07"];
    _damageSmoke.blendMode = SCNParticleBlendModeAlpha;
    _damageSmoke.birthRate = 0;
    _damageSmoke.particleLifeSpan = 2.2;
    _damageSmoke.particleAngleVariation = 180;
    _damageSmoke.particleAngularVelocityVariation = 50;
    _damageSmoke.particleVelocity = 2;
    _damageSmoke.spreadingAngle = 60;
    CAKeyframeAnimation *sc = [CAKeyframeAnimation animationWithKeyPath:@"color"];
    sc.values = @[[NSColor colorWithRed:0.2 green:0.18 blue:0.17 alpha:0.55], [NSColor colorWithRed:0.15 green:0.15 blue:0.16 alpha:0]];
    sc.keyTimes = @[@0, @1];
    CAKeyframeAnimation *ss = [CAKeyframeAnimation animationWithKeyPath:@"size"];
    ss.values = @[@1.0, @6.0];
    ss.keyTimes = @[@0, @1];
    _damageSmoke.propertyControllers = @{ SCNParticlePropertyColor : [SCNParticlePropertyController controllerWithAnimation:sc],
                                          SCNParticlePropertySize : [SCNParticlePropertyController controllerWithAnimation:ss] };
    [spot addParticleSystem:_damageSmoke];
}

- (void)flashShield {
    _shieldFlash = 1;
    _shieldNode.hidden = NO;
}

- (void)updateFx:(float)dt {
    _shieldFlash = fmaxf(0, _shieldFlash - dt * 2.8f);
    _shieldNode.hidden = _shieldFlash <= 0.001f || !_alive;
    [_shieldMaterial setValue:@(_shieldFlash) forKey:@"level"];
    float dmg = _alive ? fmaxf(0, 0.6f - _hull) / 0.6f : 0;
    _damageFire.birthRate = dmg > 0 ? 20 + 140 * dmg : 0;
    _damageSmoke.birthRate = dmg > 0 ? 10 + 60 * dmg : 0;
}

- (simd_float3)position { return _node.simdPosition; }
- (void)setPosition:(simd_float3)p { _node.simdPosition = p; }
- (simd_quatf)orientation { return _node.simdOrientation; }
- (void)setOrientation:(simd_quatf)q { _node.simdOrientation = q; }
- (simd_float3)forward { return simd_act(_node.simdOrientation, simd_make_float3(0, 0, -1)); }
- (simd_float3)up { return simd_act(_node.simdOrientation, simd_make_float3(0, 1, 0)); }
- (simd_float3)right { return simd_act(_node.simdOrientation, simd_make_float3(1, 0, 0)); }

- (void)resetAt:(simd_float3)position facing:(simd_quatf)orientation {
    self.position = position;
    self.orientation = orientation;
    _velocity = self.forward * 60;
    _angularVelocity = 0;
    _hull = 1;
    _shield = 1;
    _boostEnergy = 1;
    _alive = YES;
    _node.hidden = NO;
    [_exhaust setEnabled:YES];
}

- (void)stepWithControls:(ControlState)c dt:(float)dt {
    if (!_alive) return;

    // Boost drains energy; it recharges when not boosting.
    BOOL boost = c.boost && _boostEnergy > 0.02f;
    _boostEnergy = fminf(1, fmaxf(0, _boostEnergy + (boost ? -0.28f : 0.12f) * dt));
    _boosting = boost;
    _throttle = c.throttle;

    // Angular rates chase the stick, giving a little weight to the controls.
    simd_float3 target = simd_make_float3(c.pitch * 1.45f, -c.yaw * 0.85f, -c.roll * 2.6f) * _turnRate;
    if (boost) target *= 0.7f;
    _angularVelocity += (target - _angularVelocity) * (1.0f - expf(-5.5f * dt));
    float w = simd_length(_angularVelocity);
    if (w > 1e-5f) {
        simd_quatf dq = simd_quaternion(w * dt, _angularVelocity / w);
        _node.simdOrientation = simd_normalize(simd_mul(_node.simdOrientation, dq));
    }

    // Arcade space flight: velocity is pulled toward the nose, so hard turns
    // drift before the engines catch up.
    float speed = _throttle * _maxSpeed + (boost ? _maxSpeed * 0.9f : 0);
    simd_float3 desired = self.forward * speed;
    float grip = boost ? 2.2f : 1.4f;
    _velocity += (desired - _velocity) * (1.0f - expf(-grip * dt));
    _node.simdPosition += _velocity * dt;

    // Shields regenerate slowly.
    _shield = fminf(1, _shield + 0.06f * dt);
    [self updateFx:dt];

    [_exhaust updateThrottle:_throttle boost:boost dt:dt];
}

- (simd_float3)nextGunWorldPosition {
    simd_float3 local = ToShip(_spec.guns[_gunIndex % _spec.gunCount]);
    _gunIndex++;
    _lastGunLocal = local;
    return _node.simdPosition + simd_act(_node.simdOrientation, local);
}

- (BOOL)takeDamage:(float)amount {
    BOOL shielded = _shield > 0.02f;
    if (shielded) [self flashShield];
    float absorbed = fminf(_shield, amount);
    _shield -= absorbed;
    _hull -= (amount - absorbed) * 1.0f;
    if (_hull <= 0) { _hull = 0; _alive = NO; [self updateFx:0]; }
    return shielded;
}

@end
