#import "Effects.h"
#import "Exhaust.h"

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

static NSColor *RGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) { return [NSColor colorWithRed:r green:g blue:b alpha:a]; }

@implementation Effects {
    SCNScene *_scene;
    SCNMaterial *_playerCore, *_playerGlow, *_enemyCore, *_enemyGlow;
    SCNGeometry *_coreGeo, *_glowGeo;
    SCNMaterial *_ringMaterial;
    NSMutableDictionary<NSString *, SCNMaterial *> *_streakMaterials;
    SCNNode *_muzzles[MUZZLE_POOL];
    NSUInteger _muzzleIndex;
    SCNMaterial *_muzzlePlayer, *_muzzleEnemy;
    SCNMaterial *_fireTemplate;
    SCNNode *_flashLights[FLASH_LIGHTS];
    NSUInteger _flashIndex;
}

// Thin bright annulus with a soft inner glow and an empty centre; sprite-pack
// rings are filled discs that grey out the screen once scaled up.
+ (NSImage *)shockRingImage {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int n = 512;
        uint8_t *px = calloc(n * n * 4, 1);
        for (int y = 0; y < n; y++) {
            for (int x = 0; x < n; x++) {
                float dx = (x + 0.5f) / n * 2 - 1, dy = (y + 0.5f) / n * 2 - 1;
                float r = sqrtf(dx * dx + dy * dy);
                float edge = expf(-powf((r - 0.93f) / 0.025f, 2));            // crisp front
                float wake = r < 0.93f ? expf(-(0.93f - r) / 0.05f) * 0.25f : 0; // trailing glow
                float a = fminf(edge + wake, 1) * (r < 1 ? 1 : 0);
                uint8_t v = (uint8_t)lroundf(a * 255);
                uint8_t *p = px + (y * n + x) * 4;
                p[0] = p[1] = p[2] = p[3] = v;
            }
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, n, n, 8, n * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        image = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(n, n)];
        CGImageRelease(cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        free(px);
    });
    return image;
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
        SCNCapsule *core = [SCNCapsule capsuleWithCapRadius:0.11 height:9];
        core.radialSegmentCount = 8;
        SCNCapsule *glow = [SCNCapsule capsuleWithCapRadius:0.5 height:11];
        glow.radialSegmentCount = 12;
        _coreGeo = core;
        _glowGeo = glow;
        _ringMaterial = [Effects additiveTextureMaterial:@"circle_05" tint:simd_make_float3(1.6f, 1.25f, 1.0f)];
        _ringMaterial.diffuse.contents = [Effects shockRingImage];
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

- (void)styleBolt:(SCNNode *)bolt player:(BOOL)player {
    for (SCNNode *c in bolt.childNodes) {
        BOOL core = [c.name isEqualToString:@"core"];
        c.geometry.firstMaterial = core ? (player ? _playerCore : _enemyCore) : (player ? _playerGlow : _enemyGlow);
    }
}

- (SCNNode *)streakWithColor:(NSColor *)color width:(float)width height:(float)height {
    SCNPlane *plane = [SCNPlane planeWithWidth:1 height:1];
    CGFloat r, g, b, a;
    [[color colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]] getRed:&r green:&g blue:&b alpha:&a];
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

- (void)explosionAt:(simd_float3)p velocity:(simd_float3)v hullMaterial:(SCNMaterial *)hull {
    SCNNode *root = [SCNNode node];
    root.simdPosition = p;
    [_scene.rootNode addChildNode:root];
    // The cloud keeps a little of the ship's momentum.
    [root runAction:[SCNAction moveBy:V3(v * 0.35f * 2.5f) duration:2.5]];

    // White-hot core, a slower outer fireball, and one late secondary blast.
    [self fireSphereAt:root offset:0 radius:9.0f duration:0.7 delay:0 heat:1.0f turbulence:0.10f];
    [self fireSphereAt:root offset:randomUnit() * 1.5f radius:14.0f duration:1.4 delay:0.05 heat:0.75f turbulence:0.22f];
    [self fireSphereAt:root offset:randomUnit() * 6.0f radius:6.0f duration:0.8 delay:0.3 + frand() * 0.2 heat:0.9f turbulence:0.18f];

    // Anamorphic glint.
    SCNNode *glint = [self streakWithColor:RGBA(1, 0.75, 0.5, 1) width:160 height:2.2];
    [root addChildNode:glint];
    [glint runAction:[SCNAction sequence:@[[SCNAction fadeOutWithDuration:0.6], [SCNAction removeFromParentNode]]]];

    // Planar shockwave ring (the "Praxis" ring), tilted at random.
    SCNPlane *ringPlane = [SCNPlane planeWithWidth:1 height:1];
    ringPlane.firstMaterial = _ringMaterial;
    SCNNode *ring = [SCNNode nodeWithGeometry:ringPlane];
    ring.castsShadow = NO;
    ring.renderingOrder = 75;
    ring.simdOrientation = simd_quaternion(simd_make_float3(0, 0, 1), randomUnit());
    ring.scale = SCNVector3Make(4, 4, 4);
    [root addChildNode:ring];
    SCNAction *grow = [SCNAction scaleTo:70 duration:1.0];
    grow.timingMode = SCNActionTimingModeEaseOut;
    [ring runAction:[SCNAction group:@[grow, [SCNAction sequence:@[[SCNAction waitForDuration:0.1], [SCNAction fadeOutWithDuration:0.9]]]]]
         completionHandler:^{ [ring removeFromParentNode]; }];

    // A few glowing hull chunks that cool as they tumble away.
    int pieces = 4 + (int)arc4random_uniform(3);
    for (int i = 0; i < pieces; i++) [self debrisFrom:p velocity:v hull:hull];

    // Light flash on nearby hulls, from the fixed pool.
    SCNNode *flash = _flashLights[_flashIndex++ % FLASH_LIGHTS];
    [flash removeAllActions];
    flash.simdPosition = p;
    [flash runAction:[SCNAction customActionWithDuration:0.9 actionBlock:^(SCNNode *node, CGFloat t) {
        node.light.intensity = 60000 * powf(1.0f - (float)(t / 0.9), 2.0f);
    }]];
    [root runAction:[SCNAction sequence:@[[SCNAction waitForDuration:2.5], [SCNAction removeFromParentNode]]]];
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
    SCNNode *ring = [SCNNode nodeWithGeometry:[SCNPlane planeWithWidth:1 height:1]];
    ring.geometry.firstMaterial = _ringMaterial;
    SCNNode *streak = [self streakWithColor:RGBA(1, 0.75, 0.5, 1) width:1 height:1];
    SCNNode *bolt = [self makeBoltNode];
    [self styleBolt:bolt player:YES];
    SCNNode *bolt2 = [self makeBoltNode];
    [self styleBolt:bolt2 player:NO];
    SCNNode *muzzle = [SCNNode nodeWithGeometry:[SCNPlane planeWithWidth:1 height:1]];
    muzzle.geometry.firstMaterial = _muzzlePlayer;
    return @[fire, ring, streak, bolt, bolt2, muzzle];
}

@end
