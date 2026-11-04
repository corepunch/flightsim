#import "Cockpit.h"
#import <SpriteKit/SpriteKit.h>
#import <Metal/Metal.h>
#import "SceneAsset.h"
#import "UIStyle.h"

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static NSColor *ScreenColor(CGFloat a) { return UIColorWithOpacity(UIInk, a); }
static NSColor *WarnColor(CGFloat a) { return [NSColor colorWithRed:1.0 green:0.68 blue:0.2 alpha:a]; }
static NSColor *EnemyColor(CGFloat a) { return UIColorWithOpacity(UIRed, a); }
static NSColor *ShieldColor(CGFloat a) { return UIColorWithOpacity(UIShield, a); }

// Green -> amber -> red as a level drops.
static NSColor *LevelColor(float v, CGFloat a) {
    return v > 0.5f ? ScreenColor(a) : (v > 0.25f ? WarnColor(a) : EnemyColor(a));
}

// Where the holograms float on the MFDs, in display pixels (608 x 480).
static const CGPoint kHoloSpot = { 160, 220 };

static BOOL Blink(double t, double hz) { return fmod(t * hz, 1.0) < 0.5; }

#pragma mark - Display widgets

static SKLabelNode *Text(CGFloat size, SKLabelHorizontalAlignmentMode align, NSColor *color) {
    SKLabelNode *label = UIMonoLabel(size, color, align, SKLabelVerticalAlignmentModeCenter);
    label.fontName = UIMonoBoldFont;
    return label;
}

static SKShapeNode *Stroke(CGPathRef path, NSColor *color, CGFloat width) {
    SKShapeNode *n = [SKShapeNode shapeNodeWithPath:path];
    n.strokeColor = color;
    n.lineWidth = width;
    n.fillColor = [NSColor clearColor];
    return n;
}

// Horizontal bar: dim track plus a fill sprite scaled along X.
@interface Bar : SKNode
@property (nonatomic, readonly) SKSpriteNode *fill;
@property (nonatomic) float value;
@end
@implementation Bar
- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super init])) {
        SKSpriteNode *track = [SKSpriteNode spriteNodeWithColor:ScreenColor(0.12) size:size];
        track.anchorPoint = CGPointMake(0, 0.5);
        [self addChild:track];
        _fill = [SKSpriteNode spriteNodeWithColor:ScreenColor(0.9) size:size];
        _fill.anchorPoint = CGPointMake(0, 0.5);
        [self addChild:_fill];
        // Tick marks every 10%.
        for (int i = 1; i < 10; i++) {
            SKSpriteNode *tick = [SKSpriteNode spriteNodeWithColor:[NSColor colorWithWhite:0 alpha:0.6] size:CGSizeMake(2, size.height)];
            tick.position = CGPointMake(size.width * i / 10.0, 0);
            [self addChild:tick];
        }
    }
    return self;
}
- (void)setValue:(float)value {
    _value = value;
    _fill.xScale = MAX(clampf(value, 0, 1), 0.0001);
}
@end

// Background shared by every display: dark glass, faint grid, scanlines and
// a vignette, so the screens don't read as flat colour.
static SKTexture *ScreenBackground(CGSize size) {
    NSImage *img = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect r) {
        CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
        CGFloat comps[] = { 0.02, 0.075, 0.07, 1,   0.004, 0.012, 0.014, 1 };
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
        CGPoint c = CGPointMake(r.size.width / 2, r.size.height / 2);
        CGContextDrawRadialGradient(cg, g, c, 0, c, hypot(c.x, c.y), kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);
        [[NSColor colorWithRed:0.55 green:0.95 blue:0.85 alpha:0.05] setFill];
        for (CGFloat x = 0; x < r.size.width; x += 32) NSRectFill(NSMakeRect(x, 0, 1, r.size.height));
        for (CGFloat y = 0; y < r.size.height; y += 32) NSRectFill(NSMakeRect(0, y, r.size.width, 1));
        [[NSColor colorWithWhite:0 alpha:0.18] setFill];
        for (CGFloat y = 0; y < r.size.height; y += 3) NSRectFill(NSMakeRect(0, y, r.size.width, 1));
        return YES;
    }];
    return [SKTexture textureWithImage:img];
}

static SKScene *MakeScreen(CGSize size, NSString *title) {
    SKScene *s = [SKScene sceneWithSize:size];
    s.backgroundColor = [NSColor blackColor];
    s.scaleMode = SKSceneScaleModeFill;
    SKSpriteNode *bg = [SKSpriteNode spriteNodeWithTexture:ScreenBackground(size)];
    bg.anchorPoint = CGPointZero;
    bg.zPosition = -10;
    [s addChild:bg];
    if (title) {
        SKLabelNode *t = Text(26, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.85));
        t.text = title;
        t.position = CGPointMake(22, size.height - 30);
        [s addChild:t];
        CGMutablePathRef p = CGPathCreateMutable();
        CGPathMoveToPoint(p, NULL, 18, size.height - 52);
        CGPathAddLineToPoint(p, NULL, size.width - 18, size.height - 52);
        [s addChild:Stroke(p, ScreenColor(0.35), 2)];
        CGPathRelease(p);
    }
    return s;
}

// A display quad located from its geometry: origin is the bottom-left
// corner, u/v span the full width/height, n faces the pilot.
typedef struct { simd_float3 origin, u, v, n; } ScreenFrame;

static simd_float3 ReadFloat3(SCNGeometrySource *src, NSInteger i) {
    const uint8_t *p = (const uint8_t *)src.data.bytes + src.dataOffset + i * src.dataStride;
    const float *f = (const float *)p;
    return simd_make_float3(f[0], f[1], src.componentsPerVector > 2 ? f[2] : 0);
}

static BOOL FindScreen(SCNGeometry *g, NSString *material, ScreenFrame *out) {
    SCNGeometrySource *pos = [g geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
    SCNGeometrySource *uv = [g geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
    if (!pos || !uv || pos.bytesPerComponent != 4 || uv.bytesPerComponent != 4) return NO;
    for (NSUInteger e = 0; e < g.geometryElementCount && e < g.materials.count; e++) {
        if (![g.materials[e].name isEqualToString:material]) continue;
        SCNGeometryElement *el = [g geometryElementAtIndex:e];
        const uint8_t *idx = el.data.bytes;
        NSInteger n = el.data.length / el.bytesPerIndex;
        // Corners by UV: (0,0), (1,0), (0,1).
        simd_float3 corner[3];
        float best[3] = { FLT_MAX, FLT_MAX, FLT_MAX };
        simd_float2 want[3] = { {0, 0}, {1, 0}, {0, 1} };
        for (NSInteger k = 0; k < n; k++) {
            NSInteger vi = el.bytesPerIndex == 2 ? ((const uint16_t *)idx)[k] : ((const uint32_t *)idx)[k];
            simd_float3 t = ReadFloat3(uv, vi);
            for (int c = 0; c < 3; c++) {
                float d = simd_distance_squared(t.xy, want[c]);
                if (d < best[c]) { best[c] = d; corner[c] = ReadFloat3(pos, vi); }
            }
        }
        ScreenFrame f = { corner[0], corner[1] - corner[0], corner[2] - corner[0] };
        // Whatever the importer did to V, the screen's up runs uphill and
        // its right runs to +X.
        if (f.v.y < 0) { f.origin += f.v; f.v = -f.v; }
        if (f.u.x < 0) { f.origin += f.u; f.u = -f.u; }
        f.n = simd_normalize(simd_cross(f.u, f.v));
        if (simd_dot(f.n, f.origin) > 0) f.n = -f.n;   // the eye is the origin
        *out = f;
        return YES;
    }
    return NO;
}

// A ship mesh drawn as a wireframe hologram floating just off a display.
static SCNNode *Hologram(NSColor *color, SCNNode * __strong *modelOut) {
    SCNNode *holder = [SCNNode node];
    SCNNode *model = [SCNNode node];
    model.eulerAngles = SCNVector3Make(0, M_PI, 0);   // OBJ +Z nose -> ship -Z nose
    model.castsShadow = NO;
    [holder addChildNode:model];

    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;
    m.diffuse.contents = color;
    m.fillMode = SCNFillModeLines;
    m.blendMode = SCNBlendModeAdd;
    m.doubleSided = YES;
    m.writesToDepthBuffer = NO;
    [model setValue:m forKey:@"holoMaterial"];
    *modelOut = model;
    return holder;
}

static void SetHologramShip(SCNNode *model, ShipClass c) {
    SCNGeometry *g = [[ShipView geometryForClass:c] copy];
    g.materials = @[[model valueForKey:@"holoMaterial"]];
    model.geometry = g;
}

// Any mesh as a hologram. Fighter meshes are in OBJ space (+Z nose) and
// need the half turn; capital meshes were exported in ship space.
static void SetHologramGeometry(SCNNode *model, SCNGeometry *source, float scale, BOOL fighter) {
    SCNGeometry *g = [source copy];
    g.materials = @[[model valueForKey:@"holoMaterial"]];
    model.geometry = g;
    model.eulerAngles = SCNVector3Make(0, fighter ? M_PI : 0, 0);
    model.simdScale = simd_make_float3(scale, scale, scale);
}

static NSColor *TeamColor(Team t, CGFloat a) {
    return t == TeamEnemy ? EnemyColor(a) : (t == TeamFriend ? [NSColor colorWithRed:0.4 green:1 blue:0.55 alpha:a]
                                                             : [NSColor colorWithRed:0.95 green:0.88 blue:0.45 alpha:a]);
}

#pragma mark - Lamps

// Annunciator face: legend over a tinted tile. The lit version feeds the
// emission channel, the unlit one the diffuse, so an off lamp still shows
// its engraved legend.
static NSImage *LampImage(NSString *legend, NSColor *color, BOOL lit) {
    return [NSImage imageWithSize:NSMakeSize(256, 120) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSColor *bg = lit ? [color colorWithAlphaComponent:1] : [NSColor colorWithWhite:0.07 alpha:1];
        if (lit) bg = [NSColor colorWithRed:color.redComponent * 0.12 green:color.greenComponent * 0.12 blue:color.blueComponent * 0.12 alpha:1];
        [bg setFill];
        NSRectFill(r);
        NSColor *fg = lit ? [color blendedColorWithFraction:0.25 ofColor:NSColor.whiteColor] : [NSColor colorWithWhite:0.32 alpha:1];
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = NSTextAlignmentCenter;
        BOOL twoLines = [legend containsString:@"\n"];
        NSDictionary *attrs = @{ NSFontAttributeName : [NSFont fontWithName:UIMonoBoldFont size:twoLines ? 38 : 54] ?: [NSFont boldSystemFontOfSize:50],
                                 NSForegroundColorAttributeName : fg, NSParagraphStyleAttributeName : ps };
        NSSize ts = [legend sizeWithAttributes:attrs];
        [legend drawInRect:NSMakeRect(0, (r.size.height - ts.height) / 2, r.size.width, ts.height) withAttributes:attrs];
        return YES;
    }];
}

@interface Lamp : NSObject
@property (nonatomic, strong) SCNMaterial *material;
@property (nonatomic) float level, peak;
@end
@implementation Lamp
@end

// One display: a SpriteKit scene rendered offscreen into the texture that
// the screen's material samples.
@interface Display : NSObject
@property (nonatomic, strong) SKScene *scene;
@property (nonatomic, strong) SKRenderer *renderer;
@property (nonatomic, strong) id<MTLTexture> texture;
@end
@implementation Display
@end

#pragma mark - Cockpit

@implementation Cockpit {
    SCNNode *_stick, *_throttle;
    SCNVector3 _throttleRest;
    NSMutableDictionary<NSString *, Lamp *> *_lamps;

    SKScene *_radar, *_self, *_target, *_status;

    // Radar
    NSMutableArray<SKShapeNode *> *_blips, *_stalks;
    SKShapeNode *_radarTargetMark;
    SKLabelNode *_radarRange;
    CGPoint _radarCentre;
    CGSize _radarRadius;

    // Self status
    SCNNode *_selfHolder, *_selfModel;
    SKShapeNode *_shieldRing;
    Bar *_shieldBar, *_hullBar, *_boostBar, *_throttleBar;
    SKLabelNode *_shieldPct, *_hullPct, *_boostPct, *_throttlePct, *_speedLabel, *_selfState;

    // Target
    SCNNode *_targetHolder, *_targetModel;
    SKNode *_targetInfo;
    SKLabelNode *_noTarget, *_targetName, *_targetRange, *_targetClosing, *_targetMode, *_targetHullPct, *_targetShieldPct;
    Bar *_targetHull, *_targetShield;
    SCNGeometry *_targetGeometry;
    SKLabelNode *_targetTeam, *_targetClassLabel;

    // Status
    SKLabelNode *_killsLabel, *_deathsLabel, *_clockLabel, *_messageLabel;
    NSString *_message;
    double _messageUntil;
    BOOL _messageWarn;
    CockpitFrame _last;
    id<MTLDevice> _device;
    NSMutableArray<Display *> *_displays;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        _displays = [NSMutableArray array];
        _node = [SCNNode node];
        _node.name = @"Cockpit";
        _lamps = [NSMutableDictionary dictionary];
        [self buildDisplays];
        [self loadModel];
    }
    return self;
}

- (void)loadModel {
    NSArray<SCNNode *> *parts = SceneAssetNodes(@"Cockpit", @"Models");
    if (!parts.count) { NSLog(@"Cockpit: model missing"); return; }
    for (SCNNode *n in parts) {
        n.castsShadow = YES;
        [_node addChildNode:n];
        for (SCNMaterial *m in n.geometry.materials) [self styleMaterial:m];
        if ([n.name isEqualToString:@"Stick"]) _stick = n;
        if ([n.name isEqualToString:@"Throttle"]) _throttle = n;
    }

    // The stick pivots on the bottom of its boot.
    if (_stick) {
        SCNVector3 lo, hi;
        [_stick getBoundingBoxMin:&lo max:&hi];
        SCNVector3 p = SCNVector3Make((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2);
        _stick.pivot = SCNMatrix4MakeTranslation(p.x, p.y, p.z);
        _stick.position = p;
    }
    _throttleRest = _throttle.position;

    // Holograms hover a couple of centimetres off the MFD glass.
    for (SCNNode *n in _node.childNodes) {
        ScreenFrame sl, sr;
        if (FindScreen(n.geometry, @"Screen_Left", &sl)) [self mountHologram:_selfHolder on:sl scale:0.0085f topDown:YES];
        if (FindScreen(n.geometry, @"Screen_Right", &sr)) [self mountHologram:_targetHolder on:sr scale:0.0075f topDown:NO];
    }
}

- (void)mountHologram:(SCNNode *)holo on:(ScreenFrame)f scale:(float)scale topDown:(BOOL)topDown {
    simd_float3 p = f.origin + f.u * (float)(kHoloSpot.x / 608.0) + f.v * (float)(kHoloSpot.y / 480.0) + f.n * 0.025f;
    SCNNode *mount = [SCNNode node];
    mount.simdPosition = p;
    mount.simdScale = simd_make_float3(scale, scale, scale);
    if (topDown) {
        // Seen from above, nose toward the top of the display.
        simd_float3 u = simd_normalize(f.u), v = simd_normalize(f.v);
        mount.simdOrientation = simd_quaternion(simd_matrix(u, f.n, -v));
    }
    [mount addChildNode:holo];
    [_node addChildNode:mount];
    holo.renderingOrder = 100;
}

- (void)styleMaterial:(SCNMaterial *)m {
    NSString *name = m.name ?: @"";
    m.lightingModelName = SCNLightingModelPhysicallyBased;
    m.emission.contents = [NSColor blackColor];
    m.ambientOcclusion.contents = nil;
    m.specular.contents = nil;

    if ([name hasPrefix:@"Screen_"]) {
        NSString *key = [name substringFromIndex:7];
        SKScene *s = [self screenNamed:key];
        Display *d = [self displayForScene:s];
        // Constant model: the display is self-lit, and intensity > 1 lets
        // bright strokes bloom.
        m.lightingModelName = SCNLightingModelConstant;
        m.diffuse.contents = d.texture;
        m.diffuse.mipFilter = SCNFilterModeNone;
        m.diffuse.intensity = 1.2;
        return;
    }
    if ([name hasPrefix:@"Lamp_"]) {
        NSString *key = [name substringFromIndex:5];
        [self styleLamp:m key:key];
        return;
    }

    struct { const char *name; float r, g, b, rough, metal; } table[] = {
        { "Panel",  0.05, 0.055, 0.06, 0.62, 0.35 },
        { "Frame",  0.2, 0.21, 0.22, 0.32, 0.9 },
        { "Trim",   0.38, 0.39, 0.4, 0.42, 0.75 },
        { "Bezel",  0.025, 0.026, 0.03, 0.4, 0.2 },
        { "Rubber", 0.022, 0.022, 0.022, 0.9, 0.0 },
        { "Hazard", 0.62, 0.42, 0.06, 0.5, 0.1 },
        { "Seat",   0.08, 0.075, 0.07, 0.85, 0.0 },
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
        if (strcmp(table[i].name, name.UTF8String)) continue;
        m.diffuse.contents = [NSColor colorWithRed:table[i].r green:table[i].g blue:table[i].b alpha:1];
        m.roughness.contents = @(table[i].rough);
        m.metalness.contents = @(table[i].metal);
        return;
    }
    if ([name isEqualToString:@"Glass"]) {
        // HUD combiner: barely there, a green tint and a sharp reflection.
        m.diffuse.contents = [NSColor colorWithRed:0.3 green:0.9 blue:0.7 alpha:1];
        m.roughness.contents = @0.05;
        m.metalness.contents = @0;
        m.transparent.contents = [NSColor colorWithWhite:1 alpha:0.1];
        m.transparencyMode = SCNTransparencyModeAOne;
        m.blendMode = SCNBlendModeAlpha;
        m.writesToDepthBuffer = NO;
        m.doubleSided = YES;
        return;
    }
    NSLog(@"Cockpit: unknown material %@", name);
}

- (void)styleLamp:(SCNMaterial *)m key:(NSString *)key {
    NSDictionary<NSString *, NSArray *> *legends = @{
        @"Caution" : @[@"MASTER\nCAUTION", WarnColor(1)],
        @"Shield"  : @[@"SHIELD", ShieldColor(1)],
        @"Hull"    : @[@"HULL", EnemyColor(1)],
        @"Hit"     : @[@"HIT", EnemyColor(1)],
        @"Six"     : @[@"SIX", EnemyColor(1)],
        @"Lock"    : @[@"LOCK", [NSColor colorWithRed:0.3 green:1 blue:0.45 alpha:1]],
        @"Guns"    : @[@"GUNS", [NSColor colorWithRed:0.3 green:1 blue:0.45 alpha:1]],
        @"Boost"   : @[@"BOOST", WarnColor(1)],
        @"Prox"    : @[@"PROX", WarnColor(1)],
    };
    NSArray *legend = legends[key];
    m.metalness.contents = @0;
    m.roughness.contents = @0.25;
    if (legend) {
        m.diffuse.contents = LampImage(legend[0], legend[1], NO);
        m.emission.contents = LampImage(legend[0], legend[1], YES);
    } else {
        // Throttle ladder LEDs: plain colour, amber at the top.
        int i = [key hasPrefix:@"Thr"] ? [key substringFromIndex:3].intValue : 0;
        NSColor *c = i < 7 ? [NSColor colorWithRed:0.3 green:1 blue:0.45 alpha:1] : WarnColor(1);
        m.diffuse.contents = [NSColor colorWithWhite:0.05 alpha:1];
        m.emission.contents = c;
    }
    m.emission.intensity = 0;
    Lamp *lamp = [Lamp new];
    lamp.material = m;
    lamp.peak = legend ? 2.6f : 3.2f;
    _lamps[key] = lamp;
}

- (Display *)displayForScene:(SKScene *)scene {
    if (!scene) return nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                  width:(NSUInteger)scene.size.width
                                                                                 height:(NSUInteger)scene.size.height
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    Display *d = [Display new];
    d.scene = scene;
    d.texture = [_device newTextureWithDescriptor:td];
    d.renderer = [SKRenderer rendererWithDevice:_device];
    d.renderer.scene = scene;
    [_displays addObject:d];
    return d;
}

- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time {
    if (!queue || _node.hidden) return;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    cb.label = @"Cockpit displays";
    for (Display *d in _displays) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        [d.renderer updateAtTime:time];
        [d.renderer renderWithViewport:CGRectMake(0, 0, d.texture.width, d.texture.height) commandBuffer:cb renderPassDescriptor:rp];
    }
    [cb commit];   // same queue as SceneKit's frame, so it lands first
}

- (SKScene *)screenNamed:(NSString *)key {
    if ([key isEqualToString:@"Radar"]) return _radar;
    if ([key isEqualToString:@"Left"]) return _self;
    if ([key isEqualToString:@"Right"]) return _target;
    if ([key isEqualToString:@"Status"]) return _status;
    NSLog(@"Cockpit: unknown screen %@", key);
    return nil;
}

#pragma mark - Display layout

- (void)buildDisplays {
    [self buildRadar];
    [self buildSelf];
    [self buildTarget];
    [self buildStatus];
}

- (void)buildRadar {
    CGSize size = CGSizeMake(512, 512);
    _radar = MakeScreen(size, nil);
    _radarCentre = CGPointMake(256, 236);
    _radarRadius = CGSizeMake(226, 132);   // the scanner disc, seen at an angle

    // Range rings at 1/4, 1/2 and full range (square-root scale), plus the
    // forward cone and cross hairs.
    for (int i = 1; i <= 3; i++) {
        CGFloat k = sqrt(i == 3 ? 1.0 : i * 0.25);
        CGPathRef p = CGPathCreateWithEllipseInRect(CGRectMake(_radarCentre.x - _radarRadius.width * k, _radarCentre.y - _radarRadius.height * k,
                                                               _radarRadius.width * 2 * k, _radarRadius.height * 2 * k), NULL);
        [_radar addChild:Stroke(p, ScreenColor(i == 3 ? 0.6 : 0.28), i == 3 ? 3 : 2)];
        CGPathRelease(p);
    }
    CGMutablePathRef cross = CGPathCreateMutable();
    CGPathMoveToPoint(cross, NULL, _radarCentre.x - _radarRadius.width, _radarCentre.y);
    CGPathAddLineToPoint(cross, NULL, _radarCentre.x + _radarRadius.width, _radarCentre.y);
    CGPathMoveToPoint(cross, NULL, _radarCentre.x, _radarCentre.y - _radarRadius.height);
    CGPathAddLineToPoint(cross, NULL, _radarCentre.x, _radarCentre.y + _radarRadius.height);
    for (int s = -1; s <= 1; s += 2) {
        CGPathMoveToPoint(cross, NULL, _radarCentre.x, _radarCentre.y);
        CGPathAddLineToPoint(cross, NULL, _radarCentre.x + s * _radarRadius.width * 0.7, _radarCentre.y + _radarRadius.height * 0.7);
    }
    [_radar addChild:Stroke(cross, ScreenColor(0.18), 2)];
    CGPathRelease(cross);

    // Own ship marker.
    CGMutablePathRef me = CGPathCreateMutable();
    CGPathMoveToPoint(me, NULL, _radarCentre.x, _radarCentre.y + 12);
    CGPathAddLineToPoint(me, NULL, _radarCentre.x + 9, _radarCentre.y - 8);
    CGPathAddLineToPoint(me, NULL, _radarCentre.x - 9, _radarCentre.y - 8);
    CGPathCloseSubpath(me);
    SKShapeNode *meNode = Stroke(me, ScreenColor(0.95), 2);
    meNode.fillColor = ScreenColor(0.5);
    [_radar addChild:meNode];
    CGPathRelease(me);

    _blips = [NSMutableArray array];
    _stalks = [NSMutableArray array];
    for (int i = 0; i < COCKPIT_MAX_CONTACTS; i++) {
        SKShapeNode *stalk = [SKShapeNode node];
        stalk.strokeColor = EnemyColor(0.6);
        stalk.lineWidth = 2;
        [_radar addChild:stalk];
        [_stalks addObject:stalk];
        SKShapeNode *b = [SKShapeNode shapeNodeWithRect:CGRectMake(-7, -7, 14, 14)];
        b.strokeColor = EnemyColor(1);
        b.lineWidth = 3;
        [_radar addChild:b];
        [_blips addObject:b];
    }
    CGPathRef ring = CGPathCreateWithEllipseInRect(CGRectMake(-16, -16, 32, 32), NULL);
    _radarTargetMark = Stroke(ring, ScreenColor(1), 2.5);
    CGPathRelease(ring);
    [_radar addChild:_radarTargetMark];

    _radarRange = Text(22, SKLabelHorizontalAlignmentModeRight, ScreenColor(0.7));
    _radarRange.position = CGPointMake(496, 486);
    [_radar addChild:_radarRange];
    SKLabelNode *title = Text(22, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.7));
    title.text = @"SCANNER";
    title.position = CGPointMake(16, 486);
    [_radar addChild:title];
}

static SKLabelNode *Row(SKScene *s, NSString *name, CGFloat y, Bar * __strong *barOut, SKLabelNode * __strong *pctOut) {
    SKLabelNode *l = Text(22, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.75));
    l.text = name;
    l.position = CGPointMake(330, y + 18);
    [s addChild:l];
    SKLabelNode *pct = Text(22, SKLabelHorizontalAlignmentModeRight, ScreenColor(0.95));
    pct.position = CGPointMake(588, y + 18);
    [s addChild:pct];
    Bar *b = [[Bar alloc] initWithSize:CGSizeMake(258, 14)];
    b.position = CGPointMake(330, y - 4);
    [s addChild:b];
    *barOut = b;
    *pctOut = pct;
    return l;
}

- (void)buildSelf {
    CGSize size = CGSizeMake(608, 480);
    _self = MakeScreen(size, @"SHIP STATUS");

    _selfHolder = Hologram(ScreenColor(0.5), &_selfModel);
    SetHologramShip(_selfModel, ShipClassExecutioner);

    CGPathRef ring = CGPathCreateWithEllipseInRect(CGRectMake(-142, -128, 284, 256), NULL);
    _shieldRing = Stroke(ring, ShieldColor(0.9), 6);
    CGPathRelease(ring);
    _shieldRing.position = kHoloSpot;
    _shieldRing.glowWidth = 3;
    [_self addChild:_shieldRing];

    Row(_self, @"SHIELD", 378, &_shieldBar, &_shieldPct);
    Row(_self, @"HULL", 310, &_hullBar, &_hullPct);
    Row(_self, @"BOOST", 242, &_boostBar, &_boostPct);
    Row(_self, @"THROTTLE", 174, &_throttleBar, &_throttlePct);
    _shieldBar.fill.color = ShieldColor(0.95);
    _boostBar.fill.color = WarnColor(0.95);

    SKLabelNode *spd = Text(22, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.75));
    spd.text = @"SPEED";
    spd.position = CGPointMake(330, 118);
    [_self addChild:spd];
    _speedLabel = Text(52, SKLabelHorizontalAlignmentModeRight, ScreenColor(1));
    _speedLabel.position = CGPointMake(588, 70);
    [_self addChild:_speedLabel];
    SKLabelNode *unit = Text(20, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.6));
    unit.text = @"M/S";
    unit.position = CGPointMake(330, 62);
    [_self addChild:unit];

    _selfState = Text(22, SKLabelHorizontalAlignmentModeCenter, ScreenColor(0.85));
    _selfState.position = CGPointMake(160, 36);
    [_self addChild:_selfState];
}

- (void)buildTarget {
    CGSize size = CGSizeMake(608, 480);
    _target = MakeScreen(size, @"TARGET");

    _noTarget = Text(34, SKLabelHorizontalAlignmentModeCenter, ScreenColor(0.6));
    _noTarget.text = @"NO TARGET";
    _noTarget.position = CGPointMake(304, 220);
    [_target addChild:_noTarget];

    _targetInfo = [SKNode node];
    [_target addChild:_targetInfo];
    _targetHolder = Hologram(EnemyColor(0.55), &_targetModel);
    CGPathRef padPath = CGPathCreateWithEllipseInRect(CGRectMake(-120, -50, 240, 100), NULL);
    SKShapeNode *pad = Stroke(padPath, EnemyColor(0.35), 2);
    CGPathRelease(padPath);
    pad.position = CGPointMake(kHoloSpot.x, kHoloSpot.y - 90);
    [_targetInfo addChild:pad];

    _targetTeam = Text(22, SKLabelHorizontalAlignmentModeRight, EnemyColor(1));
    _targetTeam.position = CGPointMake(588, 450);
    [_targetInfo addChild:_targetTeam];

    _targetName = Text(24, SKLabelHorizontalAlignmentModeLeft, EnemyColor(1));
    _targetName.position = CGPointMake(330, 392);
    [_targetInfo addChild:_targetName];
    _targetClassLabel = Text(18, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.7));
    _targetClassLabel.position = CGPointMake(330, 366);
    [_targetInfo addChild:_targetClassLabel];
    _targetRange = Text(24, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.95));
    _targetRange.position = CGPointMake(330, 334);
    [_targetInfo addChild:_targetRange];
    _targetClosing = Text(24, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.95));
    _targetClosing.position = CGPointMake(330, 306);
    [_targetInfo addChild:_targetClosing];

    SKLabelNode *l = Row(_target, @"SHIELD", 238, &_targetShield, &_targetShieldPct);
    [l removeFromParent]; [_targetInfo addChild:l];
    l = Row(_target, @"HULL", 170, &_targetHull, &_targetHullPct);
    [l removeFromParent]; [_targetInfo addChild:l];
    for (SKNode *n in @[_targetShield, _targetShieldPct, _targetHull, _targetHullPct]) {
        [n removeFromParent];
        [_targetInfo addChild:n];
    }
    _targetShield.fill.color = ShieldColor(0.95);

    _targetMode = Text(24, SKLabelHorizontalAlignmentModeCenter, EnemyColor(1));
    _targetMode.position = CGPointMake(160, 40);
    [_targetInfo addChild:_targetMode];
}

- (void)buildStatus {
    CGSize size = CGSizeMake(440, 260);
    _status = MakeScreen(size, nil);
    _killsLabel = Text(28, SKLabelHorizontalAlignmentModeLeft, ScreenColor(0.95));
    _killsLabel.position = CGPointMake(20, 222);
    [_status addChild:_killsLabel];
    _deathsLabel = Text(20, SKLabelHorizontalAlignmentModeLeft, WarnColor(0.95));
    _deathsLabel.position = CGPointMake(20, 176);
    [_status addChild:_deathsLabel];
    _clockLabel = Text(30, SKLabelHorizontalAlignmentModeRight, ScreenColor(0.75));
    _clockLabel.position = CGPointMake(420, 220);
    [_status addChild:_clockLabel];
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, 16, 146);
    CGPathAddLineToPoint(p, NULL, 424, 146);
    [_status addChild:Stroke(p, ScreenColor(0.35), 2)];
    CGPathRelease(p);
    _messageLabel = Text(38, SKLabelHorizontalAlignmentModeCenter, ScreenColor(1));
    _messageLabel.position = CGPointMake(220, 80);
    [_status addChild:_messageLabel];
}

#pragma mark - Update

- (void)say:(NSString *)message warn:(BOOL)warn time:(double)t {
    _message = message;
    _messageWarn = warn;
    _messageUntil = t + 3.5;
}

- (void)setLamp:(NSString *)key level:(float)level {
    Lamp *l = _lamps[key];
    if (!l || fabsf(l.level - level) < 0.005f) return;
    l.level = level;
    l.material.emission.intensity = level * l.peak;
}

- (void)updateFrame:(CockpitFrame)f contacts:(const CockpitContact *)contacts count:(NSUInteger)count {
    double t = f.time;

    // Animated controls.
    _stick.eulerAngles = SCNVector3Make(f.pitch * 0.28f, -f.yaw * 0.2f, -f.roll * 0.3f);
    _throttle.position = SCNVector3Make(_throttleRest.x, _throttleRest.y, _throttleRest.z + 0.11f - 0.22f * f.throttle);

    // Events for the status display.
    if (f.kills > _last.kills) [self say:@"SPLASH ONE" warn:NO time:t];
    if (f.alive && f.shield < 0.02f && _last.shield >= 0.02f) [self say:@"SHIELDS DOWN" warn:YES time:t];
    if (f.alive && f.hull < 0.3f && _last.hull >= 0.3f) [self say:@"HULL CRITICAL" warn:YES time:t];
    if (!f.alive && _last.alive) [self say:@"SHIP LOST" warn:YES time:t];
    if (f.alive && !_last.alive && t > 1) [self say:@"SYSTEMS ONLINE" warn:NO time:t];
    if (f.six && !_last.six) [self say:@"CHECK SIX" warn:YES time:t];
    _last = f;

    [self updateLamps:f];
    [self updateRadar:f contacts:contacts count:count];
    [self updateSelf:f];
    [self updateTarget:f contacts:contacts count:count];
    [self updateStatus:f];
}

- (void)updateLamps:(CockpitFrame)f {
    double t = f.time;
    BOOL alive = f.alive;
    BOOL shieldLow = alive && f.shield < 0.3f;
    BOOL hullLow = alive && f.hull < 0.5f;
    BOOL prox = alive && f.nearest < 150.0f;
    BOOL caution = alive && (f.shield < 0.05f || f.hull < 0.3f || f.six || prox);

    [self setLamp:@"Caution" level:caution && Blink(t, 2.0) ? 1 : 0];
    [self setLamp:@"Shield" level:shieldLow ? (f.shield < 0.02f ? (Blink(t, 3) ? 1 : 0.15f) : 1) : 0];
    [self setLamp:@"Hull" level:hullLow ? (f.hull < 0.25f ? (Blink(t, 4) ? 1 : 0.15f) : 1) : 0];
    [self setLamp:@"Hit" level:alive ? clampf(f.damageFlash * 1.5f, 0, 1) : 0];
    [self setLamp:@"Six" level:alive && f.six ? (Blink(t, 3) ? 1 : 0.3f) : 0];
    [self setLamp:@"Lock" level:alive && f.lock ? 1 : 0];
    [self setLamp:@"Guns" level:alive && f.firing ? (Blink(t, 9) ? 1 : 0.45f) : 0];
    [self setLamp:@"Boost" level:alive ? (f.boosting ? 1 : (f.boostEnergy < 0.2f ? 0.25f : 0)) : 0];
    [self setLamp:@"Prox" level:prox ? 1 : 0];

    // Throttle ladder: ten LEDs, all of them pulse while boosting.
    float thr = alive ? f.throttle : 0;
    for (int i = 0; i < 10; i++) {
        float on = clampf(thr * 10.0f - i, 0, 1);
        if (alive && f.boosting) on = Blink(t, 6) ? 1 : 0.6f;
        [self setLamp:[NSString stringWithFormat:@"Thr%d", i] level:on];
    }
}

- (void)updateRadar:(CockpitFrame)f contacts:(const CockpitContact *)contacts count:(NSUInteger)count {
    const float range = 2000.0f;
    _radarRange.text = @"2.0 KM";
    _radarTargetMark.hidden = YES;
    for (NSUInteger i = 0; i < COCKPIT_MAX_CONTACTS; i++) {
        SKShapeNode *b = _blips[i], *s = _stalks[i];
        if (i >= count || !f.alive) { b.hidden = s.hidden = YES; continue; }
        CockpitContact c = contacts[i];
        // Square-root range scale keeps close contacts readable; forward
        // (-Z) is up on the disc, height is drawn as a stalk.
        float planar = simd_length(simd_make_float2(c.local.x, c.local.z));
        float d = simd_length(c.local);
        BOOL outside = d > range;
        float k = sqrtf(fminf(d, range) / range) / fmaxf(d, 1.0f);
        CGPoint base = CGPointMake(_radarCentre.x + c.local.x * k * _radarRadius.width,
                                   _radarCentre.y - c.local.z * k * _radarRadius.height);
        if (planar < 1e-3f) base = _radarCentre;
        CGPoint tip = CGPointMake(base.x, base.y + c.local.y * k * _radarRadius.height * 1.4f);
        CGMutablePathRef p = CGPathCreateMutable();
        CGPathMoveToPoint(p, NULL, base.x, base.y);
        CGPathAddLineToPoint(p, NULL, tip.x, tip.y);
        CGPathMoveToPoint(p, NULL, base.x - 5, base.y);
        CGPathAddLineToPoint(p, NULL, base.x + 5, base.y);
        s.path = p;
        CGPathRelease(p);
        s.hidden = NO;
        b.hidden = NO;
        b.position = tip;
        // Above the plane: filled; below: hollow. Attackers blink.
        BOOL above = c.local.y >= 0;
        CGFloat a = outside ? 0.45 : 1.0;
        if (c.attacking && !Blink(f.time, 2.5)) a *= 0.55;
        b.strokeColor = TeamColor(c.team, a);
        b.fillColor = above ? TeamColor(c.team, a * 0.8) : [NSColor clearColor];
        s.strokeColor = TeamColor(c.team, a * 0.6);
        b.xScale = b.yScale = c.capital ? 1.8 : 1.0;
        if ((int)i == f.target) {
            _radarTargetMark.hidden = NO;
            _radarTargetMark.position = tip;
        }
    }
}

- (void)updateSelf:(CockpitFrame)f {
    float shield = f.alive ? f.shield : 0, hull = f.alive ? f.hull : 0;
    _shieldBar.value = shield;
    _hullBar.value = hull;
    _boostBar.value = f.boostEnergy;
    _throttleBar.value = f.throttle;
    _hullBar.fill.color = LevelColor(hull, 0.95);
    _throttleBar.fill.color = f.boosting ? WarnColor(0.95) : ScreenColor(0.9);
    _shieldPct.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(shield * 100)];
    _hullPct.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(hull * 100)];
    _boostPct.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(f.boostEnergy * 100)];
    _throttlePct.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(f.throttle * 100)];
    _hullPct.fontColor = LevelColor(hull, 1);
    _speedLabel.text = [NSString stringWithFormat:@"%d", (int)lroundf(f.speed)];

    // Shield bubble around the silhouette fades and thins as it drains,
    // and flares on a hit.
    _shieldRing.alpha = shield > 0.02f ? 0.25 + 0.75 * shield : (Blink(f.time, 3) ? 0.25 : 0);
    _shieldRing.lineWidth = 2 + 6 * shield + 6 * f.damageFlash;
    _shieldRing.strokeColor = shield < 0.3f ? WarnColor(1) : ShieldColor(1);
    SCNMaterial *holo = [_selfModel valueForKey:@"holoMaterial"];
    holo.diffuse.contents = f.damageFlash > 0.05f ? EnemyColor(0.2 + 0.5 * f.damageFlash) : LevelColor(hull, 0.5);

    if (!f.alive) { _selfState.text = Blink(f.time, 1.5) ? @"SHIP LOST" : @""; _selfState.fontColor = EnemyColor(1); }
    else if (f.boosting) { _selfState.text = @"BOOST"; _selfState.fontColor = WarnColor(1); }
    else { _selfState.text = @"NOMINAL"; _selfState.fontColor = ScreenColor(0.7); }
}

- (void)updateTarget:(CockpitFrame)f contacts:(const CockpitContact *)contacts count:(NSUInteger)count {
    BOOL has = f.alive && f.target >= 0 && f.target < (int)count;
    _targetInfo.hidden = !has;
    _targetHolder.hidden = !has;
    _noTarget.hidden = has;
    _noTarget.alpha = Blink(f.time, 1) ? 0.8 : 0.35;
    if (!has) return;
    CockpitContact c = contacts[f.target];
    if (c.geometry != _targetGeometry) {
        _targetGeometry = c.geometry;
        BOOL fighter = !c.capital && fabsf(c.holoScale - 0.0075f) < 1e-5f;
        // The mount is scaled for fighters (0.0075); scale relative to it.
        SetHologramGeometry(_targetModel, c.geometry, c.holoScale / 0.0075f, fighter);
    }
    NSString *name = [c.name uppercaseString] ?: @"";
    if (name.length > 17) name = [name substringToIndex:17];
    _targetName.text = name;
    _targetClassLabel.text = [c.className uppercaseString];
    _targetName.fontColor = TeamColor(c.team, 1);
    _targetTeam.text = c.team == TeamEnemy ? @"HOSTILE" : (c.team == TeamFriend ? @"FRIENDLY" : @"NEUTRAL");
    _targetTeam.fontColor = TeamColor(c.team, 1);
    ((SCNMaterial *)[_targetModel valueForKey:@"holoMaterial"]).diffuse.contents = TeamColor(c.team, 0.55);
    // The hologram shows the target's attitude as seen from our cockpit.
    _targetHolder.simdOrientation = c.orientation;
    float d = simd_length(c.local);
    _targetRange.text = d >= 1000 ? [NSString stringWithFormat:@"RNG %5.2f KM", d / 1000.0f]
                                  : [NSString stringWithFormat:@"RNG %5d M", (int)d];
    _targetClosing.text = [NSString stringWithFormat:@"CLS %+5d M/S", (int)lroundf(f.closingSpeed)];
    _targetShield.value = c.shield;
    _targetHull.value = c.hull;
    _targetHull.fill.color = LevelColor(c.hull, 0.95);
    _targetShieldPct.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(c.shield * 100)];
    _targetHullPct.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(c.hull * 100)];
    if (f.lock) { _targetMode.text = Blink(f.time, 4) ? @"[ LOCK ]" : @"  LOCK  "; _targetMode.fontColor = [NSColor colorWithRed:0.3 green:1 blue:0.45 alpha:1]; }
    else if (c.capital) { _targetMode.text = c.shielded ? @"SHIELDED" : @"VULNERABLE"; _targetMode.fontColor = c.shielded ? ShieldColor(1) : WarnColor(1); }
    else if (c.attacking) { _targetMode.text = @"ATTACKING"; _targetMode.fontColor = EnemyColor(1); }
    else if (c.team != TeamEnemy) { _targetMode.text = @""; }
    else { _targetMode.text = @"EVADING"; _targetMode.fontColor = WarnColor(1); }
}

- (void)updateStatus:(CockpitFrame)f {
    _killsLabel.text = [NSString stringWithFormat:@"KILLS %d  TORP %d", f.kills, f.torpedoes];
    NSString *obj = [f.objective uppercaseString] ?: @"";
    if (obj.length > 30) obj = [[obj substringToIndex:29] stringByAppendingString:@"."];
    _deathsLabel.text = obj;
    int secs = (int)f.time;
    _clockLabel.text = [NSString stringWithFormat:@"%02d:%02d", secs / 60, secs % 60];
    BOOL show = _message && f.time < _messageUntil;
    _messageLabel.text = show ? _message : @"";
    _messageLabel.fontColor = _messageWarn ? WarnColor(1) : ScreenColor(1);
    _messageLabel.alpha = show && _messageWarn && !Blink(f.time, 3) ? 0.4 : 1;
}

@end
