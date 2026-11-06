#import "Render.h"

#define MUZZLE_POOL 24
#define FLASH_LIGHTS 2

static float frand(void) { return (float)arc4random_uniform(1000000) / 1000000.0f; }
static simd_float3 randomUnit(void) {
    simd_float3 v;
    do { v = simd_make_float3(frand() * 2 - 1, frand() * 2 - 1, frand() * 2 - 1); }
    while (simd_length_squared(v) > 1 || simd_length_squared(v) < 0.01f);
    return simd_normalize(v);
}
static SCNVector3 V3(simd_float3 v) { return SCNVector3Make(v.x, v.y, v.z); }

// Soft-edged glow: brightest where the surface faces the camera.
static NSString *const kGlowFragment =
    @"#pragma arguments\n"
     "float3 tint;\n"
     "#pragma body\n"
     "float f = abs(dot(normalize(_surface.normal), normalize(_surface.view)));\n"
     "_output.color = float4(tint * pow(f, 2.2), 1.0);\n";

static NSString *const kTintFragment =
    @"#pragma arguments\n"
     "float3 tint;\n"
     "#pragma body\n"
     "_output.color.rgb *= tint;\n";

static SKColor *RGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) { return [SKColor colorWithRed:r green:g blue:b alpha:a]; }

@implementation Effects {
    SCNScene *_scene;
    SCNMaterial *_playerCore, *_playerGlow, *_enemyCore, *_enemyGlow;
    SCNMaterial *_ionCore, *_ionGlow;
    SCNGeometry *_coreGeo, *_glowGeo;
    NSMutableDictionary<NSString *, SCNMaterial *> *_streakMaterials;
    SCNNode *_muzzles[MUZZLE_POOL];
    NSUInteger _muzzleIndex;
    SCNMaterial *_muzzlePlayer, *_muzzleEnemy;
    SCNMaterial *_fireTemplate;
    NSMutableDictionary<NSNumber *, NSDictionary<NSString *, SCNParticleSystem *> *> *_explosionSystems;
    SCNNode *_flashLights[FLASH_LIGHTS];
    NSUInteger _flashIndex;
}

+ (SCNMaterial *)additiveTextureMaterial:(NSString *)texture tint:(simd_float3)tint {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;
    m.diffuse.contents = [Exhaust particleTexture:texture];
    m.blendMode = SCNBlendModeAdd;
    m.writesToDepthBuffer = NO;
    m.doubleSided = YES;
    m.shaderModifiers = @{ SCNShaderModifierEntryPointFragment : kTintFragment };
    [m setValue:[NSValue valueWithSCNVector3:V3(tint)] forKey:@"tint"];
    return m;
}

static SCNMaterial *GlowMaterial(simd_float3 tint) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;
    m.blendMode = SCNBlendModeAdd;
    m.writesToDepthBuffer = NO;
    m.shaderModifiers = @{ SCNShaderModifierEntryPointFragment : kGlowFragment };
    [m setValue:[NSValue valueWithSCNVector3:V3(tint)] forKey:@"tint"];
    return m;
}

- (instancetype)initWithScene:(SCNScene *)scene {
    if ((self = [super init])) {
        _scene = scene;
        // Cores read as white; the over-driven glow colour is what bloom spreads.
        _playerCore = GlowMaterial(simd_make_float3(5.0f, 9.0f, 6.0f));
        _playerGlow = GlowMaterial(simd_make_float3(0.25f, 2.4f, 0.6f));
        _enemyCore = GlowMaterial(simd_make_float3(9.0f, 5.5f, 4.5f));
        _enemyGlow = GlowMaterial(simd_make_float3(2.6f, 0.25f, 0.12f));
        _ionCore = GlowMaterial(simd_make_float3(5.5f, 7.5f, 11.0f));
        _ionGlow = GlowMaterial(simd_make_float3(0.4f, 1.2f, 3.2f));
        SCNCapsule *core = [SCNCapsule capsuleWithCapRadius:0.11 height:9];
        core.radialSegmentCount = 8;
        SCNCapsule *glow = [SCNCapsule capsuleWithCapRadius:0.5 height:11];
        glow.radialSegmentCount = 12;
        _coreGeo = core;
        _glowGeo = glow;
        _streakMaterials = [NSMutableDictionary dictionary];
        // Explosion lights live in the scene permanently at zero intensity:
        // changing the number of lights makes SceneKit re-specialise every
        // lit material, which showed up in Instruments as a frame hitch.
        for (int i = 0; i < FLASH_LIGHTS; i++) {
            SCNLight *light = [SCNLight light];
            light.type = SCNLightTypeOmni;
            light.color = RGBA(1, 0.7, 0.4, 1);
            light.attenuationEndDistance = 160;
            light.intensity = 0;
            _flashLights[i] = [SCNNode node];
            _flashLights[i].light = light;
            [scene.rootNode addChildNode:_flashLights[i]];
        }
        _fireTemplate = [SCNMaterial material];
        _fireTemplate.lightingModelName = SCNLightingModelConstant;
        _fireTemplate.blendMode = SCNBlendModeAdd;
        _fireTemplate.writesToDepthBuffer = NO;
        _fireTemplate.shaderModifiers = @{ SCNShaderModifierEntryPointGeometry : kFireGeometry,
                                           SCNShaderModifierEntryPointFragment : kFireFragment };
        [_fireTemplate setValue:@0 forKey:@"seed"];
        [_fireTemplate setValue:@0.1 forKey:@"turbulence"];
        [_fireTemplate setValue:@1 forKey:@"heat"];
        [_fireTemplate setValue:@1 forKey:@"fade"];
        _explosionSystems = [NSMutableDictionary dictionary];
        _muzzlePlayer = [Effects additiveTextureMaterial:@"star_06" tint:simd_make_float3(1.5f, 3.0f, 1.8f)];
        _muzzleEnemy = [Effects additiveTextureMaterial:@"star_06" tint:simd_make_float3(3.0f, 1.4f, 1.0f)];
        SCNPlane *plane = [SCNPlane planeWithWidth:1 height:1];
        for (int i = 0; i < MUZZLE_POOL; i++) {
            SCNNode *n = [SCNNode nodeWithGeometry:[plane copy]];
            SCNBillboardConstraint *bb = [SCNBillboardConstraint billboardConstraint];
            n.constraints = @[bb];
            n.castsShadow = NO;
            n.renderingOrder = 85;
            n.hidden = YES;
            _muzzles[i] = n;
        }
    }
    return self;
}

#pragma mark - Bolts

- (SCNNode *)makeBoltNode {
    SCNNode *n = [SCNNode node];
    SCNNode *core = [SCNNode nodeWithGeometry:[_coreGeo copy]];
    SCNNode *glow = [SCNNode nodeWithGeometry:[_glowGeo copy]];
    core.name = @"core";
    glow.name = @"glow";
    core.renderingOrder = 71;
    glow.renderingOrder = 70;
    core.castsShadow = glow.castsShadow = NO;
    [n addChildNode:glow];
    [n addChildNode:core];
    n.castsShadow = NO;
    return n;
}

- (void)styleBolt:(SCNNode *)bolt player:(BOOL)player ion:(BOOL)ion {
    for (SCNNode *c in bolt.childNodes) {
        BOOL core = [c.name isEqualToString:@"core"];
        if (ion) { c.geometry.firstMaterial = core ? _ionCore : _ionGlow; continue; }
        c.geometry.firstMaterial = core ? (player ? _playerCore : _enemyCore) : (player ? _playerGlow : _enemyGlow);
    }
}

- (SCNNode *)streakWithColor:(SKColor *)color width:(float)width height:(float)height {
    SCNPlane *plane = [SCNPlane planeWithWidth:1 height:1];
    CGFloat r = 0, g = 0, b = 0;
#if TARGET_OS_OSX
    color = [color colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
#endif
    [color getRed:&r green:&g blue:&b alpha:NULL];
    NSString *key = [NSString stringWithFormat:@"%.2f,%.2f,%.2f", r, g, b];
    SCNMaterial *m = _streakMaterials[key];
    if (!m) {
        m = [Effects additiveTextureMaterial:@"light_01" tint:simd_make_float3(r, g, b)];
        m.diffuse.contents = [Exhaust streakImage];
        m.diffuse.wrapS = m.diffuse.wrapT = SCNWrapModeClamp;
        _streakMaterials[key] = m;
    }
    plane.firstMaterial = m;
    SCNNode *n = [SCNNode nodeWithGeometry:plane];
    n.scale = SCNVector3Make(width, height, 1);
    n.castsShadow = NO;
    n.renderingOrder = 80;
    SCNBillboardConstraint *bb = [SCNBillboardConstraint billboardConstraint];
    bb.freeAxes = SCNBillboardAxisAll;
    n.constraints = @[bb];
    return n;
}

// Muzzle flashes come from a small pool of billboards, so firing creates
// no nodes or particle systems.
- (void)muzzleFlashOn:(SCNNode *)parent local:(simd_float3)local player:(BOOL)player {
    SCNNode *n = _muzzles[_muzzleIndex++ % MUZZLE_POOL];
    [n removeAllActions];
    [n removeFromParentNode];
    n.geometry.firstMaterial = player ? _muzzlePlayer : _muzzleEnemy;
    n.simdPosition = local;
    float s = 2.2f + frand() * 0.8f;
    n.scale = SCNVector3Make(s, s, s);
    n.eulerAngles = SCNVector3Make(0, 0, frand() * M_PI * 2);
    n.opacity = 1;
    n.hidden = NO;
    [parent addChildNode:n];
    [n runAction:[SCNAction sequence:@[[SCNAction fadeOutWithDuration:0.06], [SCNAction hide]]]];
}

#pragma mark - Hot spheres

// Explosions and impacts are built from a few shader-driven spheres instead
// of particle clouds. The geometry modifier boils the surface with moving
// noise; the fragment modifier maps "heat" through white -> yellow -> orange
// -> deep red and fades the soft silhouette, so one sphere reads as a ball of
// fire. Per-instance state lives in the material (age, heat, seed).
static NSString *const kFireGeometry =
    @"#pragma arguments\n"
     "float seed;\n"
     "float turbulence;\n"
     "#pragma body\n"
     "float3 p = _geometry.position.xyz * 3.0 + seed;\n"
     "float t = scn_frame.time * 2.5;\n"
     "float n = sin(p.x * 1.7 + t) * sin(p.y * 2.1 - t * 0.8) * sin(p.z * 1.9 + t * 0.6)\n"
     "        + 0.5 * sin(p.x * 4.3 - t * 1.3) * sin(p.y * 3.7 + t) * sin(p.z * 4.1);\n"
     "_geometry.position.xyz += _geometry.normal * n * turbulence;\n";

static NSString *const kFireFragment =
    @"#pragma arguments\n"
     "float heat;\n"
     "float fade;\n"
     "#pragma body\n"
     "float f = abs(dot(normalize(_surface.normal), normalize(_surface.view)));\n"
     "float h = saturate(heat * (0.55 + 0.45 * f));\n"
     "float3 c = h > 0.66 ? mix(float3(1.0, 0.72, 0.28), float3(1.0, 0.97, 0.9), (h - 0.66) / 0.34)\n"
     "         : h > 0.33 ? mix(float3(1.0, 0.32, 0.05), float3(1.0, 0.72, 0.28), (h - 0.33) / 0.33)\n"
     "         : mix(float3(0.25, 0.04, 0.02), float3(1.0, 0.32, 0.05), h / 0.33);\n"
     "float intensity = pow(f, 1.3) * fade * (1.0 + 5.0 * h * h);\n"
     "_output.color = float4(c * intensity, 1.0);\n";

- (SCNMaterial *)fireMaterialWithSeed:(float)seed {
    SCNMaterial *m = [_fireTemplate copy];
    [m setValue:@(seed) forKey:@"seed"];
    return m;
}

// One expanding, cooling fire sphere.
- (void)fireSphereAt:(SCNNode *)parent offset:(simd_float3)offset radius:(float)radius
            duration:(double)duration delay:(double)delay heat:(float)heat turbulence:(float)turb {
    SCNSphere *sphere = [SCNSphere sphereWithRadius:1];
    sphere.segmentCount = 40;
    SCNMaterial *m = [self fireMaterialWithSeed:frand() * 100];
    [m setValue:@(turb) forKey:@"turbulence"];
    [m setValue:@(0.0) forKey:@"fade"];
    sphere.firstMaterial = m;
    SCNNode *n = [SCNNode nodeWithGeometry:sphere];
    n.simdPosition = offset;
    n.castsShadow = NO;
    n.renderingOrder = 76;
    n.scale = SCNVector3Make(0.01, 0.01, 0.01);
    [parent addChildNode:n];
    float r0 = radius * 0.25f;
    [n runAction:[SCNAction sequence:@[
        [SCNAction waitForDuration:delay],
        [SCNAction customActionWithDuration:duration actionBlock:^(SCNNode *node, CGFloat elapsed) {
            float t = (float)(elapsed / duration);
            float grow = 1.0f - powf(1.0f - t, 3.0f);          // fast out, slow settle
            float r = r0 + (radius - r0) * grow;
            node.scale = SCNVector3Make(r, r, r);
            [m setValue:@(heat * powf(1.0f - t, 1.4f)) forKey:@"heat"];
            [m setValue:@(fminf(t * 12.0f, 1.0f) * powf(1.0f - t, 1.6f)) forKey:@"fade"];
        }],
        [SCNAction removeFromParentNode]]]];
}

#pragma mark - Impacts

- (void)impactAt:(simd_float3)p player:(BOOL)playerBolt shielded:(BOOL)shielded {
    SCNNode *n = [SCNNode node];
    n.simdPosition = p;
    [_scene.rootNode addChildNode:n];
    if (shielded) {
        // Shield hits flash blue-white via the ship's shield bubble; add a glint.
        SCNNode *streak = [self streakWithColor:RGBA(0.5, 0.75, 1.0, 1) width:10 height:0.4];
        [n addChildNode:streak];
        [streak runAction:[SCNAction fadeOutWithDuration:0.12]];
    } else {
        [self fireSphereAt:n offset:0 radius:1.6f duration:0.35 delay:0 heat:1.0f turbulence:0.15f];
    }
    [n runAction:[SCNAction sequence:@[[SCNAction waitForDuration:0.6], [SCNAction removeFromParentNode]]]];
}

#pragma mark - Explosions

// Explosions are layered sprite particles, the way game VFX build them:
// a short additive flash, a fireball of many small clumps where glowing
// flame pockets burn among dark soot and die first, the soot thinning out,
// and many burning fragments that shoot out, each trailing a short flame and
// a thin smoke line, so the blast radiates streaks. Particle colours are
// sRGB but blend in linear space, so a "dark grey" of 0.1 is black and low
// warm tones turn red. The soot stays dark and fades out rather than
// lightening into a grey cloud.

static CAKeyframeAnimation *OverLife(NSString *keyPath, NSArray *values, NSArray<NSNumber *> *times) {
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    a.values = values;
    a.keyTimes = times;
    return a;
}

static SCNParticleSystem *SpriteSystem(NSString *texture, SCNParticleBlendMode blend,
                                       NSArray<SKColor *> *colors, NSArray<NSNumber *> *colorTimes,
                                       NSArray<NSNumber *> *sizes, NSArray<NSNumber *> *sizeTimes) {
    SCNParticleSystem *ps = [SCNParticleSystem particleSystem];
    ps.particleImage = blend == SCNParticleBlendModeAlpha ? [Exhaust straightAlphaParticleTexture:texture]
                                                          : [Exhaust particleTexture:texture];
    ps.blendMode = blend;
    ps.lightingEnabled = NO;
    ps.sortingMode = SCNParticleSortingModeNone;
    ps.birthLocation = SCNParticleBirthLocationVolume;
    ps.birthDirection = SCNParticleBirthDirectionRandom;
    ps.particleAngleVariation = 360;
    ps.loops = NO;
    ps.propertyControllers = @{
        SCNParticlePropertyColor : [SCNParticlePropertyController controllerWithAnimation:OverLife(@"color", colors, colorTimes)],
        SCNParticlePropertySize : [SCNParticlePropertyController controllerWithAnimation:OverLife(@"size", sizes, sizeTimes)],
    };
    return ps;
}

static NSArray<NSNumber *> *Scaled(NSArray<NSNumber *> *values, float s) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:values.count];
    for (NSNumber *v in values) [out addObject:@(v.floatValue * s)];
    return out;
}

// The particle systems for one explosion size. Sizes are absolute in the
// property controllers, so each scale gets its own set, built once.
- (NSDictionary<NSString *, SCNParticleSystem *> *)explosionSystemsForScale:(float)s {
    NSNumber *key = @(roundf(s * 100) / 100);
    NSDictionary *cached = _explosionSystems[key];
    if (cached) return cached;

    SCNParticleSystem *flash = SpriteSystem(@"flare_01", SCNParticleBlendModeAdditive,
        @[RGBA(1, 0.95, 0.85, 1), RGBA(1, 0.6, 0.3, 0)], @[@0, @1],
        Scaled(@[@4, @10], s), @[@0, @1]);
    flash.birthRate = 2000; flash.emissionDuration = 0.001;
    flash.particleLifeSpan = 0.12;
    flash.particleIntensity = 0.5;
    flash.emitterShape = nil;

    // The fireball is mottled the way real ones are: bright flame pockets
    // and dark soot exist at the same time and the flame burns out first.
    // A pocket is the shaded smoke sprite tinted hot (its billows give the
    // flame shape; fire_01 keeps its detail only in alpha, which flattens
    // when alpha-blended) with a little additive fire_01 over it for glow.
    // Few sprites per pocket keep the glow from summing to a flat disc.
    // Three heats, picked per clump, so neighbouring pockets differ; hot
    // pockets are small and tight, cooler ones larger.
    NSArray<NSArray<SKColor *> *> *heats = @[
        @[RGBA(1, 0.9, 0.55, 1), RGBA(1, 0.65, 0.2, 1), RGBA(1, 0.35, 0.06, 0.9), RGBA(0.5, 0.1, 0.02, 0)],
        @[RGBA(1, 0.75, 0.35, 1), RGBA(1, 0.45, 0.1, 1), RGBA(0.85, 0.22, 0.04, 0.85), RGBA(0.4, 0.07, 0.02, 0)],
        @[RGBA(1, 0.55, 0.2, 1), RGBA(0.9, 0.3, 0.06, 0.95), RGBA(0.55, 0.12, 0.03, 0.8), RGBA(0.25, 0.05, 0.02, 0)],
    ];
    NSMutableArray<SCNParticleSystem *> *flames = [NSMutableArray array], *glows = [NSMutableArray array];
    for (NSUInteger h = 0; h < heats.count; h++) {
        float k = 0.7f + 0.3f * h;
        SCNParticleSystem *flame = SpriteSystem(@"smoke_07", SCNParticleBlendModeAlpha, heats[h], @[@0, @0.2, @0.5, @1],
            Scaled(@[@2, @4, @5], s * k), @[@0, @0.4, @1]);
        flame.birthRate = 150; flame.emissionDuration = 0.03;
        flame.emitterShape = [SCNSphere sphereWithRadius:1.2 * s * k];
        // Speeds spread from zero up, so braked sprites fill the clump
        // instead of all stopping on one shell.
        flame.particleVelocity = 6 * s; flame.particleVelocityVariation = 6 * s;
        flame.dampingFactor = 3;
        flame.particleLifeSpan = 0.8 + 0.3 * (2 - h); flame.particleLifeSpanVariation = 0.3;
        flame.particleAngularVelocityVariation = 90;
        flame.particleIntensity = 2.8;
        [flames addObject:flame];

        SCNParticleSystem *glow = [flame copy];
        glow.particleImage = [Exhaust particleTexture:@"fire_01"];
        glow.blendMode = SCNParticleBlendModeAdditive;
        glow.birthRate = 70;
        glow.particleIntensity = 0.6;
        [glows addObject:glow];
    }

    SCNParticleSystem *soot = SpriteSystem(@"smoke_07", SCNParticleBlendModeAlpha,
        @[RGBA(0.45, 0.18, 0.06, 0), RGBA(0.17, 0.12, 0.1, 0.9), RGBA(0.15, 0.14, 0.135, 0.85), RGBA(0.15, 0.14, 0.135, 0)],
        @[@0, @0.14, @0.45, @1],
        Scaled(@[@3.5, @6, @7], s), @[@0, @0.3, @1]);
    soot.birthRate = 200; soot.emissionDuration = 0.03;
    soot.emitterShape = [SCNSphere sphereWithRadius:2 * s];
    soot.particleVelocity = 11 * s; soot.particleVelocityVariation = 11 * s;
    soot.dampingFactor = 2.5;
    soot.particleLifeSpan = 1.8; soot.particleLifeSpanVariation = 0.4;
    soot.particleAngularVelocityVariation = 40;

    // Streaks behind the burning fragments, left in world space: a short
    // bright flame at the head and a thin smoke line that widens and greys.
    SCNParticleSystem *trailFire = SpriteSystem(@"fire_01", SCNParticleBlendModeAdditive,
        @[RGBA(1, 0.85, 0.55, 0.8), RGBA(1, 0.45, 0.1, 0.5), RGBA(0.3, 0.05, 0.01, 0)], @[@0, @0.4, @1],
        Scaled(@[@1.8, @1.2, @0.6], s), @[@0, @0.5, @1]);
    trailFire.birthRate = 90;
    trailFire.local = NO;
    trailFire.particleLifeSpan = 0.18; trailFire.particleLifeSpanVariation = 0.06;
    trailFire.particleAngularVelocityVariation = 200;
    trailFire.particleIntensity = 1.6;
    trailFire.emitterShape = nil;

    SCNParticleSystem *trailSmoke = SpriteSystem(@"smoke_07", SCNParticleBlendModeAlpha,
        @[RGBA(0.5, 0.2, 0.07, 0), RGBA(0.22, 0.15, 0.12, 0.6), RGBA(0.16, 0.15, 0.145, 0.45), RGBA(0.16, 0.15, 0.145, 0)],
        @[@0, @0.04, @0.15, @1],
        Scaled(@[@1.0, @1.8, @2.8], s), @[@0, @0.3, @1]);
    trailSmoke.birthRate = 240;
    trailSmoke.local = NO;
    trailSmoke.particleLifeSpan = 1.4; trailSmoke.particleLifeSpanVariation = 0.5;
    trailSmoke.particleVelocity = 0.5 * s;
    trailSmoke.particleAngularVelocityVariation = 60;
    trailSmoke.emitterShape = [SCNSphere sphereWithRadius:0.15 * s];

    NSDictionary *systems = @{ @"flash" : flash, @"flame0" : flames[0], @"flame1" : flames[1], @"flame2" : flames[2],
                               @"glow0" : glows[0], @"glow1" : glows[1], @"glow2" : glows[2], @"soot" : soot,
                               @"trailFire" : trailFire, @"trailSmoke" : trailSmoke };
    _explosionSystems[key] = systems;
    return systems;
}

- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull {
    [self explosionAt:p velocity:v hullMaterial:hull scale:1];
}

- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull scale:(float)scale {
    NSDictionary<NSString *, SCNParticleSystem *> *systems = [self explosionSystemsForScale:scale];
    SCNNode *root = [SCNNode node];
    root.simdPosition = p;
    [_scene.rootNode addChildNode:root];
    // The cloud keeps a little of the ship's momentum.
    [root runAction:[SCNAction moveBy:V3(v * 0.35f * 4.0f) duration:4.0]];

    SCNNode *flash = [SCNNode node];
    flash.renderingOrder = 90;
    [root addChildNode:flash];
    [flash addParticleSystem:[systems[@"flash"] copy]];
    // The fireball is several clumps at staggered offsets and times, so its
    // outline is irregular and it keeps boiling instead of one round ball.
    // SceneKit draws each particle system as one batch, so mixing comes
    // from draw order: each clump draws its soot, wider than its flame, and
    // then its flame, and the next clump's soot lands over the last one's
    // flame. Many small overlapping clumps of different heats read as fire
    // pockets divided by dark smoke.
    int clumps = 18 + (int)lroundf(6 * scale) + (int)arc4random_uniform(5);
    for (int i = 0; i < clumps; i++) {
        SCNNode *sootNode = [SCNNode node], *flameNode = [SCNNode node];
        sootNode.renderingOrder = 60 + 2 * i;
        flameNode.renderingOrder = 61 + 2 * i;
        simd_float3 at = randomUnit() * sqrtf(frand()) * 11 * scale;
        sootNode.simdPosition = flameNode.simdPosition = at;
        [root addChildNode:sootNode];
        [root addChildNode:flameNode];
        double delay = frand() * frand() * 0.3;
        int heat = (int)arc4random_uniform(3);
        [flameNode runAction:[SCNAction sequence:@[[SCNAction waitForDuration:delay], [SCNAction runBlock:^(SCNNode *n) {
            [sootNode addParticleSystem:[systems[@"soot"] copy]];
            [n addParticleSystem:[systems[[NSString stringWithFormat:@"flame%d", heat]] copy]];
            [n addParticleSystem:[systems[[NSString stringWithFormat:@"glow%d", heat]] copy]];
        }]]]];
    }

    // Anamorphic glint.
    SCNNode *glint = [self streakWithColor:RGBA(1, 0.75, 0.5, 1) width:120 * scale height:1.6 * scale];
    [root addChildNode:glint];
    [glint runAction:[SCNAction sequence:@[[SCNAction fadeOutWithDuration:0.35], [SCNAction removeFromParentNode]]]];

    int arms = (int)lroundf(8 + 6 * scale) + (int)arc4random_uniform(4);
    for (int i = 0; i < arms; i++) [self burningFragmentIn:root systems:systems hull:hull scale:scale];
    int pieces = 4 + (int)arc4random_uniform(3) + (int)(scale > 1 ? 4 : 0);
    for (int i = 0; i < pieces; i++) [self debrisFrom:p velocity:v hull:hull];

    // Light flash on nearby hulls, from the fixed pool.
    SCNNode *flashLight = _flashLights[_flashIndex++ % FLASH_LIGHTS];
    [flashLight removeAllActions];
    flashLight.simdPosition = p;
    [flashLight runAction:[SCNAction customActionWithDuration:0.9 actionBlock:^(SCNNode *node, CGFloat t) {
        node.light.intensity = 60000 * scale * powf(1.0f - (float)(t / 0.9), 2.0f);
    }]];
    [root runAction:[SCNAction sequence:@[[SCNAction waitForDuration:3.5], [SCNAction removeFromParentNode]]]];
}

// A burning fragment that shoots out, slows and bends a little while it emits
// fire and smoke into world space; the thin trail it leaves is one of the
// streaks radiating from the explosion.
- (void)burningFragmentIn:(SCNNode *)root systems:(NSDictionary<NSString *, SCNParticleSystem *> *)systems
                     hull:(SCNMaterial *)hull scale:(float)scale {
    simd_float3 dir = randomUnit();
    __block simd_float3 vel = dir * (75 + frand() * 45) * scale;
    // A slight sideways pull so streaks bend a little instead of ruled spokes.
    simd_float3 curl = simd_normalize(simd_cross(dir, randomUnit())) * frand() * 15 * scale;
    const float drag = 2.5f + frand() * 1.0f;
    const double burn = 0.7 + frand() * 0.4;

    SCNNode *head = [SCNNode node];
    head.simdPosition = dir * 2 * scale;
    [root addChildNode:head];
    SCNBox *box = [SCNBox boxWithWidth:(0.2 + frand() * 0.3) * scale height:(0.15 + frand() * 0.2) * scale
                                length:(0.3 + frand() * 0.5) * scale chamferRadius:0.03];
    SCNMaterial *bm = hull ? [hull copy] : [SCNMaterial material];
    bm.emission.contents = RGBA(1.0, 0.55, 0.2, 1);
    bm.emission.intensity = 4.0;
    box.firstMaterial = bm;
    SCNNode *chunk = [SCNNode nodeWithGeometry:box];
    [head addChildNode:chunk];
    simd_float3 spin = randomUnit() * (4 + frand() * 8);
    [chunk runAction:[SCNAction rotateByX:spin.x * burn y:spin.y * burn z:spin.z * burn duration:burn]];

    SCNNode *smokeNode = [SCNNode node], *fireNode = [SCNNode node];
    smokeNode.renderingOrder = 74;
    fireNode.renderingOrder = 77;
    [head addChildNode:smokeNode];
    [head addChildNode:fireNode];
    SCNParticleSystem *smoke = [systems[@"trailSmoke"] copy], *fire = [systems[@"trailFire"] copy];
    float smokeRate = smoke.birthRate, fireRate = fire.birthRate;
    [smokeNode addParticleSystem:smoke];
    [fireNode addParticleSystem:fire];

    __block double last = 0;
    [head runAction:[SCNAction sequence:@[
        [SCNAction customActionWithDuration:burn actionBlock:^(SCNNode *node, CGFloat elapsed) {
            float dt = (float)(elapsed - last);
            last = elapsed;
            if (dt <= 0) return;
            vel += (curl - vel * drag) * dt;
            node.simdPosition += vel * dt;
            float t = (float)(elapsed / burn);
            bm.emission.intensity = 4.0f * (1.0f - t);
            // The flame dies before the smoke does, so the tips are sooty.
            fire.birthRate = fireRate * (1.0f - t) * (1.0f - t);
            smoke.birthRate = smokeRate * (1.0f - 0.5f * t);
        }],
        [SCNAction runBlock:^(SCNNode *node) {
            fire.birthRate = 0;
            smoke.birthRate = 0;
            chunk.hidden = YES;
        }],
        // Keep the node until its smoke has died; removing it kills its particles.
        [SCNAction waitForDuration:2.5],
        [SCNAction removeFromParentNode]]]];
}

- (void)debrisFrom:(simd_float3)p velocity:(simd_float3)v hull:(SCNMaterial *)hull {
    float w = 0.4f + frand() * 1.6f, h = 0.15f + frand() * 0.6f, l = 0.5f + frand() * 2.0f;
    SCNBox *box = [SCNBox boxWithWidth:w height:h length:l chamferRadius:0.05];
    SCNMaterial *m = hull ? [hull copy] : [SCNMaterial material];
    if (hull) {
        // Reuse the hull texture, offset randomly, so chunks look like plating.
        m.diffuse.contentsTransform = SCNMatrix4Scale(SCNMatrix4MakeTranslation(frand(), frand(), 0), 0.15, 0.15, 1);
        m.diffuse.wrapS = m.diffuse.wrapT = SCNWrapModeRepeat;
    }
    m.emission.contents = RGBA(1.0, 0.45, 0.12, 1);
    m.emission.intensity = 3.0;
    box.firstMaterial = m;
    SCNNode *chunk = [SCNNode nodeWithGeometry:box];
    chunk.simdPosition = p + randomUnit() * 1.5f;
    [_scene.rootNode addChildNode:chunk];

    simd_float3 vel = v * 0.5f + randomUnit() * (25 + frand() * 55);
    simd_float3 spin = randomUnit() * (2 + frand() * 8);
    double life = 3.0 + frand() * 1.5;
    SCNAction *cool = [SCNAction customActionWithDuration:1.6 actionBlock:^(SCNNode *node, CGFloat t) {
        node.geometry.firstMaterial.emission.intensity = 3.0 * powf(1.0f - (float)(t / 1.6), 2.0f);
    }];
    [chunk runAction:[SCNAction group:@[[SCNAction moveBy:V3(vel * (float)life) duration:life],
                                        [SCNAction rotateByX:spin.x * life y:spin.y * life z:spin.z * life duration:life],
                                        cool,
                                        [SCNAction sequence:@[[SCNAction waitForDuration:life - 0.6], [SCNAction fadeOutWithDuration:0.6]]]]]
           completionHandler:^{ [chunk removeFromParentNode]; }];
}

#pragma mark - Warm-up

- (NSArray<SCNNode *> *)warmupNodes {
    // One of each effect material, so SceneKit compiles the pipelines up front
    // instead of hitching on the first explosion.
    SCNNode *fire = [SCNNode nodeWithGeometry:[SCNSphere sphereWithRadius:1]];
    fire.geometry.firstMaterial = [self fireMaterialWithSeed:1];
    SCNNode *streak = [self streakWithColor:RGBA(1, 0.75, 0.5, 1) width:1 height:1];
    SCNNode *bolt = [self makeBoltNode];
    [self styleBolt:bolt player:YES ion:NO];
    SCNNode *bolt2 = [self makeBoltNode];
    [self styleBolt:bolt2 player:NO ion:NO];
    SCNNode *muzzle = [SCNNode nodeWithGeometry:[SCNPlane planeWithWidth:1 height:1]];
    muzzle.geometry.firstMaterial = _muzzlePlayer;
    SCNNode *particles = [SCNNode node];
    for (SCNParticleSystem *ps in [self explosionSystemsForScale:1].allValues) {
        SCNParticleSystem *idle = [ps copy];
        idle.birthRate = 0;
        [particles addParticleSystem:idle];
    }
    return @[fire, particles, streak, bolt, bolt2, muzzle];
}

@end
