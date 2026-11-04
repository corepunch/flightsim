#import "Exhaust.h"
#import <ImageIO/ImageIO.h>

static NSString *const kFlameGeometry =
    @"#pragma varyings\n"
     "float along;\n"
     "#pragma body\n"
     "out.along = _geometry.position.y + 0.5;\n";

// Additive flame: hot white core facing the camera, tinted toward the edges,
// fading along its length, with travelling bands and flicker.
static NSString *const kFlameFragment =
    @"#pragma arguments\n"
     "float level;\n"
     "float seed;\n"
     "float3 tint;\n"
     "#pragma body\n"
     "float a = saturate(in.along);\n"
     "float facing = abs(dot(normalize(_surface.normal), normalize(_surface.view)));\n"
     "float t = scn_frame.time;\n"
     "float flicker = 0.8 + 0.2 * sin(t * 53.0 + seed * 11.0) * sin(t * 31.0 + seed * 3.0);\n"
     "float bands = 0.75 + 0.25 * sin(a * 28.0 - t * 45.0 + seed);\n"
     "float diamonds = 1.0 + 0.9 * pow(max(cos(a * 34.0), 0.0), 8.0) * (1.0 - a) * saturate(level - 0.3);\n"
     "float fall = pow(1.0 - a, 1.4);\n"
     "float core = pow(facing, 4.0) * pow(1.0 - a, 3.0);\n"
     "float3 c = mix(tint, float3(1.0, 1.0, 1.0), saturate(core * 1.5));\n"
     "float intensity = (0.2 + level * 1.4) * fall * pow(facing, 1.6) * flicker * bands * diamonds;\n"
     "_output.color = float4(c * intensity, 1.0);\n";

@implementation Exhaust {
    NSMutableArray<SCNNode *> *_flames;      // scaled with throttle
    NSMutableArray<SCNNode *> *_cores;
    NSMutableArray<SCNParticleSystem *> *_plasma;
    NSMutableArray<SCNParticleSystem *> *_smoke;
    NSMutableArray<NSNumber *> *_radii;
    SCNMaterial *_flameMaterial;
    SCNMaterial *_coreMaterial;
    float _level;
    BOOL _enabled;
}

+ (NSImage *)softDotImage {
    // Rendered into a real bitmap: a lazily drawn NSImage ends up as an
    // opaque square in SceneKit's particle renderer.
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int n = 64;
        uint8_t *px = calloc(n * n * 4, 1);
        for (int y = 0; y < n; y++) {
            for (int x = 0; x < n; x++) {
                float dx = (x + 0.5f) / n * 2 - 1, dy = (y + 0.5f) / n * 2 - 1;
                float r2 = dx * dx + dy * dy;
                float a = r2 >= 1 ? 0 : expf(-r2 * 4.0f) * (1 - r2);
                uint8_t v = (uint8_t)lroundf(fminf(a, 1) * 255);
                uint8_t *p = px + (y * n + x) * 4;
                p[0] = p[1] = p[2] = v;  // premultiplied white
                p[3] = v;
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

// Several Kenney sprites are RGB on black. Give every texture premultiplied
// alpha (= brightness when the file has none) so they blend cleanly in both
// SceneKit particles and the SpriteKit overlay.
static NSImage *LuminanceAlphaImage(NSURL *url) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) return nil;
    CGImageAlphaInfo info = CGImageGetAlphaInfo(cg);
    BOOL hasAlpha = info != kCGImageAlphaNone && info != kCGImageAlphaNoneSkipLast && info != kCGImageAlphaNoneSkipFirst;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    uint8_t *px = calloc(w * h * 4, 1);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGImageRelease(cg);
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            uint8_t *p = px + (y * w + x) * 4;
            if (!hasAlpha) p[3] = MAX(p[0], MAX(p[1], p[2]));   // rgb already equals premultiplied colour
            // Soft circular vignette: several sprites have content running
            // into the quad's edge, which shows as straight cut lines once
            // bloom brightens it. Fade everything to zero inside the circle.
            float u = (x + 0.5f) / w * 2 - 1, v = (y + 0.5f) / h * 2 - 1;
            float m = fminf(fmaxf((1.0f - sqrtf(u * u + v * v)) / 0.3f, 0), 1);
            m = m * m * (3 - 2 * m);
            for (int c = 0; c < 4; c++) p[c] = (uint8_t)lroundf(p[c] * m);
        }
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    NSImage *img = [[NSImage alloc] initWithCGImage:out size:NSMakeSize(w, h)];
    CGImageRelease(out);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(px);
    return img;
}

// Horizontal lens streak whose alpha is exactly zero on every border, so it
// can be stretched to extreme aspect ratios without showing the quad's edges.
+ (NSImage *)streakImage {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int w = 512, h = 64;
        uint8_t *px = calloc(w * h * 4, 1);
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                float u = (x + 0.5f) / w * 2 - 1, v = (y + 0.5f) / h * 2 - 1;
                float across = expf(-v * v * 18.0f) - expf(-18.0f);      // 0 at top/bottom
                float along = powf(fmaxf(1.0f - fabsf(u), 0), 2.2f);     // 0 at the ends
                float core = expf(-u * u * 40.0f) * 0.6f;                // hot centre
                float a = fminf(fmaxf(across, 0) / (1 - expf(-18.0f)) * (along + core * along), 1);
                uint8_t c = (uint8_t)lroundf(a * 255);
                uint8_t *p = px + (y * w + x) * 4;
                p[0] = p[1] = p[2] = p[3] = c;
            }
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        image = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(w, h)];
        CGImageRelease(cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        free(px);
    });
    return image;
}

+ (NSImage *)particleTexture:(NSString *)name {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSImage *img = cache[name];
        if (!img) {
            NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"png" subdirectory:@"Particles"];
            img = url ? LuminanceAlphaImage(url) : nil;
            cache[name] = img ?: [self softDotImage];
            img = cache[name];
        }
        return img;
    }
}

static SCNMaterial *FlameMaterial(simd_float3 tint, float seed) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;
    m.blendMode = SCNBlendModeAdd;
    m.writesToDepthBuffer = NO;
    m.shaderModifiers = @{ SCNShaderModifierEntryPointGeometry : kFlameGeometry,
                           SCNShaderModifierEntryPointFragment : kFlameFragment };
    [m setValue:[NSValue valueWithSCNVector3:SCNVector3Make(tint.x, tint.y, tint.z)] forKey:@"tint"];
    [m setValue:@(seed) forKey:@"seed"];
    [m setValue:@(0.0) forKey:@"level"];
    return m;
}

static CAKeyframeAnimation *OverLife(NSString *keyPath, NSArray *values, NSArray<NSNumber *> *times) {
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    a.values = values;
    a.keyTimes = times;
    return a;
}

- (SCNParticleSystem *)plasmaWithColor:(simd_float3)color radius:(float)r {
    SCNParticleSystem *ps = [SCNParticleSystem particleSystem];
    ps.particleImage = [Exhaust particleTexture:@"fire_01"];
    ps.blendMode = SCNParticleBlendModeAdditive;
    ps.local = YES;
    ps.particleAngleVariation = 180;
    ps.particleAngularVelocityVariation = 400;
    ps.birthRate = 0;
    ps.particleLifeSpan = 0.22;
    ps.particleLifeSpanVariation = 0.08;
    ps.emittingDirection = SCNVector3Make(0, 1, 0);
    ps.spreadingAngle = 6;
    ps.particleVelocity = 10;
    ps.particleVelocityVariation = 4;
    ps.particleSize = r * 1.1;
    ps.particleSizeVariation = r * 0.3;
    ps.emitterShape = [SCNSphere sphereWithRadius:r * 0.45];
    ps.birthLocation = SCNParticleBirthLocationVolume;
    NSColor *hot = [NSColor colorWithRed:0.9 green:0.95 blue:1.0 alpha:0.55];
    NSColor *mid = [NSColor colorWithRed:color.x green:color.y blue:color.z alpha:0.45];
    NSColor *end = [NSColor colorWithRed:color.x * 0.6 green:color.y * 0.3 blue:color.z * 0.8 alpha:0.0];
    SCNParticlePropertyController *cc = [SCNParticlePropertyController controllerWithAnimation:
                                         OverLife(@"color", @[hot, mid, end], @[@0, @0.35, @1])];
    SCNParticlePropertyController *sc = [SCNParticlePropertyController controllerWithAnimation:
                                         OverLife(@"size", @[@(r * 0.9), @(r * 1.6), @(r * 2.2)], @[@0, @0.5, @1])];
    ps.propertyControllers = @{ SCNParticlePropertyColor : cc, SCNParticlePropertySize : sc };
    ps.sortingMode = SCNParticleSortingModeNone;
    return ps;
}

- (SCNParticleSystem *)smokeWithRadius:(float)r {
    SCNParticleSystem *ps = [SCNParticleSystem particleSystem];
    ps.particleImage = [Exhaust particleTexture:@"smoke_07"];
    ps.blendMode = SCNParticleBlendModeAlpha;
    ps.local = NO;                     // left behind in space as a trail
    ps.birthRate = 0;
    ps.particleLifeSpan = 1.1;
    ps.particleLifeSpanVariation = 0.4;
    ps.emittingDirection = SCNVector3Make(0, 1, 0);
    ps.spreadingAngle = 14;
    ps.particleVelocity = 6;
    ps.particleVelocityVariation = 3;
    ps.particleSize = r * 1.2;
    ps.emitterShape = [SCNSphere sphereWithRadius:r * 0.4];
    ps.birthLocation = SCNParticleBirthLocationVolume;
    ps.particleAngularVelocity = 30;
    ps.particleAngularVelocityVariation = 60;
    ps.particleAngleVariation = 180;
    NSColor *a = [NSColor colorWithRed:0.50 green:0.54 blue:0.62 alpha:0.0];
    NSColor *b = [NSColor colorWithRed:0.42 green:0.45 blue:0.52 alpha:0.16];
    NSColor *c = [NSColor colorWithRed:0.30 green:0.32 blue:0.38 alpha:0.0];
    SCNParticlePropertyController *cc = [SCNParticlePropertyController controllerWithAnimation:
                                         OverLife(@"color", @[a, b, c], @[@0, @0.15, @1])];
    SCNParticlePropertyController *sc = [SCNParticlePropertyController controllerWithAnimation:
                                         OverLife(@"size", @[@(r * 0.8), @(r * 2.4), @(r * 3.6)], @[@0, @0.4, @1])];
    ps.propertyControllers = @{ SCNParticlePropertyColor : cc, SCNParticlePropertySize : sc };
    ps.sortingMode = SCNParticleSortingModeNone;
    ps.lightingEnabled = NO;
    return ps;
}

- (instancetype)initWithNozzles:(const simd_float4 *)nozzles count:(NSUInteger)count
                          color:(simd_float3)color parent:(SCNNode *)parent smoke:(BOOL)smoke {
    if ((self = [super init])) {
        _flames = [NSMutableArray array];
        _cores = [NSMutableArray array];
        _plasma = [NSMutableArray array];
        _smoke = [NSMutableArray array];
        _radii = [NSMutableArray array];
        _enabled = YES;
        _flameMaterial = FlameMaterial(color, (float)arc4random_uniform(100));
        _coreMaterial = FlameMaterial(simd_make_float3(0.8f, 0.9f, 1.0f), (float)arc4random_uniform(100));

        SCNCone *cone = [SCNCone coneWithTopRadius:0 bottomRadius:1 height:1];
        cone.radialSegmentCount = 18;
        cone.heightSegmentCount = 1;
        cone.materials = @[_flameMaterial];
        SCNCone *coreCone = [cone copy];
        coreCone.materials = @[_coreMaterial];

        for (NSUInteger i = 0; i < count; i++) {
            simd_float4 n = nozzles[i];
            // Nozzle frame: local +Y points out the back of the ship (+Z).
            SCNNode *nozzle = [SCNNode node];
            nozzle.simdPosition = n.xyz;
            nozzle.eulerAngles = SCNVector3Make(M_PI_2, 0, 0);
            [parent addChildNode:nozzle];

            SCNNode *flame = [SCNNode node];
            SCNNode *coneNode = [SCNNode nodeWithGeometry:cone];
            coneNode.position = SCNVector3Make(0, 0.5, 0);
            coneNode.castsShadow = NO;
            coneNode.renderingOrder = 60;
            [flame addChildNode:coneNode];
            [nozzle addChildNode:flame];
            [_flames addObject:flame];

            SCNNode *core = [SCNNode node];
            SCNNode *coreNode = [SCNNode nodeWithGeometry:coreCone];
            coreNode.position = SCNVector3Make(0, 0.5, 0);
            coreNode.castsShadow = NO;
            coreNode.renderingOrder = 61;
            [core addChildNode:coreNode];
            [nozzle addChildNode:core];
            [_cores addObject:core];

            SCNParticleSystem *plasma = [self plasmaWithColor:color radius:n.w];
            [nozzle addParticleSystem:plasma];
            [_plasma addObject:plasma];
            if (smoke) {
                SCNParticleSystem *s = [self smokeWithRadius:n.w];
                [nozzle addParticleSystem:s];
                [_smoke addObject:s];
            }
            [_radii addObject:@(n.w)];
        }
    }
    return self;
}

- (float)level { return _level; }

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    for (SCNNode *f in _flames) f.hidden = !enabled;
    for (SCNNode *f in _cores) f.hidden = !enabled;
    if (!enabled) {
        for (SCNParticleSystem *p in _plasma) p.birthRate = 0;
        for (SCNParticleSystem *p in _smoke) p.birthRate = 0;
    }
}

- (void)updateThrottle:(float)throttle boost:(BOOL)boost dt:(float)dt {
    if (!_enabled) return;
    float target = throttle * (boost ? 1.6f : 1.0f);
    // Engines spool up quickly and down a little slower.
    float rate = target > _level ? 7.0f : 3.5f;
    _level += (target - _level) * (1.0f - expf(-rate * dt));
    float L = _level;

    [_flameMaterial setValue:@(L) forKey:@"level"];
    [_coreMaterial setValue:@(L * 1.1f) forKey:@"level"];

    for (NSUInteger i = 0; i < _flames.count; i++) {
        float r = _radii[i].floatValue;
        float jitter = 1.0f + 0.06f * ((float)arc4random_uniform(1000) / 1000.0f - 0.5f);
        float len = r * (0.8f + 11.0f * L) * jitter;
        float width = r * (0.75f + 0.25f * fminf(L, 1.0f));
        _flames[i].scale = SCNVector3Make(width, len, width);
        _cores[i].scale = SCNVector3Make(width * 0.45f, len * 0.45f, width * 0.45f);

        SCNParticleSystem *p = _plasma[i];
        p.birthRate = 12 + 160 * L;
        p.particleVelocity = r * (4 + 55 * L);
        p.particleLifeSpan = 0.08 + 0.12 * fminf(L, 1.2f);
    }
    for (NSUInteger i = 0; i < _smoke.count; i++) {
        float r = _radii[i].floatValue;
        SCNParticleSystem *s = _smoke[i];
        s.birthRate = L > 0.05f ? 1 + 16 * L : 0;
        s.particleVelocity = r * (2 + 20 * L);
    }
}

@end
