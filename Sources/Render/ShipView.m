#import "Render.h"
#import "Shared.h"

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

// Ceiling sits just under ClientView's bloomThreshold (0.9).
static NSString *const kHullRolloff =
    @"#pragma body\n"
     "float3 emit = _surface.emission.rgb;\n"
     "float3 lit = max(_output.color.rgb - emit, float3(0.0));\n"
     "float peak = max(max(lit.r, lit.g), lit.b);\n"
     "const float knee = 0.55, ceil = 0.85;\n"
     "if (peak > knee) {\n"
     "    float rolled = knee + (ceil - knee) * (1.0 - exp(-(peak - knee) / (ceil - knee)));\n"
     "    lit *= rolled / peak;\n"
     "}\n"
     "_output.color.rgb = lit + emit;\n";

void ApplyHullRolloff(SCNMaterial *m) {
    NSMutableDictionary *mods = [m.shaderModifiers mutableCopy] ?: [NSMutableDictionary dictionary];
    mods[SCNShaderModifierEntryPointFragment] = kHullRolloff;
    m.shaderModifiers = mods;
}

@implementation ShipView {
    SCNNode *_shieldNode;
    SCNMaterial *_shieldMaterial;
    float _shieldFlash;
    float _hull;
    float _sinceHit;    // seconds since the hull last dropped; drives the burn-out
    BOOL _alive;
    SCNParticleSystem *_damageFire, *_damageSmoke;
}

// One geometry per definition, shared by every view of it. The load queue
// and the render thread can both ask, so the cache is locked.
+ (SCNGeometry *)geometryForDefinition:(const ShipDef *)def {
    static NSMutableDictionary<NSString *, SCNGeometry *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (!def) return nil;
    NSString *key = @(def->name);
    @synchronized (cache) {
        SCNGeometry *g = cache[key];
        if (g) return g;

        NSURL *url = FSURL(@"Models", @(def->mesh), @"scn");   // baked by build.sh
        SCNScene *scene = url ? [SCNScene sceneWithURL:url options:nil error:nil] : nil;
        __block SCNGeometry *found = nil;
        [scene.rootNode enumerateHierarchyUsingBlock:^(SCNNode *child, BOOL *stop) {
            if (child.geometry) { found = child.geometry; *stop = YES; }
        }];
        g = [found copy] ?: [SCNBox boxWithWidth:4 height:1 length:6 chamferRadius:0];

        SCNMaterial *m = [SCNMaterial material];
        m.lightingModelName = SCNLightingModelPhysicallyBased;
        m.diffuse.contents = FSURL(@"Models", @(def->texture), @"png");
        m.diffuse.mipFilter = SCNFilterModeLinear;
        m.diffuse.maxAnisotropy = 8;
        m.metalness.contents = @0.55;
        m.roughness.contents = @0.42;
        ApplyHullRolloff(m);
        g.materials = @[m];
        cache[key] = g;
        return g;
    }
}

+ (instancetype)shipWithDefinition:(const ShipDef *)definition smoke:(BOOL)smoke {
    return definition ? [[self alloc] initWithDefinition:definition smoke:smoke] : nil;
}

+ (instancetype)viewWithModel:(NSString *)model {
    return [self shipWithDefinition:ShipDefForModel(model) smoke:YES];
}

- (instancetype)initWithDefinition:(const ShipDef *)def smoke:(BOOL)smoke {
    if ((self = [super init])) {
        _definition = def;
        _radius = def->radius;
        _node = [SCNNode node];
        _model = [SCNNode nodeWithGeometry:[ShipView geometryForDefinition:def]];
        _model.eulerAngles = SCNVector3Make(0, M_PI, 0);   // OBJ +Z nose -> ship -Z nose
        _model.castsShadow = YES;
        [_node addChildNode:_model];

        _exhaust = [[Exhaust alloc] initWithNozzles:def->nozzles count:(NSUInteger)def->nozzleCount
                                              color:def->exhaustColor parent:_node smoke:smoke];
        [self buildShield];
        [self buildDamageFx];
        _hull = 1;
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
    // A damaged ship licks small flames and a thin smoke plume off its hull.
    // Both are in the ship's frame and drift back over a few metres only, so
    // the plume trails the hull without reaching the chase camera 14 m behind.
    SCNNode *spot = [SCNNode node];
    spot.position = SCNVector3Make(_radius * 0.3f, 0.35f, 0.6f);
    [_node addChildNode:spot];
    SCNVector3 aft = SCNVector3Make(0, 0.35f, 1);

    _damageFire = [SCNParticleSystem particleSystem];
    _damageFire.particleImage = [Exhaust particleTexture:@"flame_02"];
    _damageFire.blendMode = SCNParticleBlendModeAdditive;
    _damageFire.local = YES;
    _damageFire.birthRate = 0;
    _damageFire.particleLifeSpan = 0.28;
    _damageFire.particleLifeSpanVariation = 0.08;
    _damageFire.particleSize = _radius * 0.16f;
    _damageFire.particleSizeVariation = _radius * 0.05f;
    _damageFire.particleAngleVariation = 180;
    _damageFire.particleAngularVelocityVariation = 160;
    _damageFire.particleIntensity = 1.2;
    _damageFire.particleVelocity = 2.5;
    _damageFire.spreadingAngle = 25;
    _damageFire.emittingDirection = aft;
    CAKeyframeAnimation *fc = [CAKeyframeAnimation animationWithKeyPath:@"color"];
    fc.values = @[[SKColor colorWithRed:1 green:0.85 blue:0.55 alpha:0.9], [SKColor colorWithRed:1 green:0.45 blue:0.1 alpha:0.6],
                  [SKColor colorWithRed:0.6 green:0.12 blue:0.02 alpha:0]];
    fc.keyTimes = @[@0, @0.4, @1];
    CAKeyframeAnimation *fs = [CAKeyframeAnimation animationWithKeyPath:@"size"];
    fs.values = @[@0.7, @1.0, @0.4];
    fs.keyTimes = @[@0, @0.3, @1];
    _damageFire.propertyControllers = @{ SCNParticlePropertyColor : [SCNParticlePropertyController controllerWithAnimation:fc],
                                         SCNParticlePropertySize : [SCNParticlePropertyController controllerWithAnimation:fs] };
    [spot addParticleSystem:_damageFire];

    _damageSmoke = [SCNParticleSystem particleSystem];
    _damageSmoke.particleImage = [Exhaust straightAlphaParticleTexture:@"smoke_01"];
    _damageSmoke.blendMode = SCNParticleBlendModeAlpha;
    _damageSmoke.lightingEnabled = NO;
    _damageSmoke.local = YES;
    _damageSmoke.birthRate = 0;
    _damageSmoke.particleLifeSpan = 1.0;
    _damageSmoke.particleLifeSpanVariation = 0.25;
    _damageSmoke.particleSize = _radius * 0.14f;
    _damageSmoke.particleAngleVariation = 180;
    _damageSmoke.particleAngularVelocityVariation = 40;
    _damageSmoke.particleVelocity = 4.5;
    _damageSmoke.particleVelocityVariation = 1.5;
    _damageSmoke.spreadingAngle = 12;
    _damageSmoke.emittingDirection = aft;
    CAKeyframeAnimation *sc = [CAKeyframeAnimation animationWithKeyPath:@"color"];
    sc.values = @[[SKColor colorWithRed:0.32 green:0.27 blue:0.24 alpha:0], [SKColor colorWithRed:0.24 green:0.23 blue:0.23 alpha:0.42],
                  [SKColor colorWithRed:0.2 green:0.2 blue:0.21 alpha:0]];
    sc.keyTimes = @[@0, @0.15, @1];
    CAKeyframeAnimation *ss = [CAKeyframeAnimation animationWithKeyPath:@"size"];
    ss.values = @[@1.0, @3.0];
    ss.keyTimes = @[@0, @1];
    _damageSmoke.propertyControllers = @{ SCNParticlePropertyColor : [SCNParticlePropertyController controllerWithAnimation:sc],
                                          SCNParticlePropertySize : [SCNParticlePropertyController controllerWithAnimation:ss] };
    [spot addParticleSystem:_damageSmoke];
}

// A hit below 60% hull sets the ship alight. The fire burns for a few seconds
// and goes out, leaving smoke that thins away after it; the next hit reignites
// both. Returns how hard each burns now, 0..1.
static void BurnLevels(float sinceHit, float *fire, float *smoke) {
    const float fireHold = 2.5f, fireOut = 5.0f, smokeHold = 4.0f, smokeOut = 8.0f;
    *fire = clampf(1.0f - (sinceHit - fireHold) / (fireOut - fireHold), 0, 1);
    *smoke = clampf(1.0f - (sinceHit - smokeHold) / (smokeOut - smokeHold), 0, 1);
}

- (void)flashShield {
    _shieldFlash = 1;
    _shieldNode.hidden = NO;
}

- (void)updateFx:(float)dt {
    _shieldFlash = fmaxf(0, _shieldFlash - dt * 2.8f);
    _shieldNode.hidden = _shieldFlash <= 0.001f || !_alive;
    [_shieldMaterial setValue:@(_shieldFlash) forKey:@"level"];
    _sinceHit += dt;
    float dmg = _alive ? fmaxf(0, 0.6f - _hull) / 0.6f : 0, fire, smoke;
    BurnLevels(_sinceHit, &fire, &smoke);
    _damageFire.birthRate = dmg > 0 ? (10 + 20 * dmg) * fire : 0;
    _damageSmoke.birthRate = dmg > 0 ? (8 + 14 * dmg) * smoke : 0;
}

- (void)updateThrottle:(float)throttle boost:(BOOL)boost hull:(float)hull alive:(BOOL)alive dt:(float)dt {
    if (hull < _hull - 0.001f) _sinceHit = 0;
    _hull = hull;
    _alive = alive;
    [self updateFx:dt];
    [_exhaust updateThrottle:throttle boost:boost dt:dt];
}

- (void)setAlive:(BOOL)alive {
    _alive = alive;
    _node.hidden = !alive;
    [_exhaust setEnabled:alive];
    [self updateFx:0];
}

@end
