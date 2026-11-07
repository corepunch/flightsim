#import "Render.h"
#import "Shared.h"
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

+ (PlatformImage *)softDotImage {
    // Rendered into a real bitmap: a lazily drawn NSImage ends up as an
    // opaque square in SceneKit's particle renderer.
    static PlatformImage *image;
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
        image = PlatformImageFromCGImage(cg);
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
static PlatformImage *LuminanceAlphaImage(NSURL *url) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    // Sprites are soft shapes a few dozen pixels across on screen: 256 px
    // is plenty, and every atlas built from them is a quarter of the memory.
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    BOOL hasAlpha = [properties[(__bridge id)kCGImagePropertyHasAlpha] boolValue];
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)@{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @256,
    });
    CFRelease(src);
    if (!cg) return nil;
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
            // the glow is brightened. Fade everything to zero inside the circle.
            float u = (x + 0.5f) / w * 2 - 1, v = (y + 0.5f) / h * 2 - 1;
            float m = fminf(fmaxf((1.0f - sqrtf(u * u + v * v)) / 0.3f, 0), 1);
            m = m * m * (3 - 2 * m);
            for (int c = 0; c < 4; c++) p[c] = (uint8_t)lroundf(p[c] * m);
        }
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    PlatformImage *img = PlatformImageFromCGImage(out);
    CGImageRelease(out);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(px);
    return img;
}

// Horizontal lens streak whose alpha is exactly zero on every border, so it
// can be stretched to extreme aspect ratios without showing the quad's edges.
+ (PlatformImage *)streakImage {
    static PlatformImage *image;
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
        image = PlatformImageFromCGImage(cg);
        CGImageRelease(cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        free(px);
    });
    return image;
}

+ (PlatformImage *)boltImage {
    static PlatformImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int w = 32, h = 256;
        uint8_t *px = calloc(w * h * 4, 1);
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                float u = (x + 0.5f) / w * 2 - 1, v = (y + 0.5f) / h * 2 - 1;
                float across = (expf(-u * u * 7.0f) - expf(-7.0f)) / (1 - expf(-7.0f));   // 0 on the long edges
                float along = fminf((1.0f - fabsf(v)) * 5.0f, 1);                        // flat, soft ends
                float core = expf(-u * u * 60.0f) * 0.8f;                               // hot centre line
                float a = fminf(fmaxf(across, 0) * along * (1 + core), 1);
                uint8_t c = (uint8_t)lroundf(a * 255);
                uint8_t *p = px + (y * w + x) * 4;
                p[0] = p[1] = p[2] = p[3] = c;
            }
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        image = PlatformImageFromCGImage(cg);
        CGImageRelease(cg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        free(px);
    });
    return image;
}

+ (PlatformImage *)particleTexture:(NSString *)name {
    static NSMutableDictionary<NSString *, PlatformImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        PlatformImage *img = cache[name];
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@"+"];
        if (!img && parts.count > 1) {
            cache[name] = img = [self atlasOf:parts];
        } else if (!img) {
            NSURL *url = FSURL(@"Particles", name, @"png");
            img = url ? LuminanceAlphaImage(url) : nil;
            cache[name] = img ?: [self softDotImage];
            img = cache[name];
        }
        return img;
    }
}

// The sprites side by side in a square grid, read left to right, top to
// bottom, for a particle system's image sequence.
+ (PlatformImage *)atlasOf:(NSArray<NSString *> *)names {
    size_t columns = (size_t)ceil(sqrt((double)names.count));
    CGImageRef first = PlatformImageCGImage([self particleTexture:names.firstObject]);
    size_t cell = CGImageGetWidth(first), side = cell * columns;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, side * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    for (NSUInteger i = 0; i < names.count; i++) {
        CGRect r = CGRectMake((i % columns) * cell, side - (i / columns + 1) * cell, cell, cell);
        CGContextDrawImage(ctx, r, PlatformImageCGImage([self particleTexture:names[i]]));
    }
    CGImageRef atlas = CGBitmapContextCreateImage(ctx);
    PlatformImage *img = PlatformImageFromCGImage(atlas);
    CGImageRelease(atlas);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return img;
}

+ (PlatformImage *)straightAlphaParticleTexture:(NSString *)name {
    static NSMutableDictionary<NSString *, PlatformImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        PlatformImage *img = cache[name];
        if (img) return img;
        CGImageRef src = PlatformImageCGImage([self particleTexture:name]);
        size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
        NSMutableData *data = [NSMutableData dataWithLength:w * h * 4];
        uint8_t *px = data.mutableBytes;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);
        CGContextRelease(ctx);
        for (size_t i = 0; i < w * h; i++) {
            uint8_t *p = px + i * 4;
            if (p[3] == 0) continue;
            float a = p[3] / 255.0f;
            float rgb[3], lum = 0;
            for (int c = 0; c < 3; c++) { rgb[c] = p[c] / 255.0f / a; lum = fmaxf(lum, rgb[c]); }
            // Several sprites are grey shapes on opaque black: the dark pixels
            // are background, not dark smoke. Fade coverage out with
            // brightness and keep the brightness as shading.
            float k = fminf(fmaxf((lum - 0.02f) / 0.6f, 0), 1);
            a *= k * k * (3 - 2 * k);
            for (int c = 0; c < 3; c++) p[c] = (uint8_t)lroundf(fminf(rgb[c] / 0.8f, 1) * 255);
            p[3] = (uint8_t)lroundf(a * 255);
        }
        // Bitmap contexts cannot hold straight alpha, so build the image from the bytes.
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageRef out = CGImageCreate(w, h, 8, 32, w * 4, cs, (CGBitmapInfo)kCGImageAlphaLast,
                                       provider, NULL, false, kCGRenderingIntentDefault);
        img = PlatformImageFromCGImage(out);
        CGImageRelease(out);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(cs);
        cache[name] = img;
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


// MARK: - Life ramps baked into image sequences

// SceneKit builds a colour ramp for every particle system that has property
// controllers, rebuilds it whenever the velocity, life span, size or frame
// rate changes, and never frees the old one (macOS 26, iOS 26). The exhaust
// follows the throttle through exactly those properties every frame, so its
// colour and size over life are baked into an image sequence instead: one
// frame per step of the life, the sprite tinted and scaled by the ramp, and
// the sequence played once over the particle's life span. Measured on the
// renderer: a particle's sprite is multiplied by its colour in linear light
// and by its alpha linearly, so a white particle showing the tinted frame
// draws exactly what the controllers drew.

// Colour and size over a particle's life as keyframes at times 0..1, the way
// the property controllers took them.
typedef struct {
    NSArray<SKColor *> *colors;
    NSArray<NSNumber *> *colorTimes;
    NSArray<NSNumber *> *sizes;       // factors on the particle size, as the controller applied them
    NSArray<NSNumber *> *sizeTimes;
} LifeRamp;

static float SRGBToLinear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }
static float LinearToSRGB(float c) { return c <= 0.0031308f ? c * 12.92f : 1.055f * powf(c, 1 / 2.4f) - 0.055f; }

static simd_float4 ColorRGBA(SKColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
#if TARGET_OS_IOS
    [color getRed:&r green:&g blue:&b alpha:&a];
#else
    [[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] getRed:&r green:&g blue:&b alpha:&a];
#endif
    return simd_make_float4((float)r, (float)g, (float)b, (float)a);
}

// Piecewise linear interpolation of keyframes, as the controllers did it.
static float KeyframeAt(NSArray<NSNumber *> *values, NSArray<NSNumber *> *times, float t) {
    NSUInteger last = values.count - 1;
    for (NSUInteger i = 1; i <= last; i++) {
        float t0 = times[i - 1].floatValue, t1 = times[i].floatValue;
        if (t <= t1) return values[i - 1].floatValue + (values[i].floatValue - values[i - 1].floatValue) * (t1 > t0 ? (t - t0) / (t1 - t0) : 1);
    }
    return values[last].floatValue;
}

static simd_float4 ColorKeyframeAt(NSArray<SKColor *> *colors, NSArray<NSNumber *> *times, float t) {
    NSUInteger last = colors.count - 1;
    for (NSUInteger i = 1; i <= last; i++) {
        float t0 = times[i - 1].floatValue, t1 = times[i].floatValue;
        if (t <= t1) return simd_mix(ColorRGBA(colors[i - 1]), ColorRGBA(colors[i]), t1 > t0 ? (t - t0) / (t1 - t0) : 1);
    }
    return ColorRGBA(colors[last]);
}

static float LargestSize(LifeRamp ramp) {
    float largest = 0;
    for (NSNumber *size in ramp.sizes) largest = fmaxf(largest, size.floatValue);
    return largest;
}

// The sprite at `frames` steps of the ramp, each tinted by the colour and
// drawn at its size relative to the largest, in a square grid read left to
// right, top to bottom; straight alpha like +straightAlphaParticleTexture:.
// Sizes enter as fractions, so every nozzle radius shares one atlas.
+ (PlatformImage *)rampSequence:(NSString *)sprite ramp:(LifeRamp)ramp frames:(NSUInteger)frames cell:(size_t)cell {
    static NSMutableDictionary<NSString *, PlatformImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    float largest = LargestSize(ramp);
    NSMutableString *key = [NSMutableString stringWithFormat:@"%@|%lu|%zu", sprite, (unsigned long)frames, cell];
    for (NSUInteger i = 0; i < ramp.colors.count; i++) {
        simd_float4 c = ColorRGBA(ramp.colors[i]);
        [key appendFormat:@"|%.3f,%.3f,%.3f,%.3f@%.3f", c.x, c.y, c.z, c.w, ramp.colorTimes[i].floatValue];
    }
    for (NSUInteger i = 0; i < ramp.sizes.count; i++)
        [key appendFormat:@"|%.3f@%.3f", ramp.sizes[i].floatValue / largest, ramp.sizeTimes[i].floatValue];
    @synchronized (cache) {
        PlatformImage *img = cache[key];
        if (img) return img;

        size_t columns = (size_t)ceil(sqrt((double)frames)), rows = (frames + columns - 1) / columns;
        size_t w = columns * cell, h = rows * cell;
        CGImageRef source = PlatformImageCGImage([self particleTexture:sprite]);
        NSMutableData *data = [NSMutableData dataWithLength:w * h * 4];
        uint8_t *px = data.mutableBytes;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        for (NSUInteger f = 0; f < frames; f++) {
            float t = frames > 1 ? (float)f / (frames - 1) : 0;
            float side = cell * KeyframeAt(ramp.sizes, ramp.sizeTimes, t) / largest;
            CGFloat x = (f % columns) * cell + (cell - side) / 2, y = h - (f / columns + 1) * cell + (cell - side) / 2;
            CGContextDrawImage(ctx, CGRectMake(x, y, side, side), source);
        }
        CGContextRelease(ctx);
        // Tint each frame: straight colour into linear light times the ramp
        // colour, alpha times the ramp alpha, stored straight.
        for (NSUInteger f = 0; f < frames; f++) {
            simd_float4 tint = ColorKeyframeAt(ramp.colors, ramp.colorTimes, frames > 1 ? (float)f / (frames - 1) : 0);
            simd_float3 tintLinear = simd_make_float3(SRGBToLinear(tint.x), SRGBToLinear(tint.y), SRGBToLinear(tint.z));
            size_t x0 = (f % columns) * cell, y0 = (f / columns) * cell;
            for (size_t y = y0; y < y0 + cell; y++) {
                for (size_t x = x0; x < x0 + cell; x++) {
                    uint8_t *p = px + (y * w + x) * 4;
                    float a = p[3] / 255.0f;
                    if (a <= 0) { p[0] = p[1] = p[2] = 0; continue; }
                    for (int c = 0; c < 3; c++) {
                        float straight = fminf(p[c] / 255.0f / a, 1);
                        p[c] = (uint8_t)lroundf(LinearToSRGB(SRGBToLinear(straight) * tintLinear[c]) * 255);
                    }
                    p[3] = (uint8_t)lroundf(a * tint.w * 255);
                }
            }
        }
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageRef out = CGImageCreate(w, h, 8, 32, w * 4, cs, (CGBitmapInfo)kCGImageAlphaLast,
                                       provider, NULL, false, kCGRenderingIntentDefault);
        img = PlatformImageFromCGImage(out);
        CGImageRelease(out);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(cs);
        cache[key] = img;
        return img;
    }
}

// The life span and the frame rate that plays the whole sequence over it, as
// one setting: the last frame is reached just before the particle dies.
static void ParticleSetLife(SCNParticleSystem *ps, CGFloat life, NSUInteger frames) {
    ParticleSet(ps, @"particleLifeSpan", life);
    ParticleSet(ps, @"imageSequenceFrameRate", frames / life);
}

// Gives the system the baked sequence in place of colour and size controllers:
// white particles stepping through the frames once over the life span. A
// size controller multiplied the particle's size and its variation (measured:
// a size of 2 under a controller at 3 drew 6), so both take the ramp's
// largest factor and the frames carry the rest. Any later change of life
// span goes through ParticleSetLife with the same frame count.
static void UseLifeRamp(SCNParticleSystem *ps, NSString *sprite, LifeRamp ramp, NSUInteger frames, size_t cell) {
    float largest = LargestSize(ramp);
    ps.particleImage = [Exhaust rampSequence:sprite ramp:ramp frames:frames cell:cell];
    ps.imageSequenceColumnCount = (NSUInteger)ceil(sqrt((double)frames));
    ps.imageSequenceRowCount = (frames + ps.imageSequenceColumnCount - 1) / ps.imageSequenceColumnCount;
    ps.imageSequenceAnimationMode = SCNParticleImageSequenceAnimationModeClamp;
    ps.particleSize *= largest;
    ps.particleSizeVariation *= largest;
    ps.propertyControllers = nil;
    ParticleSetLife(ps, ps.particleLifeSpan, frames);
}

static const NSUInteger kPlasmaFrames = 16;   // a 4 x 4 sequence over 0.08-0.2 s: 80 frames a second and up
static const NSUInteger kSmokeFrames = 25;    // a 5 x 5 sequence over 1.1 s: the puff grows in steps below 6%

- (SCNParticleSystem *)plasmaWithColor:(simd_float3)color radius:(float)r {
    SCNParticleSystem *ps = [SCNParticleSystem particleSystem];
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
    SKColor *hot = [SKColor colorWithRed:0.9 green:0.95 blue:1.0 alpha:0.55];
    SKColor *mid = [SKColor colorWithRed:color.x green:color.y blue:color.z alpha:0.45];
    SKColor *end = [SKColor colorWithRed:color.x * 0.6 green:color.y * 0.3 blue:color.z * 0.8 alpha:0.0];
    LifeRamp ramp = { .colors = @[hot, mid, end], .colorTimes = @[@0, @0.35, @1],
                      .sizes = @[@(r * 0.9), @(r * 1.6), @(r * 2.2)], .sizeTimes = @[@0, @0.5, @1] };
    UseLifeRamp(ps, @"fire_01", ramp, kPlasmaFrames, 64);
    ps.sortingMode = SCNParticleSortingModeNone;
    return ps;
}

- (SCNParticleSystem *)smokeWithRadius:(float)r {
    SCNParticleSystem *ps = [SCNParticleSystem particleSystem];
    ps.blendMode = SCNParticleBlendModeAlpha;
    ps.local = NO;                     // left behind in space as a trail
    ps.birthRate = 0;
    ps.particleLifeSpan = 1.1;
    ps.particleLifeSpanVariation = 0.4;
    ps.emittingDirection = SCNVector3Make(0, 1, 0);
    // Many small, faint puffs rather than a few big ones: they overlap into
    // a continuous stream instead of reading as separate clumps.
    ps.spreadingAngle = 7;
    ps.particleVelocity = 6;
    ps.particleVelocityVariation = 2;
    ps.particleSize = r * 0.45;
    ps.particleSizeVariation = r * 0.15;
    ps.emitterShape = [SCNSphere sphereWithRadius:r * 0.25];
    ps.birthLocation = SCNParticleBirthLocationVolume;
    ps.particleAngularVelocity = 20;
    ps.particleAngularVelocityVariation = 40;
    ps.particleAngleVariation = 180;
    SKColor *a = [SKColor colorWithRed:0.50 green:0.54 blue:0.62 alpha:0.0];
    SKColor *b = [SKColor colorWithRed:0.42 green:0.45 blue:0.52 alpha:0.06];
    SKColor *c = [SKColor colorWithRed:0.30 green:0.32 blue:0.38 alpha:0.0];
    LifeRamp ramp = { .colors = @[a, b, c], .colorTimes = @[@0, @0.1, @1],
                      .sizes = @[@(r * 0.35), @(r * 0.9), @(r * 1.7)], .sizeTimes = @[@0, @0.4, @1] };
    UseLifeRamp(ps, @"smoke_07", ramp, kSmokeFrames, 96);
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
        ParticleSet(p, @"birthRate", 12 + 160 * L);
        ParticleSet(p, @"particleVelocity", r * (4 + 55 * L));
        ParticleSetLife(p, round((0.08 + 0.12 * fminf(L, 1.2f)) / 0.02) * 0.02, kPlasmaFrames);
    }
    for (NSUInteger i = 0; i < _smoke.count; i++) {
        float r = _radii[i].floatValue;
        SCNParticleSystem *s = _smoke[i];
        ParticleSet(s, @"birthRate", L > 0.05f ? 30 + 270 * L : 0);
        ParticleSet(s, @"particleVelocity", r * (2 + 20 * L));
    }
}

@end
