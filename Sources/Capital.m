#import "Capital.h"
#import <Cocoa/Cocoa.h>
#import "ObjLoader.h"

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static simd_quatf LookRotation(simd_float3 forward, simd_float3 up) {
    simd_float3 f = simd_normalize(forward);
    if (fabsf(simd_dot(f, up)) > 0.98f) up = simd_make_float3(1, 0, 0);
    simd_float3 r = simd_normalize(simd_cross(f, up));
    simd_float3 u = simd_cross(r, f);
    return simd_quaternion(simd_matrix(r, u, -f));
}

@implementation Subsystem
+ (NSString *)nameForKind:(SubsystemKind)kind {
    switch (kind) {
        case SubsystemTurret: return @"TURRET";
        case SubsystemEngine: return @"ENGINE";
        case SubsystemShield: return @"SHIELD GEN";
        case SubsystemCore: return @"REACTOR";
    }
}
@end

#pragma mark - Asset table

// hp, display class, style, flags. Styles pick the hull texture set and tints.
static NSDictionary *AssetTable(void) {
    static NSDictionary *t;
    if (!t) t = @{
        @"Carrier":        @{ @"hp": @120, @"class": @"Fleet Carrier", @"style": @"concord" },
        @"Frigate":        @{ @"hp": @30, @"class": @"Frigate", @"style": @"concord" },
        @"CommRelay":      @{ @"hp": @30, @"class": @"Comm Relay", @"style": @"concord" },
        @"RingStation":    @{ @"hp": @90, @"class": @"Orbital Station", @"style": @"concord" },
        @"ResearchVessel": @{ @"hp": @22, @"class": @"Survey Ship", @"style": @"concord" },
        @"JumpGate":       @{ @"hp": @1, @"class": @"Jump Gate", @"style": @"concord", @"invulnerable": @YES },
        @"NavBuoy":        @{ @"hp": @1, @"class": @"Nav Buoy", @"style": @"concord", @"prop": @YES },
        @"Freighter":      @{ @"hp": @25, @"class": @"Freighter", @"style": @"civil" },
        @"Tanker":         @{ @"hp": @22, @"class": @"Tanker", @"style": @"civil" },
        @"Liner":          @{ @"hp": @35, @"class": @"Liner", @"style": @"civil" },
        @"HospitalShip":   @{ @"hp": @28, @"class": @"Hospital Ship", @"style": @"medical" },
        @"FuelDepot":      @{ @"hp": @40, @"class": @"Fuel Depot", @"style": @"civil" },
        @"Container":      @{ @"hp": @1.2, @"class": @"Cargo Container", @"style": @"civil", @"prop": @YES },
        @"EscapePod":      @{ @"hp": @0.6, @"class": @"Escape Pod", @"style": @"civil", @"prop": @YES },
        @"Corvette":       @{ @"hp": @9, @"class": @"Corvette", @"style": @"skarn" },
        @"Destroyer":      @{ @"hp": @28, @"class": @"Destroyer", @"style": @"skarn" },
        @"Cruiser":        @{ @"hp": @45, @"class": @"Heavy Cruiser", @"style": @"skarn" },
        @"Dreadnought":    @{ @"hp": @80, @"class": @"Dreadnought", @"style": @"skarn" },
        @"Minelayer":      @{ @"hp": @7, @"class": @"Minelayer", @"style": @"skarn" },
        @"DefensePlatform":@{ @"hp": @14, @"class": @"Defence Platform", @"style": @"skarn" },
        @"Shipyard":       @{ @"hp": @50, @"class": @"Shipyard", @"style": @"skarn" },
        @"PrisonBarge":    @{ @"hp": @40, @"class": @"Prison Barge", @"style": @"skarn" },
        @"Prototype":      @{ @"hp": @3, @"class": @"Stealth Prototype", @"style": @"stealth" },
        @"Mine":           @{ @"hp": @0.15, @"class": @"Mine", @"style": @"skarn", @"prop": @YES, @"mine": @YES },
        @"CorsairBase":    @{ @"hp": @50, @"class": @"Corsair Base", @"style": @"corsair" },
        @"CorsairCutter":  @{ @"hp": @5, @"class": @"Corsair Cutter", @"style": @"corsair" },
        @"AsteroidA":      @{ @"hp": @1, @"class": @"Asteroid", @"style": @"rock", @"invulnerable": @YES },
        @"AsteroidB":      @{ @"hp": @1, @"class": @"Asteroid", @"style": @"rock", @"invulnerable": @YES },
        @"AsteroidC":      @{ @"hp": @1, @"class": @"Asteroid", @"style": @"rock", @"invulnerable": @YES },
    };
    return t;
}

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
static SCNMaterial *TexturedMaterial(NSString *set, NSColor *tint, float normalStrength) {
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
    return m;
}

static SCNMaterial *PlainMaterial(NSColor *c, float rough, float metal) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelPhysicallyBased;
    m.diffuse.contents = c;
    m.roughness.contents = @(rough);
    m.metalness.contents = @(metal);
    return m;
}

static SCNMaterial *EmissiveMaterial(id contents, float intensity) {
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;
    m.diffuse.contents = [NSColor blackColor];
    m.emission.contents = contents;
    m.emission.intensity = intensity;
    return m;
}

// Rows of cabin windows, about two thirds lit, in a few warm and cool tones.
static NSImage *WindowImage(void) {
    return [NSImage imageWithSize:NSMakeSize(512, 128) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSColor colorWithWhite:0.01 alpha:1] setFill];
        NSRectFill(r);
        srand48(77);
        NSArray *tones = @[[NSColor colorWithRed:1 green:0.85 blue:0.55 alpha:1], [NSColor colorWithRed:0.75 green:0.9 blue:1 alpha:1],
                           [NSColor colorWithRed:1 green:0.95 blue:0.85 alpha:1]];
        for (int row = 0; row < 4; row++)
            for (int col = 0; col < 16; col++) {
                if (drand48() < 0.33) continue;
                NSColor *c = tones[(int)(drand48() * tones.count)];
                [[c colorWithAlphaComponent:0.5 + drand48() * 0.5] setFill];
                NSRectFill(NSMakeRect(col * 32 + 6, row * 32 + 8, 20, 16));
            }
        return YES;
    }];
}

static SCNMaterial *gLights, *gShield;

static NSDictionary<NSString *, SCNMaterial *> *StyleMaterials(NSString *style) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    if (cache[style]) return cache[style];

    NSString *set = @"panels", *darkSet = @"hex";   // Hull and HullDark texture sets
    NSColor *tint = [NSColor colorWithRed:0.85 green:0.88 blue:0.95 alpha:1];
    NSColor *dark = [NSColor colorWithRed:0.42 green:0.44 blue:0.5 alpha:1];
    NSColor *glow = [NSColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1];
    if ([style isEqualToString:@"civil"] || [style isEqualToString:@"medical"]) {
        set = @"plating";
        darkSet = @"ribbed";
        tint = [NSColor colorWithRed:1 green:0.97 blue:0.92 alpha:1];
        dark = [NSColor colorWithWhite:0.5 alpha:1];
        glow = [style isEqualToString:@"medical"] ? [NSColor colorWithRed:0.3 green:1 blue:0.5 alpha:1]
                                                  : [NSColor colorWithRed:1 green:0.75 blue:0.4 alpha:1];
    } else if ([style isEqualToString:@"skarn"] || [style isEqualToString:@"stealth"]) {
        BOOL stealth = [style isEqualToString:@"stealth"];
        set = darkSet = stealth ? @"stealth" : @"armor";
        // The stealth set is already near-black, so it only needs a light tint.
        tint = stealth ? [NSColor colorWithWhite:0.85 alpha:1] : [NSColor colorWithRed:0.78 green:0.66 blue:0.63 alpha:1];
        dark = stealth ? [NSColor colorWithWhite:0.55 alpha:1] : [NSColor colorWithRed:0.4 green:0.34 blue:0.33 alpha:1];
        glow = [NSColor colorWithRed:1.0 green:0.25 blue:0.12 alpha:1];
    } else if ([style isEqualToString:@"corsair"]) {
        set = darkSet = @"rusted";
        tint = [NSColor colorWithWhite:0.9 alpha:1];
        dark = [NSColor colorWithWhite:0.45 alpha:1];
        glow = [NSColor colorWithRed:1 green:0.55 blue:0.2 alpha:1];
    }

    if (!gLights) {
        gLights = EmissiveMaterial([NSColor whiteColor], 4);
        gShield = EmissiveMaterial([NSColor colorWithRed:0.3 green:0.8 blue:1 alpha:1], 2.5);
    }
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"Hull"] = TexturedMaterial(set, tint, 1.0);
    m[@"HullDark"] = TexturedMaterial(darkSet, dark, 1.0);
    m[@"Civil"] = TexturedMaterial(@"plating", [NSColor colorWithRed:0.95 green:0.95 blue:0.96 alpha:1], 0.8);
    m[@"Trim"] = PlainMaterial([NSColor colorWithWhite:0.5 alpha:1], 0.35, 0.9);
    m[@"Windows"] = EmissiveMaterial(WindowImage(), 1.8);
    Repeat(((SCNMaterial *)m[@"Windows"]).emission);
    m[@"Glow"] = EmissiveMaterial(glow, 3.0);
    m[@"Lights"] = gLights;
    m[@"ShieldGen"] = gShield;
    m[@"GateGlow"] = EmissiveMaterial([NSColor colorWithRed:0.4 green:0.8 blue:1 alpha:1], 4.0);
    m[@"Hangar"] = EmissiveMaterial([NSColor colorWithRed:1 green:0.6 blue:0.3 alpha:1], 0.25);
    m[@"Solar"] = TexturedMaterial(@"solar", [NSColor whiteColor], 1.0);
    m[@"Cargo1"] = TexturedMaterial(@"industrial", [NSColor colorWithRed:0.85 green:0.45 blue:0.15 alpha:1], 1.0);
    m[@"Cargo2"] = TexturedMaterial(@"industrial", [NSColor colorWithRed:0.2 green:0.45 blue:0.65 alpha:1], 1.0);
    m[@"Cargo3"] = TexturedMaterial(@"industrial", [NSColor colorWithRed:0.75 green:0.7 blue:0.25 alpha:1], 1.0);
    SCNMaterial *rock = TexturedMaterial(@"rusted", [NSColor colorWithRed:0.42 green:0.39 blue:0.36 alpha:1], 1.4);
    rock.diffuse.contents = [NSColor colorWithRed:0.42 green:0.39 blue:0.36 alpha:1];
    rock.multiply.contents = nil;
    rock.metalness.contents = @0;
    m[@"Rock"] = rock;
    cache[style] = m;
    return m;
}

#pragma mark - Prototypes

static SCNNode *Prototype(NSString *asset, NSString *style) {
    static NSMutableDictionary<NSString *, SCNNode *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@|%@", asset, style];
    if (cache[key]) return cache[key];

    SCNNode *root = [SCNNode node];
    NSURL *url = [[NSBundle mainBundle] URLForResource:asset withExtension:@"obj" subdirectory:@"Models/Capital"];
    NSArray<SCNNode *> *parts = [ObjLoader nodesFromURL:url];
    if (!parts.count) NSLog(@"Capital: missing asset %@", asset);
    NSDictionary *mats = StyleMaterials(style);
    for (SCNNode *n in parts) {
        NSMutableArray *ms = [NSMutableArray array];
        for (SCNMaterial *src in n.geometry.materials) [ms addObject:mats[src.name] ?: mats[@"Hull"]];
        n.geometry.materials = ms;
        n.castsShadow = YES;
        [root addChildNode:n];
    }
    if (!parts.count) [root addChildNode:[SCNNode nodeWithGeometry:[SCNBox boxWithWidth:20 height:20 length:60 chamferRadius:2]]];
    cache[key] = root;
    return root;
}

#pragma mark - Capital

@implementation Capital {
    NSMutableArray<Subsystem *> *_subs;
    NSUInteger _pathIndex;
    float _currentSpeed;
    BOOL _hadEngines;
}

+ (NSDictionary *)infoForAsset:(NSString *)asset { return AssetTable()[asset]; }

+ (void)updateSharedMaterials:(double)t {
    // Strobe: a short flash every 1.2 s.
    gLights.emission.intensity = fmod(t, 1.2) < 0.12 ? 6.0 : 0.6;
    gShield.emission.intensity = 2.0 + 0.8 * sin(t * 3.0);
}

+ (instancetype)capitalWithAsset:(NSString *)asset style:(NSString *)style team:(Team)team {
    return [[self alloc] initWithAsset:asset style:style team:team];
}

- (instancetype)initWithAsset:(NSString *)asset style:(NSString *)style team:(Team)team {
    if ((self = [super init])) {
        NSDictionary *info = AssetTable()[asset] ?: @{ @"hp": @10, @"class": asset, @"style": @"concord" };
        _asset = [asset copy];
        _team = team;
        _className = info[@"class"];
        _maxHull = _hull = [info[@"hp"] floatValue];
        _invulnerable = [info[@"invulnerable"] boolValue];
        _isProp = [info[@"prop"] boolValue];
        _isMine = [info[@"mine"] boolValue];
        _alive = YES;
        _node = [Prototype(asset, style ?: info[@"style"]) clone];
        _node.name = asset;
        _subs = [NSMutableArray array];

        SCNVector3 lo, hi;
        [_node getBoundingBoxMin:&lo max:&hi];
        simd_float3 a = simd_make_float3(lo.x, lo.y, lo.z), b = simd_make_float3(hi.x, hi.y, hi.z);
        _radius = fmaxf(simd_length(a), simd_length(b));

        for (SCNNode *n in _node.childNodes) {
            if ([n.name isEqualToString:@"Body"]) _body = n;
            SubsystemKind kind;
            if ([n.name hasPrefix:@"Turret_"]) kind = SubsystemTurret;
            else if ([n.name hasPrefix:@"Engine_"]) kind = SubsystemEngine;
            else if ([n.name hasPrefix:@"Shield_"]) kind = SubsystemShield;
            else if ([n.name hasPrefix:@"Core_"]) kind = SubsystemCore;
            else continue;
            Subsystem *s = [Subsystem new];
            s.node = n;
            s.kind = kind;
            float hp[] = { 1.2f, 3.0f, 4.0f, fmaxf(4.0f, _maxHull * 0.12f) };
            s.maxHp = s.hp = hp[kind];
            s.alive = YES;
            [n getBoundingBoxMin:&lo max:&hi];
            s.local = simd_make_float3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2);
            simd_float3 out = s.local;
            s.muzzle = simd_length(out) > 1e-3f ? simd_normalize(out) : simd_make_float3(0, 1, 0);
            s.lastShot = -(double)arc4random_uniform(1000) / 1000.0;
            [_subs addObject:s];
        }
        _hadEngines = [self totalCount:SubsystemEngine] > 0;
    }
    return self;
}

- (NSArray<Subsystem *> *)subsystems { return _subs; }

- (void)setUniformScale:(float)scale {
    _radius *= scale / fmaxf(_node.simdScale.x, 1e-3f);
    _node.simdScale = simd_make_float3(scale, scale, scale);
}

- (simd_float3)position { return _node.simdPosition; }
- (void)setPosition:(simd_float3)p { _node.simdPosition = p; }
- (simd_quatf)orientation { return _node.simdOrientation; }
- (void)setOrientation:(simd_quatf)q { _node.simdOrientation = q; }
- (simd_float3)forward { return simd_act(_node.simdOrientation, simd_make_float3(0, 0, -1)); }
- (simd_float3)velocity { return self.forward * _currentSpeed; }

- (simd_float3)worldPoint:(simd_float3)local { return simd_act(_node.simdOrientation, local) + _node.simdPosition; }
- (simd_float3)worldDirection:(simd_float3)local { return simd_act(_node.simdOrientation, local); }

- (NSUInteger)aliveCount:(SubsystemKind)kind {
    NSUInteger n = 0;
    for (Subsystem *s in _subs) if (s.kind == kind && s.alive) n++;
    return n;
}
- (NSUInteger)totalCount:(SubsystemKind)kind {
    NSUInteger n = 0;
    for (Subsystem *s in _subs) if (s.kind == kind) n++;
    return n;
}
- (BOOL)shielded { return [self aliveCount:SubsystemShield] > 0; }
- (BOOL)enginesDead { return _hadEngines && [self aliveCount:SubsystemEngine] == 0; }

- (void)update:(float)dt {
    if (!_alive) return;
    if (_spin != 0) {
        simd_quatf q = simd_quaternion(_spin * (float)M_PI / 180.0f * dt, simd_make_float3(0, 1, 0));
        _node.simdOrientation = simd_normalize(simd_mul(_node.simdOrientation, q));
    }
    float target = (_path.count && !_arrived && !self.enginesDead) ? _speed : 0;
    _currentSpeed += (target - _currentSpeed) * (1.0f - expf(-0.4f * dt));
    if (_path.count && !_arrived) {
        simd_float3 wp;
        [_path[_pathIndex] getValue:&wp size:sizeof wp];
        simd_float3 to = wp - self.position;
        float d = simd_length(to);
        if (d < fmaxf(40.0f, _speed * 2.0f)) {
            if (_pathIndex + 1 < _path.count) _pathIndex++;
            else if (_loop) _pathIndex = 0;
            else _arrived = YES;
        } else if (_spin == 0) {
            // Big ships turn slowly toward the next waypoint.
            simd_quatf want = LookRotation(to / d, simd_make_float3(0, 1, 0));
            float rate = clampf(18.0f / fmaxf(_radius, 10.0f), 0.02f, 0.6f);
            _node.simdOrientation = simd_slerp(_node.simdOrientation, want, 1.0f - expf(-rate * dt));
        }
    }
    _node.simdPosition += self.velocity * dt;
}

- (BOOL)hitSegmentFrom:(simd_float3)a to:(simd_float3)b point:(simd_float3 *)point
             subsystem:(Subsystem * __autoreleasing *)subsystem {
    simd_float4x4 inv = simd_inverse(_node.simdWorldTransform);
    simd_float4 la = simd_mul(inv, simd_make_float4(a, 1)), lb = simd_mul(inv, simd_make_float4(b, 1));
    NSArray<SCNHitTestResult *> *hits = [_node hitTestWithSegmentFromPoint:SCNVector3Make(la.x, la.y, la.z)
                                                                  toPoint:SCNVector3Make(lb.x, lb.y, lb.z)
                                                                  options:@{ SCNHitTestOptionSearchMode : @(SCNHitTestSearchModeClosest),
                                                                             SCNHitTestIgnoreHiddenNodesKey : @YES,
                                                                             SCNHitTestBackFaceCullingKey : @NO }];
    SCNHitTestResult *h = hits.firstObject;
    if (!h) return NO;
    SCNVector3 w = h.worldCoordinates;
    *point = simd_make_float3(w.x, w.y, w.z);
    *subsystem = nil;
    for (Subsystem *s in _subs) if (s.node == h.node && s.alive) { *subsystem = s; break; }
    return YES;
}

- (BOOL)damage:(float)amount subsystem:(Subsystem *)s {
    if (!_alive || _invulnerable) return YES;
    BOOL shielded = self.shielded;
    if (s && s.alive) {
        if (shielded && s.kind != SubsystemShield) return YES;
        s.hp -= amount;
        if (s.hp <= 0) {
            s.alive = NO;
            s.node.hidden = YES;
            if (s.kind == SubsystemCore) _hull = 0;
        }
        if (!_noHullDamage) _hull -= amount * 0.25f;
    } else {
        if (shielded || _noHullDamage) return YES;
        _hull -= amount;
    }
    if (_hull <= 0) {
        _hull = 0;
        _alive = NO;
    }
    return NO;
}

@end
