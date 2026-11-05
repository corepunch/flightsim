#import "ShipView.h"

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

        NSURL *url = [[NSBundle mainBundle] URLForResource:@(def->mesh) withExtension:@"scn" subdirectory:@"Models"];   // baked by build.sh
        SCNScene *scene = url ? [SCNScene sceneWithURL:url options:nil error:nil] : nil;
        __block SCNGeometry *found = nil;
        [scene.rootNode enumerateHierarchyUsingBlock:^(SCNNode *child, BOOL *stop) {
            if (child.geometry) { found = child.geometry; *stop = YES; }
        }];
        g = [found copy] ?: [SCNBox boxWithWidth:4 height:1 length:6 chamferRadius:0];

        SCNMaterial *m = [SCNMaterial material];
        m.lightingModelName = SCNLightingModelPhysicallyBased;
        m.diffuse.contents = [[NSBundle mainBundle] URLForResource:@(def->texture) withExtension:@"png" subdirectory:@"Models"];
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
    fc.values = @[[SKColor colorWithRed:1 green:0.85 blue:0.5 alpha:1], [SKColor colorWithRed:1 green:0.35 blue:0.08 alpha:0]];
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
    sc.values = @[[SKColor colorWithRed:0.2 green:0.18 blue:0.17 alpha:0.55], [SKColor colorWithRed:0.15 green:0.15 blue:0.16 alpha:0]];
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

- (void)updateThrottle:(float)throttle boost:(BOOL)boost hull:(float)hull alive:(BOOL)alive dt:(float)dt {
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
