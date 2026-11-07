#import "Render.h"
#import <ImageIO/ImageIO.h>

#define MUZZLE_POOL 24
#define FLASH_LIGHTS 2
enum { BoltPlayer, BoltEnemy, BoltIon, BOLT_STYLES };
#define BOLT_LENGTH 16      // metres; the bolt's head is the node, the streak trails it

static float frand(void) { return (float)arc4random_uniform(1000000) / 1000000.0f; }
static simd_float3 randomUnit(void) {
    simd_float3 v;
    do { v = simd_make_float3(frand() * 2 - 1, frand() * 2 - 1, frand() * 2 - 1); }
    while (simd_length_squared(v) > 1 || simd_length_squared(v) < 0.01f);
    return simd_normalize(v);
}
static SCNVector3 V3(simd_float3 v) { return SCNVector3Make(v.x, v.y, v.z); }

static NSString *const kTintFragment =
    @"#pragma arguments\n"
     "float3 tint;\n"
     "#pragma body\n"
     "_output.color.rgb *= tint;\n";

static SKColor *RGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) { return [SKColor colorWithRed:r green:g blue:b alpha:a]; }

// MARK: - Explosion kits

// SceneKit builds a colour ramp for every particle system that has property
// controllers and never frees it (macOS 26, iOS 26): a system copied for
// each explosion left about a kilobyte behind for good. So the systems of
// one explosion are kept as a kit and lent out again: taken off the last
// explosion's nodes, restarted and attached to the new one's. Only the
// birth rate is set on them afterwards, which leaves the ramp alone.
@interface PooledSystem : NSObject
@property (nonatomic, readonly) SCNParticleSystem *system;
@property (nonatomic, readonly) NSUInteger uses;    // counts the explosions it served; a stale action compares
@end

@implementation PooledSystem {
    __weak SCNNode *_host;
    CGFloat _birthRate;      // the template's, restored for each use
}

- (instancetype)initWithTemplate:(SCNParticleSystem *)template {
    if ((self = [super init])) {
        _system = [template copy];
        _birthRate = template.birthRate;
    }
    return self;
}

- (SCNParticleSystem *)takeOn:(SCNNode *)node {
    [_host removeParticleSystem:_system];
    [_system reset];
    _system.birthRate = _birthRate;
    [node addParticleSystem:_system];
    _host = node;
    _uses++;
    return _system;
}

@end

// Every system one explosion of a given scale needs: the flash and embers
// at the centre and a fire and smoke trail for each burning fragment.
@interface ExplosionKit : NSObject
@property (nonatomic, readonly) PooledSystem *flash, *embers;
@property (nonatomic, readonly) NSArray<PooledSystem *> *fires, *smokes;
@end

@implementation ExplosionKit

- (instancetype)initWithSystems:(NSDictionary<NSString *, SCNParticleSystem *> *)systems fragments:(NSUInteger)fragments {
    if ((self = [super init])) {
        _flash = [[PooledSystem alloc] initWithTemplate:systems[@"flash"]];
        _embers = [[PooledSystem alloc] initWithTemplate:systems[@"embers"]];
        NSMutableArray *fires = [NSMutableArray arrayWithCapacity:fragments], *smokes = [NSMutableArray arrayWithCapacity:fragments];
        for (NSUInteger i = 0; i < fragments; i++) {
            [fires addObject:[[PooledSystem alloc] initWithTemplate:systems[@"trailFire"]]];
            [smokes addObject:[[PooledSystem alloc] initWithTemplate:systems[@"trailSmoke"]]];
        }
        _fires = fires;
        _smokes = smokes;
    }
    return self;
}

@end

// MARK: - Effects

@implementation Effects {
    SCNScene *_scene;
    // One core and one glow capsule per bolt style, shared by every bolt
    // node: the pool of hundreds of bolts carries no geometry of its own.
    SCNGeometry *_boltCore[BOLT_STYLES], *_boltGlow[BOLT_STYLES];
    SCNGeometry *_tracerCore;
    NSMutableDictionary<NSString *, SCNMaterial *> *_streakMaterials;
    SCNNode *_muzzles[MUZZLE_POOL];
    NSUInteger _muzzleIndex;
    SCNMaterial *_muzzlePlayer, *_muzzleEnemy;
    SCNMaterial *_fireTemplate;
    NSMutableDictionary<NSNumber *, NSDictionary<NSString *, SCNParticleSystem *> *> *_explosionSystems;
    NSMutableDictionary<NSNumber *, NSMutableArray<ExplosionKit *> *> *_explosionKits;   // per scale, least recently used first
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

// An additive streak the bolt image long, in one tint.
static SCNMaterial *BoltMaterial(simd_float3 tint) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;
    m.diffuse.contents = [Exhaust boltImage];
    m.diffuse.wrapS = m.diffuse.wrapT = SCNWrapModeClamp;
    m.blendMode = SCNBlendModeAdd;
    m.writesToDepthBuffer = NO;
    m.doubleSided = YES;
    m.shaderModifiers = @{ SCNShaderModifierEntryPointFragment : kTintFragment };
    [m setValue:[NSValue valueWithSCNVector3:V3(tint)] forKey:@"tint"];
    return m;
}

static SCNGeometry *BoltStreak(CGFloat width, CGFloat length, simd_float3 tint) {
    SCNPlane *plane = [SCNPlane planeWithWidth:width height:length];
    plane.firstMaterial = BoltMaterial(tint);
    return plane;
}

- (instancetype)initWithScene:(SCNScene *)scene {
    if ((self = [super init])) {
        _scene = scene;
        // A near-white core line inside a wider, coloured glow.
        const simd_float3 cores[BOLT_STYLES] = { { 1.3f, 1.7f, 1.4f }, { 1.8f, 1.2f, 1.0f }, { 1.1f, 1.4f, 1.8f } };
        const simd_float3 glows[BOLT_STYLES] = { { 0.2f, 1.1f, 0.4f }, { 1.1f, 0.2f, 0.1f }, { 0.3f, 0.6f, 1.1f } };
        for (int i = 0; i < BOLT_STYLES; i++) {
            _boltCore[i] = BoltStreak(0.4, BOLT_LENGTH, cores[i]);
            _boltGlow[i] = BoltStreak(1.5, BOLT_LENGTH, glows[i]);
        }
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
        _explosionKits = [NSMutableDictionary dictionary];
        // A soft round flash at the gun, not a lens star.
        _muzzlePlayer = [Effects additiveTextureMaterial:@"flare_01" tint:simd_make_float3(0.9f, 2.0f, 1.1f)];
        _muzzleEnemy = [Effects additiveTextureMaterial:@"flare_01" tint:simd_make_float3(2.0f, 0.9f, 0.6f)];
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
    SCNNode *core = [SCNNode nodeWithGeometry:_boltCore[BoltPlayer]];
    SCNNode *glow = [SCNNode nodeWithGeometry:_boltGlow[BoltPlayer]];
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
    int style = ion ? BoltIon : player ? BoltPlayer : BoltEnemy;
    for (SCNNode *c in bolt.childNodes)
        c.geometry = [c.name isEqualToString:@"core"] ? _boltCore[style] : _boltGlow[style];
}

- (void)setBolt:(SCNNode *)bolt length:(float)travelled {
    float k = fminf(1, fmaxf(travelled, 0.5f) / BOLT_LENGTH);
    for (SCNNode *c in bolt.childNodes) {
        c.simdScale = simd_make_float3(1, k, 1);
        c.simdPosition = simd_make_float3(0, -k * BOLT_LENGTH / 2.0f, 0);
    }
}

- (void)styleBoltAsTracer:(SCNNode *)bolt material:(SCNMaterial *)material {
    if (_tracerCore.firstMaterial != material) {
        _tracerCore = [_boltCore[BoltPlayer] copy];
        _tracerCore.firstMaterial = material;
    }
    for (SCNNode *c in bolt.childNodes) if ([c.name isEqualToString:@"core"]) c.geometry = _tracerCore;
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
    float s = 1.3f + frand() * 0.5f;
    n.scale = SCNVector3Make(s, s, s);
    n.eulerAngles = SCNVector3Make(0, 0, frand() * M_PI * 2);
    n.opacity = 1;
    n.hidden = NO;
    [parent addChildNode:n];
    [n runAction:[SCNAction sequence:@[[SCNAction fadeOutWithDuration:0.06], [SCNAction hide]]]];
}

#pragma mark - Hot spheres

// Small impacts use shader-driven spheres. Moving noise boils the surface;
// the fragment modifier maps "heat" through white -> yellow -> orange
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

// The Houdini flipbook already contains fire, self-shadowed smoke and their
// transition. Preserve its authored alpha: black cavities are opaque soot.
static PlatformImage *ExplosionTexture(void) {
    static PlatformImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = FSURL(@"Particles", @"explosion", @"png");
        CGImageSourceRef source = url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL) : NULL;
        CGImageRef atlas = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
        if (source) CFRelease(source);
        if (!atlas) return;
        size_t w = CGImageGetWidth(atlas), h = CGImageGetHeight(atlas);
        NSMutableData *data = [NSMutableData dataWithLength:w * h * 4];
        uint8_t *px = data.mutableBytes;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), atlas);
        CGContextRelease(ctx);
        CGImageRelease(atlas);
        // SceneKit alpha particles expect straight RGB, including soft edges.
        for (size_t p = 0; p < w * h; p++) {
            uint8_t *rgba = px + p * 4;
            if (!rgba[3]) continue;
            for (int c = 0; c < 3; c++) rgba[c] = (uint8_t)MIN(255, (rgba[c] * 255 + rgba[3] / 2) / rgba[3]);
        }
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageRef result = CGImageCreate(w, h, 8, 32, w * 4, cs, (CGBitmapInfo)kCGImageAlphaLast,
                                          provider, NULL, false, kCGRenderingIntentDefault);
        image = PlatformImageFromCGImage(result);
        CGImageRelease(result);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(cs);
    });
    return image ?: [Exhaust straightAlphaParticleTexture:@"smoke_07"];
}

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
    ps.sortingMode = blend == SCNParticleBlendModeAlpha ? SCNParticleSortingModeProjectedDepth : SCNParticleSortingModeNone;
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
        Scaled(@[@3, @7], s), @[@0, @1]);
    flash.birthRate = 2000; flash.emissionDuration = 0.001;
    flash.particleLifeSpan = 0.12;
    flash.particleIntensity = 0.5;
    flash.emitterShape = nil;

    // Expansion is baked into the simulation. Keep the quad's size stable
    // so the smoke does not inflate again after the pressure front has passed.
    SCNParticleSystem *billow = [SCNParticleSystem particleSystem];
    billow.blendMode = SCNParticleBlendModeAlpha;
    billow.lightingEnabled = NO;
    billow.sortingMode = SCNParticleSortingModeProjectedDepth;
    billow.loops = NO;
    billow.particleImage = ExplosionTexture();
    billow.particleColor = RGBA(1, 1, 1, 1);
    billow.particleSize = 16 * s;
    billow.local = YES;
    billow.birthRate = 1; billow.emissionDuration = 0;
    billow.particleLifeSpan = 25.0 / 15.0;
    billow.particleAngleVariation = 50;
    billow.particleIntensity = 1;
    billow.imageSequenceColumnCount = billow.imageSequenceRowCount = 5;
    billow.imageSequenceAnimationMode = SCNParticleImageSequenceAnimationModeClamp;
    // Color and coverage come only from the source frames, with no tint,
    // intensity boost or additional opacity envelope over the animation.
    billow.imageSequenceFrameRate = 15;
    NSMutableDictionary *systems = [@{ @"flash" : flash, @"billow" : billow } mutableCopy];

    SCNParticleSystem *trailFire = SpriteSystem(@"fire_01", SCNParticleBlendModeAdditive,
        @[RGBA(1, 0.88, 0.6, 0.7), RGBA(1, 0.5, 0.12, 0.4), RGBA(0.4, 0.08, 0.01, 0)], @[@0, @0.3, @1],
        Scaled(@[@0.9, @0.55, @0.15], s), @[@0, @0.4, @1]);
    trailFire.birthRate = 60;
    trailFire.local = NO;
    trailFire.particleLifeSpan = 0.12; trailFire.particleLifeSpanVariation = 0.04;
    trailFire.particleAngularVelocityVariation = 120;
    trailFire.particleIntensity = 0.9;
    trailFire.emitterShape = nil;
    // Keep emitting until the fragment stops burning; pockets above are bursts.
    trailFire.loops = YES;
    systems[@"trailFire"] = trailFire;

    // The same soot as the billow's frames: a warm flicker at birth, then dark grey.
    SCNParticleSystem *trailSmoke = SpriteSystem(@"smoke_07", SCNParticleBlendModeAlpha,
        @[RGBA(0.45, 0.25, 0.12, 0), RGBA(0.2, 0.16, 0.14, 0.65), RGBA(0.13, 0.13, 0.13, 0.5), RGBA(0.11, 0.11, 0.12, 0)],
        @[@0, @0.05, @0.22, @1],
        Scaled(@[@0.3, @0.8, @1.8], s), @[@0, @0.25, @1]);
    trailSmoke.birthRate = 55;
    trailSmoke.local = NO;
    trailSmoke.loops = YES;
    trailSmoke.particleLifeSpan = 1.7; trailSmoke.particleLifeSpanVariation = 0.3;
    trailSmoke.particleVelocity = 0.7 * s;
    trailSmoke.particleAngularVelocityVariation = 25;
    trailSmoke.emitterShape = [SCNSphere sphereWithRadius:0.1 * s];
    systems[@"trailSmoke"] = trailSmoke;

    SCNParticleSystem *embers = SpriteSystem(@"flare_01", SCNParticleBlendModeAdditive,
        @[RGBA(1, 0.92, 0.7, 1), RGBA(1, 0.38, 0.06, 0.85), RGBA(0.5, 0.08, 0.01, 0)], @[@0, @0.2, @1],
        Scaled(@[@0.24, @0.12, @0.02], s), @[@0, @0.25, @1]);
    embers.birthRate = 1800; embers.emissionDuration = 0.045;
    embers.particleLifeSpan = 1.15; embers.particleLifeSpanVariation = 0.65;
    embers.particleVelocity = 35 * s; embers.particleVelocityVariation = 25 * s;
    embers.dampingFactor = 0.65;
    embers.stretchFactor = 0.025;
    embers.particleIntensity = 2;
    systems[@"embers"] = embers;
    _explosionSystems[key] = systems;
    return systems;
}

// Burning fragments per explosion: the streaks radiating from it.
static int FragmentCount(float scale) { return 8 + (int)lroundf(3 * fminf(scale, 3)); }

#define EXPLOSION_KITS 8    // explosions within five seconds before one has its particles taken

// The next kit for this scale, least recently used; made on first use.
- (ExplosionKit *)explosionKitForScale:(float)s {
    NSNumber *key = @(roundf(s * 100) / 100);
    NSMutableArray<ExplosionKit *> *kits = _explosionKits[key];
    if (!kits) {
        NSDictionary *systems = [self explosionSystemsForScale:s];
        _explosionKits[key] = kits = [NSMutableArray arrayWithCapacity:EXPLOSION_KITS];
        for (int i = 0; i < EXPLOSION_KITS; i++)
            [kits addObject:[[ExplosionKit alloc] initWithSystems:systems fragments:(NSUInteger)FragmentCount(s)]];
    }
    ExplosionKit *kit = kits.firstObject;
    [kits removeObjectAtIndex:0];
    [kits addObject:kit];
    return kit;
}

- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull {
    [self explosionAt:p velocity:v hullMaterial:hull scale:1];
}

- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull scale:(float)scale {
    NSDictionary<NSString *, SCNParticleSystem *> *systems = [self explosionSystemsForScale:scale];
    ExplosionKit *kit = [self explosionKitForScale:scale];
    SCNNode *root = [SCNNode node];
    root.simdPosition = p;
    [_scene.rootNode addChildNode:root];
    // The cloud keeps the ship's momentum, with a slower dispersal afterwards.
    [root runAction:[SCNAction moveBy:V3(v * 0.35f * 5.0f) duration:5.0]];

    SCNNode *flash = [SCNNode node];
    flash.renderingOrder = 90;
    [root addChildNode:flash];
    [kit.flash takeOn:flash];
    [kit.embers takeOn:root];

    // One primary detonation followed by three smaller fast-moving lobes:
    // a short double beat gives the burst weight without hiding the fireball.
    for (int i = 0; i < 4; i++) {
        SCNNode *pocket = [SCNNode node];
        simd_float3 direction = randomUnit();
        simd_float3 travel = direction * (i ? 5 + frand() * 5 : 1.5f) * scale;
        [root addChildNode:pocket];
        float size = i ? 0.55f + frand() * 0.2f : 1;
        pocket.simdScale = simd_make_float3(size);
        SCNParticleSystem *billow = [systems[@"billow"] copy];
        billow.particleLifeSpan *= i ? 0.75 + frand() * 0.15 : 1;
        billow.imageSequenceFrameRate = 25 / billow.particleLifeSpan;
        [pocket runAction:[SCNAction sequence:@[
            [SCNAction waitForDuration:i ? 0.055 + frand() * 0.09 : 0],
            [SCNAction runBlock:^(SCNNode *n) { [n addParticleSystem:billow]; }],
            [SCNAction customActionWithDuration:3.5 actionBlock:^(SCNNode *n, CGFloat elapsed) {
                n.simdPosition = travel * (1 - expf(-4 * (float)elapsed));
            }]
        ]]];
    }

    SCNNode *glint = [self streakWithColor:RGBA(1, 0.8, 0.55, 1) width:40 * scale height:0.5 * scale];
    [root addChildNode:glint];
    [glint runAction:[SCNAction sequence:@[[SCNAction fadeOutWithDuration:0.16], [SCNAction removeFromParentNode]]]];

    int arms = FragmentCount(scale);
    for (int i = 0; i < arms; i++) [self burningFragmentIn:root fire:kit.fires[i] smoke:kit.smokes[i] hull:hull scale:scale];
    int pieces = 5 + (int)arc4random_uniform(4) + (int)(scale > 1 ? 4 : 0);
    for (int i = 0; i < pieces; i++) [self debrisFrom:p velocity:v hull:hull];

    // Light flash on nearby hulls, from the fixed pool.
    SCNNode *flashLight = _flashLights[_flashIndex++ % FLASH_LIGHTS];
    [flashLight removeAllActions];
    flashLight.simdPosition = p;
    [flashLight runAction:[SCNAction customActionWithDuration:0.9 actionBlock:^(SCNNode *node, CGFloat t) {
        node.light.intensity = 60000 * scale * powf(1.0f - (float)(t / 0.9), 2.0f);
    }]];
    [root runAction:[SCNAction sequence:@[[SCNAction waitForDuration:5.0], [SCNAction removeFromParentNode]]]];
}

// A burning fragment that shoots out, slows and bends a little while it emits
// fire and smoke into world space; the thin trail it leaves is one of the
// streaks radiating from the explosion.
- (void)burningFragmentIn:(SCNNode *)root fire:(PooledSystem *)pooledFire smoke:(PooledSystem *)pooledSmoke
                     hull:(SCNMaterial *)hull scale:(float)scale {
    simd_float3 dir = randomUnit();
    simd_float3 velocity = dir * (40 + frand() * 65) * scale;
    // A slight sideways pull so streaks bend a little instead of ruled spokes.
    simd_float3 curl = simd_cross(dir, randomUnit()) * (6 + frand() * 12) * scale;
    const float drag = 1.3f + frand() * 1.4f;
    const double burn = 0.35 + frand() * 0.65;

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
    SCNParticleSystem *smoke = [pooledSmoke takeOn:smokeNode], *fire = [pooledFire takeOn:fireNode];
    float smokeRate = smoke.birthRate, fireRate = fire.birthRate;
    // Should the kit go round again while this fragment still burns, its
    // systems belong to a newer explosion and this one leaves them alone.
    NSUInteger use = pooledFire.uses;

    simd_float3 origin = head.simdPosition;
    [head runAction:[SCNAction sequence:@[
        [SCNAction customActionWithDuration:burn actionBlock:^(SCNNode *node, CGFloat elapsed) {
            float distance = (1 - expf(-drag * (float)elapsed)) / drag;
            node.simdPosition = origin + velocity * distance + curl * (float)(elapsed * elapsed) * 0.5f;
            float t = (float)(elapsed / burn);
            bm.emission.intensity = 4.0f * (1.0f - t);
            if (pooledFire.uses != use) return;
            // The flame dies before the smoke does, so the tips are sooty.
            fire.birthRate = fireRate * (1.0f - t) * (1.0f - t);
            smoke.birthRate = smokeRate * powf(1.0f - t, 1.3f);
        }],
        [SCNAction runBlock:^(SCNNode *node) {
            if (pooledFire.uses == use) {
                fire.birthRate = 0;
                smoke.birthRate = 0;
            }
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
    // The first explosion's kit lends its systems; the billow has none of
    // the controllers that cost a ramp, so a copy of it is free.
    SCNNode *particles = [SCNNode node];
    ExplosionKit *kit = [self explosionKitForScale:1];
    for (PooledSystem *ps in @[kit.flash, kit.embers, kit.fires[0], kit.smokes[0]]) [ps takeOn:particles].birthRate = 0;
    [particles addParticleSystem:[[self explosionSystemsForScale:1][@"billow"] copy]];
    return @[fire, particles, streak, bolt, bolt2, muzzle];
}

@end
