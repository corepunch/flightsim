#import "PlatformImage.h"
#import "CapitalView.h"
#import "Assets.h"
#import "ShipView.h"

#pragma mark - Materials

static NSURL *TextureURL(NSString *name) {
    return [[NSBundle mainBundle] URLForResource:name withExtension:@"jpg" subdirectory:@"Textures"]
        ?: [[NSBundle mainBundle] URLForResource:name withExtension:@"png" subdirectory:@"Textures"];
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

static SCNMaterial *gLights, *gShield;

static NSDictionary<NSString *, SCNMaterial *> *StyleMaterials(NSString *style) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    if (cache[style]) return cache[style];

    NSString *set = @"panels", *darkSet = @"hex";   // Hull and HullDark texture sets
    SKColor *tint = [SKColor colorWithRed:0.85 green:0.88 blue:0.95 alpha:1];
    SKColor *dark = [SKColor colorWithRed:0.42 green:0.44 blue:0.5 alpha:1];
    SKColor *glow = [SKColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1];
    if ([style isEqualToString:@"civil"] || [style isEqualToString:@"medical"]) {
        set = @"plating";
        darkSet = @"ribbed";
        tint = [SKColor colorWithRed:1 green:0.97 blue:0.92 alpha:1];
        dark = [SKColor colorWithWhite:0.5 alpha:1];
        glow = [style isEqualToString:@"medical"] ? [SKColor colorWithRed:0.3 green:1 blue:0.5 alpha:1]
                                                  : [SKColor colorWithRed:1 green:0.75 blue:0.4 alpha:1];
    } else if ([style isEqualToString:@"skarn"] || [style isEqualToString:@"stealth"]) {
        BOOL stealth = [style isEqualToString:@"stealth"];
        set = darkSet = stealth ? @"stealth" : @"armor";
        // The stealth set is already near-black, so it only needs a light tint.
        tint = stealth ? [SKColor colorWithWhite:0.85 alpha:1] : [SKColor colorWithRed:0.78 green:0.66 blue:0.63 alpha:1];
        dark = stealth ? [SKColor colorWithWhite:0.55 alpha:1] : [SKColor colorWithRed:0.4 green:0.34 blue:0.33 alpha:1];
        glow = [SKColor colorWithRed:1.0 green:0.25 blue:0.12 alpha:1];
    } else if ([style isEqualToString:@"corsair"]) {
        set = darkSet = @"rusted";
        tint = [SKColor colorWithWhite:0.9 alpha:1];
        dark = [SKColor colorWithWhite:0.45 alpha:1];
        glow = [SKColor colorWithRed:1 green:0.55 blue:0.2 alpha:1];
    }

    if (!gLights) {
        gLights = EmissiveMaterial([SKColor whiteColor], 4);
        gShield = EmissiveMaterial([SKColor colorWithRed:0.3 green:0.8 blue:1 alpha:1], 2.5);
    }
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"Hull"] = TexturedMaterial(set, tint, 1.0);
    m[@"HullDark"] = TexturedMaterial(darkSet, dark, 1.0);
    m[@"Civil"] = TexturedMaterial(@"plating", [SKColor colorWithRed:0.95 green:0.95 blue:0.96 alpha:1], 0.8);
    m[@"Trim"] = PlainMaterial([SKColor colorWithWhite:0.5 alpha:1], 0.35, 0.9);
    m[@"Windows"] = EmissiveMaterial(WindowImage(), 1.8);
    Repeat(((SCNMaterial *)m[@"Windows"]).emission);
    m[@"Glow"] = EmissiveMaterial(glow, 3.0);
    m[@"Lights"] = gLights;
    m[@"ShieldGen"] = gShield;
    m[@"GateGlow"] = EmissiveMaterial([SKColor colorWithRed:0.4 green:0.8 blue:1 alpha:1], 4.0);
    m[@"Hangar"] = EmissiveMaterial([SKColor colorWithRed:1 green:0.6 blue:0.3 alpha:1], 0.25);
    m[@"Solar"] = TexturedMaterial(@"solar", [SKColor whiteColor], 1.0);
    m[@"Cargo1"] = TexturedMaterial(@"industrial", [SKColor colorWithRed:0.85 green:0.45 blue:0.15 alpha:1], 1.0);
    m[@"Cargo2"] = TexturedMaterial(@"industrial", [SKColor colorWithRed:0.2 green:0.45 blue:0.65 alpha:1], 1.0);
    m[@"Cargo3"] = TexturedMaterial(@"industrial", [SKColor colorWithRed:0.75 green:0.7 blue:0.25 alpha:1], 1.0);
    SCNMaterial *rock = TexturedMaterial(@"rusted", [SKColor colorWithRed:0.42 green:0.39 blue:0.36 alpha:1], 1.4);
    rock.diffuse.contents = [SKColor colorWithRed:0.42 green:0.39 blue:0.36 alpha:1];
    rock.multiply.contents = nil;
    rock.metalness.contents = @0;
    m[@"Rock"] = rock;
    cache[style] = m;
    return m;
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
    // Strobe: a short flash every 1.2 s.
    gLights.emission.intensity = fmod(t, 1.2) < 0.12 ? 6.0 : 0.6;
    gShield.emission.intensity = 2.0 + 0.8 * sin(t * 3.0);
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
