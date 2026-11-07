#import "Render.h"
#import "Shared.h"

// Keep the impact patch attached to the ship as it turns and the camera moves.
static NSString *const kShieldGeometry =
    @"#pragma varyings\n"
     "float3 shieldPosition;\n"
     "#pragma body\n"
     "out.shieldPosition = _geometry.position.xyz;\n";

// The rest of the bubble contributes no light outside the impact patch.
static NSString *const kShieldFragment =
    @"#pragma arguments\n"
     "float level;\n"
     "float3 hitDirection;\n"
     "#pragma body\n"
     "float patch = smoothstep(0.65, 0.95, dot(normalize(in.shieldPosition), hitDirection));\n"
     "float f = 1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view)));\n"
     "float3 p = _surface.position * 1.7;\n"
     "float ripple = 0.6 + 0.4 * sin(p.x * 3.0 + scn_frame.time * 9.0) * sin(p.y * 3.0 - scn_frame.time * 7.0) * sin(p.z * 3.0);\n"
     "float a = (pow(f, 2.5) * 1.6 + 0.12) * ripple * level * patch;\n"
     "_output.color = float4(float3(0.35, 0.65, 1.0) * a * 2.5, a);\n";

// Keep reflected hull light below the white emission range.
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
    SCNNode *_propeller;
    SCNParticleSystem *_damageFire, *_damageCore, *_damageSmoke;
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

        if (!def->texture[0]) {
            NSMutableArray *materials = [NSMutableArray array];
            for (SCNMaterial *source in g.materials) {
                SCNMaterial *material = [source copy];
                material.lightingModelName = SCNLightingModelPhysicallyBased;
                material.metalness.contents = @0;
                material.roughness.contents = @0.85;
                material.doubleSided = YES;
                [materials addObject:material];
            }
            g.materials = materials;
            cache[key] = g;
            return g;
        }
        SCNMaterial *m = [SCNMaterial material];
        m.lightingModelName = SCNLightingModelPhysicallyBased;
        m.diffuse.contents = [RenderTextures contentsOfURL:FSURL(@"Models", @(def->texture), @"png") sRGB:YES];
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
        if (def->propeller.w > 0) {
            _propeller = [SCNNode node];
            _propeller.simdPosition = simd_make_float3(def->propeller);
            SCNBox *blade = [SCNBox boxWithWidth:0.13 height:def->propeller.w * 2 length:0.06 chamferRadius:0.03];
            blade.firstMaterial.diffuse.contents = [SKColor colorWithRed:0.27 green:0.13 blue:0.05 alpha:1];
            [_propeller addChildNode:[SCNNode nodeWithGeometry:blade]];
            [_node addChildNode:_propeller];
        }

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
    _shieldMaterial.shaderModifiers = @{ SCNShaderModifierEntryPointGeometry : kShieldGeometry,
                                         SCNShaderModifierEntryPointFragment : kShieldFragment };
    [_shieldMaterial setValue:@0 forKey:@"level"];
    [_shieldMaterial setValue:[NSValue valueWithSCNVector3:SCNVector3Make(0, 0, -1)] forKey:@"hitDirection"];
    sphere.firstMaterial = _shieldMaterial;
    _shieldNode = [SCNNode nodeWithGeometry:sphere];
    _shieldNode.scale = SCNVector3Make(_radius * 1.15, _radius * 0.5, _radius * 1.05);
    _shieldNode.castsShadow = NO;
    _shieldNode.renderingOrder = 90;
    _shieldNode.hidden = YES;
    [_node addChildNode:_shieldNode];
}

static CAKeyframeAnimation *OverLife(NSString *keyPath, NSArray *values, NSArray<NSNumber *> *times) {
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    a.values = values;
    a.keyTimes = times;
    return a;
}

// Each particle shows one sprite of a 2 x 2 atlas, picked at random, held for its life.
static void RandomSpriteOf4(SCNParticleSystem *ps) {
    ps.imageSequenceColumnCount = ps.imageSequenceRowCount = 2;
    ps.imageSequenceFrameRate = 0;
    ps.imageSequenceInitialFrame = 0;
    ps.imageSequenceInitialFrameVariation = 4;
    ps.imageSequenceAnimationMode = SCNParticleImageSequenceAnimationModeRepeat;
}

- (void)buildDamageFx {
    // A damaged ship streams fire off its hull like a burning wing: a narrow
    // flame that leaves the hull fast, widens and cools into dark smoke. Both
    // are in the ship's frame and end about 10 m aft, short of the chase
    // camera 14 m behind, so the stream trails the ship without covering the view.
    SCNNode *spot = [SCNNode node], *fireNode = [SCNNode node], *smokeNode = [SCNNode node];
    spot.position = SCNVector3Make(_radius * 0.3f, 0.2f, 0.6f);
    [_node addChildNode:spot];
    // Smoke trails the flame toward the chase camera, so it draws over it.
    fireNode.renderingOrder = 76;
    smokeNode.renderingOrder = 77;
    [spot addChildNode:fireNode];
    [spot addChildNode:smokeNode];
    // Aft, angled a little outboard and down, so from the chase camera the
    // stream streaks off the wing rather than pointing into the lens.
    SCNVector3 aft = SCNVector3Make(0.28f, -0.22f, 1);
    float r = _radius;

    _damageFire = [SCNParticleSystem particleSystem];
    // Alpha-blended so the flame reads as a body of fire rather than adding up
    // to a glare, and each particle a different tongue of flame.
    _damageFire.particleImage = [Exhaust straightAlphaParticleTexture:@"flame_01+flame_02+flame_03+flame_04"];
    _damageFire.blendMode = SCNParticleBlendModeAlpha;
    _damageFire.lightingEnabled = NO;
    _damageFire.sortingMode = SCNParticleSortingModeProjectedDepth;
    RandomSpriteOf4(_damageFire);
    _damageFire.local = YES;
    _damageFire.birthRate = 0;
    _damageFire.particleLifeSpan = 0.45;
    _damageFire.particleLifeSpanVariation = 0.12;
    _damageFire.particleAngleVariation = 180;
    _damageFire.particleAngularVelocityVariation = 90;
    _damageFire.particleIntensity = 4.0;
    _damageFire.particleVelocity = 13;
    _damageFire.particleVelocityVariation = 3;
    _damageFire.spreadingAngle = 5;
    _damageFire.emittingDirection = aft;
    _damageFire.stretchFactor = 0.02;
    _damageFire.propertyControllers = @{
        SCNParticlePropertyColor : [SCNParticlePropertyController controllerWithAnimation:OverLife(@"color",
            @[[SKColor colorWithRed:1 green:0.95 blue:0.7 alpha:1], [SKColor colorWithRed:1 green:0.78 blue:0.32 alpha:0.95],
              [SKColor colorWithRed:1 green:0.45 blue:0.1 alpha:0.7], [SKColor colorWithRed:0.35 green:0.1 blue:0.04 alpha:0]],
            @[@0, @0.35, @0.7, @1])],
        SCNParticlePropertySize : [SCNParticlePropertyController controllerWithAnimation:OverLife(@"size",
            @[@(r * 0.1f), @(r * 0.26f), @(r * 0.36f)], @[@0, @0.35, @1])],
    };
    [fireNode addParticleSystem:_damageFire];

    // The hot root: a few short additive tongues where the stream leaves the
    // hull. Too few and too brief to add up to a glare.
    _damageCore = [_damageFire copy];
    _damageCore.particleImage = [Exhaust particleTexture:@"flame_01+flame_02+flame_03+flame_04"];
    _damageCore.blendMode = SCNParticleBlendModeAdditive;
    _damageCore.sortingMode = SCNParticleSortingModeNone;
    _damageCore.particleLifeSpan = 0.14;
    _damageCore.particleLifeSpanVariation = 0.04;
    _damageCore.particleIntensity = 3.0;
    _damageCore.propertyControllers = @{
        SCNParticlePropertyColor : [SCNParticlePropertyController controllerWithAnimation:OverLife(@"color",
            @[[SKColor colorWithRed:1 green:0.9 blue:0.6 alpha:0.9], [SKColor colorWithRed:1 green:0.55 blue:0.15 alpha:0]], @[@0, @1])],
        SCNParticlePropertySize : [SCNParticlePropertyController controllerWithAnimation:OverLife(@"size",
            @[@(r * 0.1f), @(r * 0.2f)], @[@0, @1])],
    };
    [fireNode addParticleSystem:_damageCore];

    // Slower than the flame, so it fills in behind the flame and carries the stream on.
    _damageSmoke = [SCNParticleSystem particleSystem];
    _damageSmoke.particleImage = [Exhaust straightAlphaParticleTexture:@"smoke_01+smoke_04+smoke_05+smoke_07"];
    _damageSmoke.sortingMode = SCNParticleSortingModeProjectedDepth;
    RandomSpriteOf4(_damageSmoke);
    _damageSmoke.blendMode = SCNParticleBlendModeAlpha;
    _damageSmoke.lightingEnabled = NO;
    _damageSmoke.local = YES;
    _damageSmoke.birthRate = 0;
    _damageSmoke.particleLifeSpan = 0.9;
    _damageSmoke.particleLifeSpanVariation = 0.15;
    _damageSmoke.particleAngleVariation = 180;
    _damageSmoke.particleAngularVelocityVariation = 40;
    _damageSmoke.particleVelocity = 10;
    _damageSmoke.particleVelocityVariation = 2;
    _damageSmoke.spreadingAngle = 7;
    _damageSmoke.emittingDirection = aft;
    _damageSmoke.propertyControllers = @{
        SCNParticlePropertyColor : [SCNParticlePropertyController controllerWithAnimation:OverLife(@"color",
            @[[SKColor colorWithRed:0.1 green:0.08 blue:0.07 alpha:0], [SKColor colorWithRed:0.1 green:0.09 blue:0.09 alpha:0],
              [SKColor colorWithRed:0.09 green:0.09 blue:0.09 alpha:0.6], [SKColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:0]],
            @[@0, @0.3, @0.5, @1])],
        SCNParticlePropertySize : [SCNParticlePropertyController controllerWithAnimation:OverLife(@"size",
            @[@(r * 0.2f), @(r * 0.4f), @(r * 0.55f)], @[@0, @0.5, @1])],
    };
    [smokeNode addParticleSystem:_damageSmoke];
}

// A hit below 60% hull sets the ship alight. The fire burns for a few seconds
// and goes out, leaving smoke that thins away after it; the next hit reignites
// both. Returns how hard each burns now, 0..1.
static void BurnLevels(float sinceHit, float *fire, float *smoke) {
    const float fireHold = 3.0f, fireOut = 6.0f, smokeHold = 5.0f, smokeOut = 9.0f;
    *fire = clampf(1.0f - (sinceHit - fireHold) / (fireOut - fireHold), 0, 1);
    *smoke = clampf(1.0f - (sinceHit - smokeHold) / (smokeOut - smokeHold), 0, 1);
}

- (void)flashShieldFrom:(simd_float3)direction {
    if (simd_length_squared(direction) < 1e-6f) return;
    // The bubble is an ellipsoid; map the ship-space direction to its unit sphere.
    simd_float3 hit = simd_normalize(direction / _shieldNode.simdScale);
    [_shieldMaterial setValue:[NSValue valueWithSCNVector3:SCNVector3FromFloat3(hit)] forKey:@"hitDirection"];
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
    _damageFire.birthRate = dmg > 0 ? (60 + 50 * dmg) * fire : 0;
    _damageCore.birthRate = _damageFire.birthRate * 0.5f;
    _damageSmoke.birthRate = dmg > 0 ? (18 + 18 * dmg) * smoke : 0;
}

- (void)updateThrottle:(float)throttle boost:(BOOL)boost hull:(float)hull alive:(BOOL)alive dt:(float)dt {
    if (hull < _hull - 0.001f) _sinceHit = 0;
    _hull = hull;
    _alive = alive;
    [self updateFx:dt];
    [_exhaust updateThrottle:throttle boost:boost dt:dt];
    if (alive && _propeller) _propeller.eulerAngles = SCNVector3Make(0, 0, _propeller.eulerAngles.z + dt * (45 + throttle * 130));
}

- (void)setAlive:(BOOL)alive {
    _alive = alive;
    _node.hidden = !alive;
    [_exhaust setEnabled:alive];
    [self updateFx:0];
}

@end
