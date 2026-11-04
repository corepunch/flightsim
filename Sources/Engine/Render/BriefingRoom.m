#import "BriefingRoom.h"
#import <simd/simd.h>
#import "SceneAsset.h"
#import "SpaceSky.h"
#import "StencilShadows.h"

// Light categories: the hall's lamps stay inside, the star lights the
// cruiser outside the window.
enum { kInside = 1 << 1, kOutside = 1 << 2 };

typedef struct { simd_float3 eye, at; float fov; } Pose;

static Pose PoseMix(Pose a, Pose b, float t) {
    return (Pose){ simd_mix(a.eye, b.eye, t), simd_mix(a.at, b.at, t), a.fov + (b.fov - a.fov) * t };
}

static simd_float3 Vec(NSArray *a) {
    return simd_make_float3([a[0] floatValue], [a[1] floatValue], [a[2] floatValue]);
}

static NSURL *TextureURL(NSString *name) {
    return [[NSBundle mainBundle] URLForResource:name withExtension:@"jpg" subdirectory:@"Textures"]
        ?: [[NSBundle mainBundle] URLForResource:name withExtension:@"png" subdirectory:@"Textures"];
}

static NSColor *RGB(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithRed:r green:g blue:b alpha:1];
}

// Lit trim. `set` names a tiling texture set in Resources/Textures; its
// colour map is tinted, and `scale` stretches it (the room's UVs run one
// unit per 4 m; the hull sets were drawn for ~40 m tiles).
static void Dress(SCNMaterial *m, NSString *set, NSColor *tint, float rough, float metal, float scale) {
    m.lightingModelName = SCNLightingModelPhysicallyBased;
    m.emission.contents = [NSColor blackColor];
    m.ambientOcclusion.contents = nil;
    m.specular.contents = nil;
    NSMutableArray<SCNMaterialProperty *> *props = [NSMutableArray array];
    if (set) {
        m.diffuse.contents = TextureURL([set stringByAppendingString:@"_color"]);
        m.multiply.contents = tint;
        m.normal.contents = TextureURL([set stringByAppendingString:@"_normal"]);
        m.normal.intensity = 0.3;
        m.roughness.contents = TextureURL([set stringByAppendingString:@"_rough"]);
        m.roughness.intensity = rough * 2;
        m.metalness.contents = @(metal);
        [props addObjectsFromArray:@[m.diffuse, m.normal, m.roughness]];
    } else {
        m.diffuse.contents = tint;
        m.multiply.contents = [NSColor whiteColor];
        m.roughness.contents = @(rough);
        m.metalness.contents = @(metal);
    }
    for (SCNMaterialProperty *p in props) {
        p.wrapS = p.wrapT = SCNWrapModeRepeat;
        p.mipFilter = SCNFilterModeLinear;
        p.maxAnisotropy = 8;
        p.contentsTransform = SCNMatrix4MakeScale(scale, scale, 1);
    }
}

// The tech interior sets (Art/build_hull_textures.py: techwall, techfloor,
// techtrim, techgrate) carry their own albedo; one tile is 4 m, like the
// room's UVs, and their relief is meant to be seen at full strength.
static void Tech(SCNMaterial *m, NSString *set, float tint, float scale) {
    Dress(m, set, RGB(tint, tint, tint), 0.5, 0.65, scale);
    m.normal.intensity = 1.0;
    m.metalness.contents = TextureURL([set stringByAppendingString:@"_metal"]);
    m.metalness.wrapS = m.metalness.wrapT = SCNWrapModeRepeat;
    m.metalness.contentsTransform = SCNMatrix4MakeScale(scale, scale, 1);
}

static void Glow(SCNMaterial *m, NSColor *c, float intensity) {
    m.lightingModelName = SCNLightingModelConstant;
    m.diffuse.contents = c;
    m.diffuse.intensity = intensity;   // > 1: blooms
    m.emission.contents = [NSColor blackColor];
}


// Lamp light to crowd-sprite brightness: a seated row under an audience
// downlight comes out about as bright as the sprites were unlit.
#define SPRITE_GAIN 0.05f

@implementation BriefingRoom {
    id<MTLDevice> _device;
    SKRenderer *_renderer;
    id<MTLTexture> _screenTexture;
    SpaceSky *_sky;
    NSDictionary<NSString *, NSData *> *_shots;   // name -> Pose
    simd_float3 _screenMin, _screenMax;
    Pose _from, _pose;
    double _moveStart, _moveSeconds, _now;
    BOOL _moving;
    float _leanNow;
    CGFloat _aspect;
    NSMutableDictionary<NSString *, NSImage *> *_sprites;
    NSArray<NSDictionary *> *_lamps;   // the fixtures in BriefingRoom.json
    StencilShadows *_shadows;   // nil: the hall's lamps are plain SCNLights, no shadows
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        _aspect = 16.0 / 9.0;
        _sprites = [NSMutableDictionary dictionary];
        _scene = [SCNScene scene];
        [self loadLayout];
        [self buildPresentation];
        [self buildCamera];
        // SF_STENCIL=0: SceneKit's own lamps; =lit: ours, never shadowed.
        const char *stencil = getenv("SF_STENCIL");
        if (!stencil || strcmp(stencil, "0")) {
            _shadows = [[StencilShadows alloc] initWithDevice:device];
            _shadows.disabled = stencil && !strcmp(stencil, "lit");
        }
        [self buildLights];
        [self buildRoom];
        [_shadows finish];
        _sky = [[SpaceSky alloc] initWithDevice:device faceSize:1024 seed:4242];
        _scene.background.contents = _sky.cubeTexture;
        _scene.lightingEnvironment.contents = _sky.cubeTexture;
        _scene.lightingEnvironment.intensity = _shadows ? 0.03 : 0.25;   // a hint of reflection, no fill
        [self cutTo:RoomShotWide];
    }
    return self;
}

#pragma mark - Building

- (void)loadLayout {
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"BriefingRoom" withExtension:@"json" subdirectory:@"Briefing"];
    NSDictionary *d = url ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:nil] : nil;
    NSMutableDictionary *shots = [NSMutableDictionary dictionary];
    [d[@"shots"] enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSDictionary *s, BOOL *stop) {
        Pose p = { Vec(s[@"eye"]), Vec(s[@"at"]), [s[@"fov"] floatValue] };
        shots[name] = [NSData dataWithBytes:&p length:sizeof p];
    }];
    _shots = shots;
    _lamps = d[@"lamps"];
    _screenMin = d ? Vec(d[@"screen"][@"min"]) : simd_make_float3(-8, 4.4, -11.9);
    _screenMax = d ? Vec(d[@"screen"][@"max"]) : simd_make_float3(8, 11.4, -11.9);
    if (!d) NSLog(@"BriefingRoom: BriefingRoom.json missing");
}

- (void)buildPresentation {
    _presentation = [SKScene sceneWithSize:CGSizeMake(1120, 490)];
    _presentation.scaleMode = SKSceneScaleModeFill;
    _presentation.backgroundColor = RGB(0.0, 0.035, 0.045);
    // Rendered at twice its point size, so the text holds up close.
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                  width:2240 height:980 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    _screenTexture = [_device newTextureWithDescriptor:td];
    _renderer = [SKRenderer rendererWithDevice:_device];
    _renderer.scene = _presentation;
}

- (void)buildCamera {
    SCNCamera *cam = [SCNCamera camera];
    cam.zNear = 0.1;
    cam.zFar = 3000;
    cam.wantsHDR = YES;
    cam.wantsExposureAdaptation = NO;
    cam.bloomIntensity = 1.1;
    cam.bloomThreshold = 0.85;
    cam.bloomBlurRadius = 14;
    cam.bloomIterationCount = 2;
    cam.bloomIterationSpread = 1.0;
    cam.vignettingIntensity = 0.8;
    cam.vignettingPower = 1.0;
    cam.saturation = 1.05;
    cam.contrast = 0.08;
    cam.categoryBitMask = ~0u;
    _cameraNode = [SCNNode node];
    _cameraNode.name = @"RoomCamera";
    _cameraNode.camera = cam;
    [_scene.rootNode addChildNode:_cameraNode];
}

- (void)buildRoom {
    NSArray<SCNNode *> *nodes = SceneAssetNodes(@"BriefingRoom", @"Models");
    if (!nodes.count) NSLog(@"BriefingRoom: model missing");
    NSMutableDictionary<NSString *, SCNMaterial *> *shared = [NSMutableDictionary dictionary];
    for (SCNNode *n in nodes) {
        BOOL outside = [n.name isEqualToString:@"Outside"];
        [n enumerateHierarchyUsingBlock:^(SCNNode *c, BOOL *stop) { c.categoryBitMask = outside ? kOutside : kInside; }];
        NSMutableArray *mats = [NSMutableArray array];
        for (SCNMaterial *m in n.geometry.materials) {
            NSString *name = m.name ?: @"";
            // Same name, same material: one draw state per kind.
            NSString *key = outside ? [@"Outside/" stringByAppendingString:name] : name;
            SCNMaterial *s = shared[key];
            if (!s) {
                s = m;
                [self dress:s outside:outside];
                if (_shadows && !outside && [s.lightingModelName isEqualToString:SCNLightingModelPhysicallyBased])
                    [_shadows applyToMaterial:s tint:[s.multiply.contents isKindOfClass:[NSColor class]] ? s.multiply.contents : nil];
                shared[key] = s;
            }
            [mats addObject:s];
        }
        n.geometry.materials = mats;
        n.castsShadow = NO;
        [_scene.rootNode addChildNode:n];
        if (_shadows && [n.name isEqualToString:@"Room"]) {
            // Glows are the lamps themselves; the screen and sprites let light by.
            NSArray *skip = @[@"Sprite_", @"Glow_", @"Screen_"];
            [_shadows addReceiver:n skip:@[@"Sprite_"]];
            [_shadows addCaster:n skip:skip];
        }
    }
}

- (void)dress:(SCNMaterial *)m outside:(BOOL)outside {
    NSString *n = m.name ?: @"";
    if ([n hasPrefix:@"Sprite_"]) { [self dressSprite:m]; return; }
    if ([n isEqualToString:@"Screen_Briefing"]) {
        m.lightingModelName = SCNLightingModelConstant;
        m.diffuse.contents = _screenTexture;
        m.diffuse.intensity = 1.15;
        m.diffuse.mipFilter = SCNFilterModeNone;
        m.emission.contents = [NSColor blackColor];
        return;
    }
    if ([n isEqualToString:@"Glow_Lamp"])  { Glow(m, RGB(0.9, 0.95, 1.0), 3.0); return; }   // a fixture's lens
    if ([n isEqualToString:@"Duct"])     { Dress(m, nil, RGB(0.3, 0.24, 0.1), 0.7, 0.1, 1); return; }
    if ([n isEqualToString:@"Glow_Amber"]) { Glow(m, RGB(1.0, 0.58, 0.24), outside ? 2.0 : 2.2); return; }
    if ([n isEqualToString:@"Glow_AmberDim"]) { Glow(m, RGB(1.0, 0.58, 0.24), 0.55); return; }   // every other fixture: lit, no bloom
    if ([n isEqualToString:@"Glow_Warm"])  { Glow(m, RGB(1.0, 0.82, 0.6), outside ? 1.6 : 1.5); return; }
    if ([n isEqualToString:@"Glow_Cyan"])  { Glow(m, RGB(0.25, 0.85, 1.0), 1.15); return; }
    if ([n isEqualToString:@"Glow_Red"])   { Glow(m, RGB(1.0, 0.18, 0.12), 2.4); return; }
    if (_shadows && !outside) {
        // Doom 3 style: big calm modules, tiles and grating under hard light.
        if ([n isEqualToString:@"Wall"])     { Tech(m, @"techwall", 0.5, 1); return; }
        if ([n isEqualToString:@"WallDark"]) { Tech(m, @"techwall", 0.28, 1); return; }
        if ([n isEqualToString:@"Panel"])    { Tech(m, @"techtrim", 0.5, 1); return; }
        if ([n isEqualToString:@"Floor"])    { Tech(m, @"techfloor", 0.45, 1); return; }
        if ([n isEqualToString:@"Stage"])    { Tech(m, @"techgrate", 0.5, 1); return; }
        if ([n isEqualToString:@"Grate"])    { Tech(m, @"techgrate", 0.3, 1); return; }
        if ([n isEqualToString:@"Metal"])    { Tech(m, @"techtrim", 0.45, 2); return; }
        if ([n isEqualToString:@"Dark"])     { Tech(m, @"techtrim", 0.18, 2); return; }
    }
    if ([n isEqualToString:@"Wall"])     { Dress(m, @"bulkhead", RGB(0.2, 0.205, 0.215), 0.45, 0.45, 0.25); return; }
    if ([n isEqualToString:@"WallDark"]) { Dress(m, @"bulkhead", RGB(0.075, 0.078, 0.085), 0.55, 0.35, 0.12); return; }
    if ([n isEqualToString:@"Panel"])    { Dress(m, @"bulkhead", RGB(0.3, 0.3, 0.31), 0.35, 0.55, 0.5); return; }
    if ([n isEqualToString:@"Floor"])    { Dress(m, @"industrial", RGB(0.2, 0.21, 0.24), 0.3, 0.6, 0.5); return; }
    if ([n isEqualToString:@"Stage"])    { Dress(m, @"plating", RGB(0.16, 0.18, 0.21), 0.18, 0.7, 0.3); return; }
    if ([n isEqualToString:@"Hull"])     { Dress(m, @"armor", RGB(0.5, 0.52, 0.56), 0.5, 0.5, 1.0); return; }
    if ([n isEqualToString:@"HullDark"]) { Dress(m, @"armor", RGB(0.2, 0.21, 0.24), 0.5, 0.5, 1.0); return; }
    if ([n isEqualToString:@"Metal"])    { Dress(m, nil, RGB(0.32, 0.31, 0.3), 0.35, 0.85, 1); return; }
    if ([n isEqualToString:@"Dark"])     { Dress(m, nil, RGB(0.025, 0.027, 0.03), 0.55, 0.3, 1); return; }
    if ([n isEqualToString:@"Seat"])     { Dress(m, nil, RGB(0.045, 0.045, 0.05), 0.75, 0.05, 1); return; }
    if ([n isEqualToString:@"Rail"])     { Dress(m, nil, RGB(0.62, 0.45, 0.25), 0.3, 1.0, 1); return; }
    if ([n isEqualToString:@"Gold"])     { Dress(m, nil, RGB(0.85, 0.62, 0.28), 0.3, 1.0, 1); return; }
    if ([n isEqualToString:@"Banner"])   { Dress(m, nil, RGB(0.32, 0.035, 0.045), 0.85, 0.0, 1); m.doubleSided = YES; return; }
    if ([n isEqualToString:@"Grate"])    { Dress(m, nil, RGB(0.03, 0.033, 0.036), 0.5, 0.6, 1); return; }
    if ([n isEqualToString:@"Bezel"])    { Dress(m, nil, RGB(0.015, 0.017, 0.02), 0.3, 0.4, 1); return; }
    NSLog(@"BriefingRoom: unknown material %@", n);
    Dress(m, nil, RGB(0.2, 0.2, 0.2), 0.5, 0.2, 1);
}

// Sprite_<Kind>_<n> -> Resources/Briefing/Crowd/<Kind>_<n>.png. Cut out by
// alpha (so it sorts with depth like geometry); hidden if there's no image.
- (void)dressSprite:(SCNMaterial *)m {
    NSString *file = [m.name substringFromIndex:7];
    NSURL *url = [[NSBundle mainBundle] URLForResource:file withExtension:@"png" subdirectory:@"Briefing/Crowd"];
    NSImage *image = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    m.lightingModelName = SCNLightingModelConstant;
    m.emission.contents = [NSColor blackColor];
    if (!image) {
        m.colorBufferWriteMask = SCNColorMaskNone;
        m.writesToDepthBuffer = NO;
        return;
    }
    m.diffuse.contents = image;
    m.diffuse.wrapS = m.diffuse.wrapT = SCNWrapModeClamp;
    m.diffuse.mipFilter = SCNFilterModeLinear;
    m.diffuse.intensity = 0.9;
    m.doubleSided = NO;
    m.blendMode = SCNBlendModeReplace;
    m.shaderModifiers = @{ SCNShaderModifierEntryPointFragment: @"if (_output.color.a < 0.5) discard_fragment();" };
    if (_shadows) [_shadows applyToSprite:m gain:SPRITE_GAIN];   // in the lamps' pools, black outside them
}

- (void)buildLights {
    void (^omni)(simd_float3, NSColor *, CGFloat, CGFloat) = ^(simd_float3 p, NSColor *c, CGFloat lumens, CGFloat reach) {
        if (self->_shadows) { [self->_shadows addLight:p color:c intensity:(float)lumens reach:(float)reach]; return; }
        SCNLight *l = [SCNLight light];
        l.type = SCNLightTypeOmni;
        l.color = c;
        l.intensity = lumens;
        l.attenuationStartDistance = 0;
        l.attenuationEndDistance = reach;
        l.attenuationFalloffExponent = 2;
        l.categoryBitMask = kInside;
        SCNNode *n = [SCNNode node];
        n.light = l;
        n.simdPosition = p;
        [self->_scene.rootNode addChildNode:n];
    };
    SCNLight *ambient = [SCNLight light];
    ambient.type = SCNLightTypeAmbient;
    ambient.color = RGB(0.5, 0.55, 0.7);
    // With hard shadows the fill comes down, so they read (Doom 3's contrast).
    ambient.intensity = _shadows ? 0 : 70;   // Doom 3: no fill; what no lamp reaches is black
    ambient.categoryBitMask = kInside;
    SCNNode *an = [SCNNode node];
    an.light = ambient;
    [_scene.rootNode addChildNode:an];

    NSColor *warm = RGB(1.0, 0.78, 0.55), *amber = RGB(1.0, 0.62, 0.32), *cyan = RGB(0.35, 0.75, 1.0);
    if (_shadows) {
        [self buildDoom3Lights];
    } else {
        omni(simd_make_float3(-6, 12.5, 4), warm, 1300, 22);       // ceiling, over the audience
        omni(simd_make_float3(6, 12.5, 4), warm, 1300, 22);
        omni(simd_make_float3(0, 12.0, -6), warm, 900, 18);        // ceiling, over the stage
        omni(simd_make_float3(0, 7.9, -8.5), cyan, 650, 14);      // the screen's spill
        omni(simd_make_float3(-12.5, 3.2, 0), amber, 700, 11);     // under the balconies
        omni(simd_make_float3(12.5, 3.2, 0), amber, 700, 11);
        omni(simd_make_float3(-12.5, 7.6, 2), amber, 550, 10);     // between the tiers
        omni(simd_make_float3(12.5, 7.6, 2), amber, 550, 10);
    }

    SCNLight *star = [SCNLight light];
    star.type = SCNLightTypeDirectional;
    star.color = RGB(1.0, 0.95, 0.88);
    star.intensity = 1800;
    star.categoryBitMask = kOutside;
    SCNNode *sn = [SCNNode node];
    sn.light = star;
    sn.simdOrientation = simd_quaternion(simd_make_float3(0, 0, -1), simd_normalize(simd_make_float3(0.6, -0.4, -0.7)));
    [_scene.rootNode addChildNode:sn];
}

// Under stencil shadows: Doom 3's rig. No fill at all; a spot at each
// fixture the room was built with (BriefingRoom.json "lamps"), aimed where
// the light is wanted, each a pool with hard shadows and black between.
- (void)buildDoom3Lights {
    NSColor *white = RGB(0.86, 0.94, 1.0), *amber = RGB(1.0, 0.66, 0.38);
    // kind -> colour, lumens (as an SCNLight's), reach
    NSDictionary *rig = @{ @"audience": @[white, @7000, @20], @"stage": @[white, @6000, @18],
                           @"foot": @[white, @1500, @15], @"low": @[amber, @2400, @11], @"tier": @[white, @2200, @11],
                           @"upper": @[white, @2600, @12] };
    for (NSDictionary *l in _lamps) {
        NSArray *r = rig[l[@"kind"]];
        if (!r) { NSLog(@"BriefingRoom: unknown lamp kind %@", l[@"kind"]); continue; }
        [_shadows addLight:Vec(l[@"at"]) color:r[0] intensity:[r[1] floatValue] reach:[r[2] floatValue]
                 direction:Vec(l[@"aim"]) cone:[l[@"cone"] floatValue]];
    }
    // The screen is lit too: its spill on the stage and the front wall.
    [_shadows addLight:simd_make_float3(0, 7.9f, -8.5f) color:RGB(0.35, 0.75, 1.0) intensity:450 reach:10];
}

- (NSArray *)warmupObjects { return @[_scene]; }

#pragma mark - Camera

- (Pose)poseFor:(RoomShot)shot {
    NSString *key = shot == RoomShotEnter ? @"enter" : @"wide";
    Pose p = { simd_make_float3(0, 4, 14.6), simd_make_float3(0, 6.6, -12), 50 };
    if (_shots[key].length == sizeof p) memcpy(&p, _shots[key].bytes, sizeof p);
    if (shot != RoomShotTactical) return p;
    // The screen on the right ~55% of the frame, square on, whatever the
    // window's shape; the briefing text sits over the room on the left.
    float fov = 36, t = tanf(fov * 0.5f * (float)M_PI / 180), a = (float)MAX(_aspect, 1.0);
    float w = _screenMax.x - _screenMin.x;
    float d = fminf(w / (1.08f * t * a), 26.5f);
    simd_float3 mid = (_screenMin + _screenMax) * 0.5f;
    simd_float3 eye = simd_make_float3(mid.x - 0.4f * d * t * a, mid.y - 0.4f, mid.z + d);
    return (Pose){ eye, eye + simd_make_float3(0, 0, -d), fov };
}

- (void)cutTo:(RoomShot)shot {
    _shot = shot;
    _moving = NO;
    _pose = [self poseFor:shot];
}

- (void)moveTo:(RoomShot)shot seconds:(double)seconds {
    if (shot == _shot && !_moving) return;
    _from = _pose;
    _shot = shot;
    _moving = YES;
    _moveStart = NAN;   // starts on the next update
    _moveSeconds = MAX(seconds, 0.01);
}

- (void)updateAtTime:(double)time aspect:(CGFloat)aspect {
    double dt = MIN(MAX(time - _now, 0), 0.1);
    _now = time;
    _aspect = aspect;
    Pose target = [self poseFor:_shot];
    if (_moving) {
        if (isnan(_moveStart)) _moveStart = _now;
        float t = (float)MIN((_now - _moveStart) / _moveSeconds, 1.0);
        float e = t * t * t * (t * (t * 6 - 15) + 10);   // smootherstep
        _pose = PoseMix(_from, target, e);
        if (t >= 1) _moving = NO;
    } else {
        _pose = target;
    }
    // Lean toward whoever is talking, and a slow handheld drift; both
    // quieter on the tactical shot, where the screen has to read.
    float k = 1 - expf(-(float)dt * 1.5f);
    _leanNow += (_lean - _leanNow) * k;
    float calm = _shot == RoomShotTactical ? 0.25f : 1.0f;
    float tt = (float)time;
    simd_float3 drift = simd_make_float3(0.30f * sinf(tt * 0.11f) + 0.12f * sinf(tt * 0.29f + 1),
                                         0.10f * sinf(tt * 0.17f + 2), 0.20f * sinf(tt * 0.07f)) * calm;
    simd_float3 look = simd_make_float3(0.25f * sinf(tt * 0.09f + 3), 0.10f * sinf(tt * 0.13f), 0) * calm;
    simd_float3 eye = _pose.eye + drift + simd_make_float3(_leanNow * 0.9f * calm, 0, 0);
    simd_float3 at = _pose.at + look + simd_make_float3(_leanNow * 1.6f * calm, 0, 0);
    _cameraNode.simdPosition = eye;
    [_cameraNode simdLookAt:at up:simd_make_float3(0, 1, 0) localFront:simd_make_float3(0, 0, -1)];
    _cameraNode.camera.fieldOfView = _pose.fov;
    _cameraNode.camera.projectionDirection = SCNCameraProjectionDirectionVertical;
}

- (void)renderShadowsWithRenderer:(id<SCNSceneRenderer>)renderer {
    [_shadows renderWithRenderer:renderer camera:_cameraNode];
}

- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time {
    if (!queue) return;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    cb.label = @"Briefing screen";
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = _screenTexture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    [_renderer updateAtTime:time];
    [_renderer renderWithViewport:CGRectMake(0, 0, _screenTexture.width, _screenTexture.height)
                    commandBuffer:cb renderPassDescriptor:rp];
    [cb commit];
}

@end
