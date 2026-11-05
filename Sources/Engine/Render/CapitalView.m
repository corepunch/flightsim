#import "PlatformImage.h"
#import "FileSystem.h"
#import "CapitalView.h"
#import "Assets.h"
#import "ShipView.h"

#pragma mark - Materials

static NSURL *TextureURL(NSString *name) {
    return FSURL(@"Textures", name, @"jpg") ?: FSURL(@"Textures", name, @"png");
}

static void Repeat(SCNMaterialProperty *p) {
    p.wrapS = p.wrapT = SCNWrapModeRepeat;
    p.mipFilter = SCNFilterModeLinear;
    p.maxAnisotropy = 8;
}

// Tiling PBR set from Resources/Textures/<set>_{color,normal,rough,metal}.jpg.
static SCNMaterial *TexturedMaterial(NSString *set, SKColor *tint, float normalStrength) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelPhysicallyBased;
    m.diffuse.contents = TextureURL([set stringByAppendingString:@"_color"]);
    m.multiply.contents = tint;
    m.normal.contents = TextureURL([set stringByAppendingString:@"_normal"]);
    m.normal.intensity = normalStrength;
    m.roughness.contents = TextureURL([set stringByAppendingString:@"_rough"]);
    NSURL *metal = TextureURL([set stringByAppendingString:@"_metal"]);
    m.metalness.contents = metal ?: @0.6;
    // The plate sets are fully metallic, which reads as black mirror against
    // space; keep some diffuse so the hulls show their colour.
    m.metalness.intensity = 0.3;
    NSMutableArray *props = [NSMutableArray arrayWithObjects:m.diffuse, m.normal, m.roughness, m.metalness, nil];
    // The generated hull sets (Art/build_hull_textures.py) carry lit windows
    // and running lights, and one tile spans ~40 m instead of the UVs' 24.
    NSURL *emit = TextureURL([set stringByAppendingString:@"_emit"]);
    if (emit) {
        m.emission.contents = emit;
        m.emission.intensity = 1.6;
        [props addObject:m.emission];
        for (SCNMaterialProperty *p in props) p.contentsTransform = SCNMatrix4MakeScale(0.6, 0.6, 1);
    }
    for (SCNMaterialProperty *p in props) Repeat(p);
    ApplyHullRolloff(m);
    return m;
}

static SCNMaterial *PlainMaterial(SKColor *c, float rough, float metal) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelPhysicallyBased;
    m.diffuse.contents = c;
    m.roughness.contents = @(rough);
    m.metalness.contents = @(metal);
    ApplyHullRolloff(m);
    return m;
}

static SCNMaterial *EmissiveMaterial(id contents, float intensity) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;
    m.diffuse.contents = [SKColor blackColor];
    m.emission.contents = contents;
    m.emission.intensity = intensity;
    return m;
}

// Rows of cabin windows, about two thirds lit, in a few warm and cool tones.
static PlatformImage *WindowImage(void) {
    return PlatformDrawImage(CGSizeMake(512, 128), ^(CGContextRef cg, CGRect r) {
        [[SKColor colorWithWhite:0.01 alpha:1] setFill];
        CGContextFillRect(cg, r);
        srand48(77);
        NSArray *tones = @[[SKColor colorWithRed:1 green:0.85 blue:0.55 alpha:1], [SKColor colorWithRed:0.75 green:0.9 blue:1 alpha:1],
                           [SKColor colorWithRed:1 green:0.95 blue:0.85 alpha:1]];
        for (int row = 0; row < 4; row++)
            for (int col = 0; col < 16; col++) {
                if (drand48() < 0.33) continue;
                SKColor *c = tones[(int)(drand48() * tones.count)];
                [[c colorWithAlphaComponent:0.5 + drand48() * 0.5] setFill];
                CGContextFillRect(cg, CGRectMake(col * 32 + 6, row * 32 + 8, 20, 16));
            }
    });
}

#pragma mark - Styles

// A hull style is Resources/Styles/<style>.json: material slot name (as in
// the model's material names) to a spec, over everything in default.json.
//   { "textures": "panels", "tint": [r, g, b], "normal": 1.0 }   tiling PBR set, optional "color" and "metalness"
//   { "color": [r, g, b], "roughness": 0.35, "metalness": 0.9 }   plain PBR
//   { "emissive": [r, g, b] | "windows", "intensity": 3.0 }      unlit emitter; "animated": "strobe" or "pulse"

static SKColor *ColorFrom(NSArray *rgb, SKColor *fallback) {
    return rgb.count >= 3 ? [SKColor colorWithRed:[rgb[0] floatValue] green:[rgb[1] floatValue] blue:[rgb[2] floatValue] alpha:1] : fallback;
}

static float NumberIn(NSDictionary *d, NSString *key, float fallback) {
    NSNumber *n = d[key];
    return [n isKindOfClass:NSNumber.class] ? n.floatValue : fallback;
}

// Materials whose intensity the frame animates, with their kind ("strobe", "pulse").
static NSMutableArray<NSArray *> *gAnimated;

static SCNMaterial *MaterialFromSpec(NSString *slot, NSDictionary *spec) {
    SCNMaterial *m;
    if (spec[@"textures"]) {
        m = TexturedMaterial(spec[@"textures"], ColorFrom(spec[@"tint"], SKColor.whiteColor), NumberIn(spec, @"normal", 1));
        if (spec[@"color"]) {   // a tinted surface colour instead of the set's colour map
            m.diffuse.contents = ColorFrom(spec[@"color"], SKColor.grayColor);
            m.multiply.contents = nil;
        }
        if (spec[@"metalness"]) m.metalness.contents = @(NumberIn(spec, @"metalness", 0.6f));
    } else if (spec[@"emissive"]) {
        id emissive = spec[@"emissive"];
        BOOL windows = [emissive isKindOfClass:NSString.class] && [emissive isEqualToString:@"windows"];
        m = EmissiveMaterial(windows ? (id)WindowImage() : ColorFrom(emissive, SKColor.whiteColor), NumberIn(spec, @"intensity", 1));
        if (windows) Repeat(m.emission);
        NSString *animated = spec[@"animated"];
        if (animated.length) {
            if (!gAnimated) gAnimated = [NSMutableArray array];
            [gAnimated addObject:@[m, animated]];
        }
    } else {
        m = PlainMaterial(ColorFrom(spec[@"color"], SKColor.grayColor), NumberIn(spec, @"roughness", 0.5f), NumberIn(spec, @"metalness", 0.5f));
    }
    m.name = slot;
    return m;
}

static NSDictionary *StyleFile(NSString *style) {
    NSURL *url = FSURL(@"Data/Styles", style, @"json");
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [d isKindOfClass:NSDictionary.class] ? d : nil;
}

static NSDictionary<NSString *, SCNMaterial *> *StyleMaterials(NSString *style) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        if (cache[style]) return cache[style];
        NSMutableDictionary *specs = [StyleFile(@"default") mutableCopy] ?: [NSMutableDictionary dictionary];
        NSDictionary *own = StyleFile(style);
        if (!own) NSLog(@"CapitalView: no style \"%@\"; using default", style);
        [specs addEntriesFromDictionary:own ?: @{}];
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *slot in specs) {
            NSDictionary *spec = specs[slot];
            if ([spec isKindOfClass:NSDictionary.class]) m[slot] = MaterialFromSpec(slot, spec);
        }
        if (!m[@"Hull"]) m[@"Hull"] = PlainMaterial(SKColor.grayColor, 0.5f, 0.5f);   // never leave a hull unlit
        cache[style] = m;
        return m;
    }
}

@implementation CapitalView

#pragma mark - Prototypes

// The asset's parts with the style's materials, matched by source material
// name. Geometry is copied from the shared ModelInfo so each style can carry
// its own materials.
+ (SCNNode *)prototypeForAsset:(NSString *)asset style:(NSString *)style {
    static NSMutableDictionary<NSString *, SCNNode *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key = [NSString stringWithFormat:@"%@|%@", asset, style];
    @synchronized (cache) {
        if (cache[key]) return cache[key];
        SCNNode *root = [SCNNode node];
        NSDictionary *mats = StyleMaterials(style);
        for (SCNNode *src in [ModelInfo capitalAsset:asset].nodes) {
            SCNGeometry *g = [src.geometry copy];
            NSMutableArray *ms = [NSMutableArray array];
            for (SCNMaterial *m in src.geometry.materials) [ms addObject:mats[m.name] ?: mats[@"Hull"]];
            g.materials = ms;
            SCNNode *n = [SCNNode nodeWithGeometry:g];
            n.name = src.name;
            n.simdTransform = src.simdTransform;
            n.castsShadow = YES;
            [root addChildNode:n];
        }
        cache[key] = root;
        return root;
    }
}

+ (void)updateSharedMaterials:(double)t {
    for (NSArray *entry in gAnimated) {
        SCNMaterial *m = entry[0];
        // Strobe: a short flash every 1.2 s. Pulse: a slow breathing glow.
        if ([entry[1] isEqualToString:@"strobe"]) m.emission.intensity = fmod(t, 1.2) < 0.12 ? 6.0 : 0.6;
        else if ([entry[1] isEqualToString:@"pulse"]) m.emission.intensity = 2.0 + 0.8 * sin(t * 3.0);
    }
}

+ (instancetype)viewWithModel:(NSString *)model {
    NSArray *f = [model componentsSeparatedByString:@":"];
    if (f.count < 3 || ![f[0] isEqualToString:@"cap"]) return nil;
    return [[self alloc] initWithAsset:f[1] style:f[2]];
}

- (instancetype)initWithAsset:(NSString *)asset style:(NSString *)style {
    if ((self = [super init])) {
        _info = [ModelInfo capitalAsset:asset];
        _node = [[CapitalView prototypeForAsset:asset style:style] clone];
        _node.name = asset;
        NSMutableArray *parts = [NSMutableArray array];
        for (SCNNode *n in _node.childNodes) {
            if ([n.name isEqualToString:@"Body"]) _body = n;
            if ([ModelInfo partKindForName:n.name] >= 0) [parts addObject:n];
        }
        _parts = parts;
    }
    return self;
}

- (void)setDeadParts:(uint64_t)mask {
    if (mask == _deadParts) return;
    _deadParts = mask;
    for (NSUInteger i = 0; i < _parts.count && i < MAX_PARTS; i++) _parts[i].hidden = (mask >> i) & 1;
}

- (NSUInteger)countParts:(SubsystemKind)kind alive:(BOOL)aliveOnly {
    NSUInteger n = 0;
    const GameModelInfo *mi = _info.info;
    for (int i = 0; i < mi->numParts; i++)
        if (mi->parts[i].kind == kind && (!aliveOnly || !((_deadParts >> i) & 1))) n++;
    return n;
}

@end
