#import "Render.h"
#import "Shared.h"

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
    m.diffuse.contents = [RenderTextures contentsOfURL:TextureURL([set stringByAppendingString:@"_color"]) sRGB:YES];
    m.multiply.contents = tint;
    m.normal.contents = [RenderTextures contentsOfURL:TextureURL([set stringByAppendingString:@"_normal"]) sRGB:NO];
    m.normal.intensity = normalStrength;
    m.roughness.contents = [RenderTextures contentsOfURL:TextureURL([set stringByAppendingString:@"_rough"]) sRGB:NO];
    NSURL *metal = TextureURL([set stringByAppendingString:@"_metal"]);
    m.metalness.contents = metal ? [RenderTextures contentsOfURL:metal sRGB:NO] : @0.6;
    // The plate sets are fully metallic, which reads as black mirror against
    // space; keep some diffuse so the hulls show their colour.
    m.metalness.intensity = 0.3;
    NSMutableArray *props = [NSMutableArray arrayWithObjects:m.diffuse, m.normal, m.roughness, m.metalness, nil];
    // The generated hull sets (Art/build_hull_textures.py) carry lit windows
    // and running lights, and one tile spans ~40 m instead of the UVs' 24.
    NSURL *emit = TextureURL([set stringByAppendingString:@"_emit"]);
    if (emit) {
        m.emission.contents = [RenderTextures contentsOfURL:emit sRGB:YES];
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

// One painted texture over the whole model (Art/build_pickups.py), not tiled.
// It also lights itself by `glow`, so its colours read out of the light too.
static SCNMaterial *BakedMaterial(NSString *texture, float glow, float rough) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelPhysicallyBased;
    NSURL *url = TextureURL(texture);
    if (!url) NSLog(@"CapitalView: no baked texture \"%@\"", texture);
    id contents = [RenderTextures contentsOfURL:url sRGB:YES];
    m.diffuse.contents = contents ?: SKColor.grayColor;
    m.emission.contents = contents;
    m.emission.intensity = glow;
    m.roughness.contents = @(rough);
    m.metalness.contents = @0;
    for (SCNMaterialProperty *p in @[m.diffuse, m.emission]) p.mipFilter = SCNFilterModeLinear;
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
//   { "baked": "<texture>", "glow": 0.4, "roughness": 0.5 }      one painted texture over the model, partly self-lit

// An [r, g, b] colour, or nil when the key is missing or not one.
static SKColor *JSONColor(NSDictionary *json, NSString *key) {
    NSArray *rgb = JSONArray(json, key);
    return rgb.count >= 3 ? [SKColor colorWithRed:[rgb[0] floatValue] green:[rgb[1] floatValue] blue:[rgb[2] floatValue] alpha:1] : nil;
}

typedef enum { MaterialTextured, MaterialEmissive, MaterialPlain, MaterialBaked } MaterialKind;
typedef enum { MaterialSteady, MaterialStrobe, MaterialPulse } MaterialAnimation;

// One material slot of a style, read once from its JSON spec.
typedef struct {
    MaterialKind kind;
    NSString *textures;             // textured: the tiling PBR set; baked: the painted texture
    SKColor *tint;                  // textured: over the set's colours
    SKColor *color;                 // textured: replaces the set's colour map when set; plain: the surface
    SKColor *emission;              // emissive: the glow, unless it is lit windows
    bool windows;
    float normal, roughness;
    float metalness;                // < 0: the texture set's own
    float intensity;                // emissive: brightness; baked: how far it lights itself
    MaterialAnimation animation;
} MaterialSpec;

static MaterialSpec MaterialSpecFromJSON(NSDictionary *json) {
    MaterialKind kind = JSONString(json, @"baked") ? MaterialBaked : JSONString(json, @"textures") ? MaterialTextured
                      : json[@"emissive"] ? MaterialEmissive : MaterialPlain;
    NSDictionary *animations = @{ @"strobe": @(MaterialStrobe), @"pulse": @(MaterialPulse) };
    NSString *animated = JSONString(json, @"animated");
    return (MaterialSpec){
        .kind = kind,
        .textures = JSONString(json, kind == MaterialBaked ? @"baked" : @"textures"),
        .tint = JSONColor(json, @"tint") ?: SKColor.whiteColor,
        .color = JSONColor(json, @"color") ?: (kind == MaterialPlain ? SKColor.grayColor : nil),
        .emission = JSONColor(json, @"emissive") ?: SKColor.whiteColor,
        .windows = [JSONString(json, @"emissive") isEqualToString:@"windows"],
        .normal = JSONFloat(json, @"normal", 1),
        .roughness = JSONFloat(json, @"roughness", 0.5f),
        .metalness = JSONFloat(json, @"metalness", kind == MaterialPlain ? 0.5f : -1),
        .intensity = kind == MaterialBaked ? JSONFloat(json, @"glow", 0.4f) : JSONFloat(json, @"intensity", 1),
        .animation = animated ? (MaterialAnimation)[animations[animated] intValue] : MaterialSteady,
    };
}

// A material whose glow the frame animates.
@interface AnimatedMaterial : NSObject
@property (nonatomic, strong) SCNMaterial *material;
@property (nonatomic) MaterialAnimation animation;
@end
@implementation AnimatedMaterial
@end

static NSMutableArray<AnimatedMaterial *> *gAnimated;

static SCNMaterial *MaterialFromSpec(NSString *slot, MaterialSpec spec) {
    SCNMaterial *m;
    switch (spec.kind) {
        case MaterialTextured:
            m = TexturedMaterial(spec.textures, spec.tint, spec.normal);
            if (spec.color) {   // a tinted surface colour instead of the set's colour map
                m.diffuse.contents = spec.color;
                m.multiply.contents = nil;
            }
            if (spec.metalness >= 0) m.metalness.contents = @(spec.metalness);
            break;
        case MaterialEmissive:
            m = EmissiveMaterial(spec.windows ? (id)WindowImage() : spec.emission, spec.intensity);
            if (spec.windows) Repeat(m.emission);
            if (spec.animation != MaterialSteady) {
                AnimatedMaterial *animated = [AnimatedMaterial new];
                animated.material = m;
                animated.animation = spec.animation;
                if (!gAnimated) gAnimated = [NSMutableArray array];
                [gAnimated addObject:animated];
            }
            break;
        case MaterialPlain:
            m = PlainMaterial(spec.color, spec.roughness, spec.metalness);
            break;
        case MaterialBaked:
            m = BakedMaterial(spec.textures, spec.intensity, spec.roughness);
            break;
    }
    m.name = slot;
    return m;
}

static NSDictionary *StyleFile(NSString *style) {
    id json = FSJSON(FSURL(@"Data/Styles", style, @"json"));
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

@interface HullMaterialDefinition : NSObject
@property (nonatomic) MaterialSpec spec;
@end
@implementation HullMaterialDefinition
@end

// A style describes many possible slots; only slots on a loaded mesh should
// allocate textures. Several styles can still share the same texture objects.
@interface HullStyle : NSObject
- (instancetype)initWithName:(NSString *)name;
- (SCNMaterial *)materialForSlot:(NSString *)slot;
@end
@implementation HullStyle {
    NSDictionary<NSString *, HullMaterialDefinition *> *_definitions;
    NSMutableDictionary<NSString *, SCNMaterial *> *_materials;
}
- (instancetype)initWithName:(NSString *)name {
    if ((self = [super init])) {
        NSMutableDictionary *specs = [StyleFile(@"default") mutableCopy] ?: [NSMutableDictionary dictionary];
        NSDictionary *own = StyleFile(name);
        if (!own) NSLog(@"CapitalView: no style \"%@\"; using default", name);
        [specs addEntriesFromDictionary:own ?: @{}];
        NSMutableDictionary *definitions = [NSMutableDictionary dictionary];
        for (NSString *slot in specs) {
            NSDictionary *json = JSONObject(specs, slot);
            if (!json) continue;
            HullMaterialDefinition *definition = [HullMaterialDefinition new];
            definition.spec = MaterialSpecFromJSON(json);
            definitions[slot] = definition;
        }
        _definitions = [definitions copy];
        _materials = [NSMutableDictionary dictionary];
    }
    return self;
}
- (SCNMaterial *)materialForSlot:(NSString *)slot {
    SCNMaterial *material = _materials[slot];
    if (material) return material;
    HullMaterialDefinition *definition = _definitions[slot];
    if (definition) material = MaterialFromSpec(slot, definition.spec);
    else if (![slot isEqualToString:@"Hull"]) return [self materialForSlot:@"Hull"];
    else material = PlainMaterial(SKColor.grayColor, 0.5f, 0.5f);
    _materials[slot] = material;
    return material;
}
@end

static HullStyle *StyleMaterials(NSString *style) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        if (cache[style]) return cache[style];
        HullStyle *materials = [[HullStyle alloc] initWithName:style];
        cache[style] = materials;
        return materials;
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
        HullStyle *mats = StyleMaterials(style);
        for (SCNNode *src in [ModelInfo capitalAsset:asset].nodes) {
            SCNGeometry *g = [src.geometry copy];
            NSMutableArray *ms = [NSMutableArray array];
            for (SCNMaterial *m in src.geometry.materials) [ms addObject:[mats materialForSlot:m.name ?: @"Hull"]];
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
    for (AnimatedMaterial *entry in gAnimated) {
        // Strobe: a short flash every 1.2 s. Pulse: a slow breathing glow.
        switch (entry.animation) {
            case MaterialStrobe: entry.material.emission.intensity = fmod(t, 1.2) < 0.12 ? 6.0 : 0.6; break;
            case MaterialPulse: entry.material.emission.intensity = 2.0 + 0.8 * sin(t * 3.0); break;
            case MaterialSteady: break;
        }
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
