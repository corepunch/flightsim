#import "SceneKitRefresh.h"
#import "ShipView.h"
#import "CapitalView.h"
#import "SpaceSky.h"
#import "Effects.h"
#import "Cockpit.h"
#import "Assets.h"

static const NSUInteger kSkyFaceSize = TARGET_OS_IOS ? 1024 : 1536;

typedef NS_ENUM(int, RefModelKind) { RefKindNone, RefKindShip, RefKindCapital, RefKindProjectile };

// A registered model: what its name says and the prototype that keeps it on the GPU.
@interface RefModelEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) RefModelKind kind;
@property (nonatomic) const ShipDef *ship;
@property (nonatomic) const ProjectileDef *projectile;
@property (nonatomic, copy) NSString *asset, *style;
@property (nonatomic, strong) ModelInfo *info;
@property (nonatomic, strong) SCNNode *prototype;
@end
@implementation RefModelEntry
@end

// The nodes drawing one entity.
@interface RefEntityNode : NSObject
@property (nonatomic) RefModel model;
@property (nonatomic) uint8_t kind;
@property (nonatomic, strong) SCNNode *node;
@property (nonatomic, strong) ShipView *ship;
@property (nonatomic, strong) CapitalView *capital;
@property (nonatomic) BOOL seen;
@end
@implementation RefEntityNode
@end

@implementation SceneKitRefresh {
    __weak id<SCNSceneRenderer> _renderer;
    CGSize _size;
    id<MTLDevice> _device;

    NSMutableArray<RefModelEntry *> *_models;          // handle - 1
    NSMutableDictionary<NSString *, NSNumber *> *_handles;
    NSMutableArray *_pending;                           // built, not yet uploaded

    SpaceSky *_sky, *_nextSky;
    SCNNode *_sunLight, *_engineLight, *_dust, *_nextDust, *_world;
    Effects *_fx;
    Cockpit *_cockpit;
    SCNNode *_boltNodes[REF_MAX_BOLTS];

    NSMutableDictionary<NSNumber *, RefEntityNode *> *_entities;

    SCNNode *_playerNode;
    ShipView *_playerView;
    RefModel _playerModel;
    uint16_t _playerKey;
    BOOL _playerShown;

    double _time;
    float _dt;
}

- (instancetype)initWithRenderer:(id<SCNSceneRenderer>)renderer size:(CGSize)size {
    if ((self = [super init])) {
        _renderer = renderer;
        _size = size;
        _device = renderer.device ?: MTLCreateSystemDefaultDevice();
        _models = [NSMutableArray array];
        _handles = [NSMutableDictionary dictionary];
        _pending = [NSMutableArray array];
        _entities = [NSMutableDictionary dictionary];
        _dt = 1.0f / 60.0f;
    }
    return self;
}

- (CGSize)viewSize {
    id<SCNSceneRenderer> r = _renderer;
#if TARGET_OS_IOS
    if ([(id)r isKindOfClass:UIView.class]) return ((UIView *)r).bounds.size;
#else
    if ([(id)r isKindOfClass:NSView.class]) return ((NSView *)r).bounds.size;
#endif
    return _size;
}

- (simd_float3)sunDirection { return _sky.sunDirection; }

#pragma mark - World

- (SCNNode *)makeCamera:(BOOL)studio {
    SCNCamera *cam = [SCNCamera camera];
    cam.fieldOfView = studio ? 60 : 70;
    cam.zNear = 0.3;
    cam.zFar = studio ? 5000 : 40000;
    cam.wantsHDR = YES;
    cam.wantsExposureAdaptation = NO;
    cam.exposureOffset = 0.0;
    // Screen-space bloom does the glow work: emitters write HDR values > 1.
    cam.bloomIntensity = 1.35;
    cam.bloomThreshold = 0.9;
    cam.bloomBlurRadius = 18;
    if (!studio) {
        cam.bloomIterationCount = 2;
        cam.bloomIterationSpread = 1.0;
        cam.vignettingIntensity = 0.7;
        cam.vignettingPower = 0.9;
        cam.colorFringeStrength = 0.5;
        cam.colorFringeIntensity = 0.6;
        cam.saturation = 1.08;
        cam.contrast = 0.05;
    }
    SCNNode *n = [SCNNode node];
    n.camera = cam;
    return n;
}

// Effects, the bolt pool and the player's rig: shared by the game and the studio.
- (void)buildCommon:(BOOL)studio {
    _cameraNode = [self makeCamera:studio];
    [_scene.rootNode addChildNode:_cameraNode];

    _playerNode = [SCNNode node];
    _playerNode.name = @"Player";
    _playerNode.hidden = YES;
    [_scene.rootNode addChildNode:_playerNode];

    SCNLight *glow = [SCNLight light];
    glow.type = SCNLightTypeOmni;
    glow.color = [SKColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1];
    glow.attenuationStartDistance = 0;
    glow.attenuationEndDistance = 18;
    glow.intensity = 0;
    _engineLight = [SCNNode node];
    _engineLight.light = glow;
    _engineLight.position = SCNVector3Make(0, 0.5, 6.0);
    [_playerNode addChildNode:_engineLight];

    _fx = [[Effects alloc] initWithScene:_scene];
    for (int i = 0; i < REF_MAX_BOLTS; i++) {
        SCNNode *n = [_fx makeBoltNode];
        n.hidden = YES;
        [_scene.rootNode addChildNode:n];
        _boltNodes[i] = n;
    }
    _world = [SCNNode node];
    _world.name = @"World";
    [_scene.rootNode addChildNode:_world];
    [_pending addObject:_scene];
    [_pending addObjectsFromArray:[_fx warmupNodes]];
}

- (void)buildWorld {
    [SCNTransaction begin];
    [SCNTransaction setDisableActions:YES];
    _scene = [SCNScene scene];
    [self applySky:[[SpaceSky alloc] initWithDevice:_device faceSize:kSkyFaceSize seed:1337] dust:nil];

    SCNLight *sun = [SCNLight light];
    sun.type = SCNLightTypeDirectional;
    sun.color = [SKColor colorWithRed:1.0 green:0.94 blue:0.86 alpha:1];
    sun.intensity = 2600;
    sun.castsShadow = YES;
    sun.shadowMapSize = CGSizeMake(2048, 2048);
    sun.shadowSampleCount = 8;
    sun.shadowRadius = 2;
    sun.orthographicScale = 40;
    sun.zNear = 1;
    sun.zFar = 600;
    sun.shadowColor = [SKColor colorWithWhite:0 alpha:0.85];
    _sunLight = [SCNNode node];
    _sunLight.light = sun;
    [_scene.rootNode addChildNode:_sunLight];

    [self buildCommon:NO];

    _cockpit = [[Cockpit alloc] initWithDevice:_device];
    _cockpit.node.simdPosition = RefCockpitEye;
    _cockpit.node.hidden = YES;
    [_playerNode addChildNode:_cockpit.node];
    [SCNTransaction commit];
    [SCNTransaction flush];
}

- (void)buildStudio {
    [SCNTransaction begin];
    [SCNTransaction setDisableActions:YES];
    _scene = [SCNScene scene];
#if TARGET_OS_IOS
    _scene.background.contents = UIColor.blackColor;
#else
    _scene.background.contents = NSColor.blackColor;
#endif
    // Neutral key + fill so hulls and debris read on black.
    SCNNode *key = [SCNNode node];
    key.light = [SCNLight light];
    key.light.type = SCNLightTypeDirectional;
    key.light.intensity = 1500;
    key.eulerAngles = SCNVector3Make(-0.8, 0.6, 0);
    [_scene.rootNode addChildNode:key];
    SCNNode *fill = [SCNNode node];
    fill.light = [SCNLight light];
    fill.light.type = SCNLightTypeAmbient;
    fill.light.intensity = 250;
    [_scene.rootNode addChildNode:fill];
    [self buildCommon:YES];
    [SCNTransaction commit];
    [SCNTransaction flush];
}

- (void)applySky:(SpaceSky *)sky dust:(SCNNode *)dust {
    _sky = sky;
    _scene.background.contents = _sky.cubeTexture;
    _scene.lightingEnvironment.contents = _sky.cubeTexture;
    _scene.lightingEnvironment.intensity = 1.6;
    [_dust removeFromParentNode];
    _dust = dust ?: [sky makeDustNode];
    [_scene.rootNode addChildNode:_dust];
}

#pragma mark - Registration

- (void)beginRegistration:(uint32_t)skySeed {
    _nextSky = [[SpaceSky alloc] initWithDevice:_device faceSize:kSkyFaceSize seed:skySeed ?: 1337];
    _nextDust = [_nextSky makeDustNode];
    @synchronized (_pending) { [_pending addObject:_nextDust]; }
}

- (RefModel)registerModel:(NSString *)name {
    if (!name.length) return 0;
    @synchronized (_handles) {
        NSNumber *h = _handles[name];
        if (h) return h.unsignedIntValue;
    }
    RefModelEntry *m = [RefModelEntry new];
    m.name = name;
    [SCNTransaction begin];
    [SCNTransaction setDisableActions:YES];
    if ([name hasPrefix:@"ship:"]) {
        m.kind = RefKindShip;
        m.ship = ShipDefForModel(name);
        if (!m.ship) NSLog(@"Refresh: no ship definition for model \"%@\"", name);
        else m.prototype = [ShipView shipWithDefinition:m.ship smoke:YES].node;
    } else if ([name hasPrefix:@"proj:"]) {
        m.kind = RefKindProjectile;
        m.projectile = ProjectileDefForModel(name);
        if (!m.projectile) NSLog(@"Refresh: no projectile definition for model \"%@\"", name);
    } else if ([name hasPrefix:@"cap:"]) {
        NSArray *f = [name componentsSeparatedByString:@":"];
        if (f.count >= 3) {
            m.kind = RefKindCapital;
            m.asset = f[1];
            m.style = f[2];
            m.info = [ModelInfo capitalAsset:m.asset];
            m.prototype = [CapitalView prototypeForAsset:m.asset style:m.style];
        }
    }
    [SCNTransaction commit];
    if (m.kind == RefKindNone) NSLog(@"Refresh: unknown model \"%@\"", name);
    @synchronized (_handles) {
        NSNumber *h = _handles[name];
        if (h) return h.unsignedIntValue;   // registered meanwhile from another thread
        [_models addObject:m];
        RefModel handle = (RefModel)_models.count;
        _handles[name] = @(handle);
        if (m.prototype) @synchronized (_pending) { [_pending addObject:m.prototype]; }
        return handle;
    }
}

- (RefModelEntry *)entry:(RefModel)model {
    @synchronized (_handles) {
        return model > 0 && model <= _models.count ? _models[model - 1] : nil;
    }
}

- (NSUInteger)upload:(void (^)(float))progress {
    NSArray *objects;
    @synchronized (_pending) {
        objects = [_pending copy];
        [_pending removeAllObjects];
    }
    [SCNTransaction flush];
    id<SCNSceneRenderer> r = _renderer;
    NSUInteger n = objects.count;
    for (NSUInteger i = 0; i < n; i++) {
        [r prepareObject:objects[i] shouldAbortBlock:nil];
        if (progress) progress((float)(i + 1) / (float)n);
    }
    return n;
}

#pragma mark - Level

- (void)endRegistration {
    if (_nextSky) [self applySky:_nextSky dust:_nextDust];
    _nextSky = nil;
    _nextDust = nil;
    [_world removeFromParentNode];
    _world = [SCNNode node];
    _world.name = @"World";
    [_scene.rootNode addChildNode:_world];
    _playerShown = NO;
}

- (void)clearWorld {
    [_entities removeAllObjects];
    [_world removeFromParentNode];
    _world = nil;
    for (int i = 0; i < REF_MAX_BOLTS; i++) _boltNodes[i].hidden = YES;
    _playerNode.hidden = YES;
    _cockpit.node.hidden = YES;
    _playerKey = 0;
    [self ensurePlayerShip:0];
}

#pragma mark - Entities

- (RefEntityNode *)makeEntity:(const RefEntity *)e {
    RefEntityNode *v = [RefEntityNode new];
    v.model = e->model;
    v.kind = e->kind;
    RefModelEntry *m = [self entry:e->model];
    if (e->kind == EntityProjectile) {
        // A camera-facing glow sized and tinted by the projectile definition.
        const ProjectileDef *p = m.projectile;
        SCNNode *n = [SCNNode node];
        float size = p ? p->size : 5;
        SCNPlane *glow = [SCNPlane planeWithWidth:size height:size];
        glow.firstMaterial = [Effects additiveTextureMaterial:p ? @(p->glow) : @"flare_01" tint:p ? p->tint : simd_make_float3(2, 2, 2)];
        SCNNode *g = [SCNNode nodeWithGeometry:glow];
        g.constraints = @[[SCNBillboardConstraint billboardConstraint]];
        g.castsShadow = NO;
        [n addChildNode:g];
        v.node = n;
    } else if (e->kind == EntityFighter) {
        v.ship = [ShipView shipWithDefinition:m.ship smoke:YES];
        v.node = v.ship.node ?: [SCNNode node];
    } else {
        if (m.kind == RefKindCapital) v.capital = [[CapitalView alloc] initWithAsset:m.asset style:m.style];
        v.node = v.capital.node ?: [SCNNode node];
    }
    [_world addChildNode:v.node];
    return v;
}

- (void)beginFrame:(double)time {
    _dt = _time > 0 ? (float)fmin(fmax(time - _time, 0.0005), 1.0 / 20.0) : 1.0f / 60.0f;
    _time = time;
    [CapitalView updateSharedMaterials:time];
    for (RefEntityNode *v in _entities.allValues) v.seen = NO;
}

- (void)addEntity:(const RefEntity *)e {
    RefEntityNode *v = _entities[@(e->key)];
    if (v && (v.model != e->model || v.kind != e->kind)) {
        [v.node removeFromParentNode];
        v = nil;
    }
    if (!v) _entities[@(e->key)] = v = [self makeEntity:e];
    v.seen = YES;
    v.node.simdPosition = e->origin;
    if (e->kind != EntityProjectile) v.node.simdOrientation = e->orientation;
    if (v.ship) {
        [v.ship updateThrottle:e->throttle boost:e->boost hull:e->hull alive:YES dt:_dt];
    } else if (v.capital) {
        float k = e->scale > 0 ? e->scale : 1;
        v.node.simdScale = simd_make_float3(k, k, k);
        v.capital.deadParts = e->hiddenParts;
    }
}

- (void)endFrame {
    for (NSNumber *k in _entities.allKeys) {
        RefEntityNode *v = _entities[k];
        if (v.seen) continue;
        [v.node removeFromParentNode];
        [_entities removeObjectForKey:k];
    }
}

// The player state names our ship's model; (re)build the view of it when
// that changes. The level's registration already uploaded its geometry.
- (void)ensurePlayerShip:(RefModel)model {
    if (model == _playerModel && (_playerView || !model)) return;
    _playerModel = model;
    [_playerView.node removeFromParentNode];
    _playerView = nil;
    const ShipDef *def = [self entry:model].ship;
    if (!def) return;
    _playerView = [ShipView shipWithDefinition:def smoke:YES];
    [_playerNode addChildNode:_playerView.node];
    [_cockpit setSelfGeometry:[ShipView geometryForDefinition:def]];
    _playerShown = NO;   // a new hull: reset the alive/hidden bookkeeping
}

- (void)setPlayer:(const RefEntity *)p alive:(BOOL)alive interior:(BOOL)interior {
    if (!p) {
        _playerNode.hidden = YES;
        _cockpit.node.hidden = YES;
        return;
    }
    _playerKey = p->key;
    [self ensurePlayerShip:p->model];
    if (alive != !_playerNode.hidden || !_playerShown) {
        [_playerView setAlive:alive];
        _playerNode.hidden = !alive;
    }
    _playerShown = YES;
    _playerNode.simdPosition = p->origin;
    _playerNode.simdOrientation = p->orientation;
    if (alive) [_playerView updateThrottle:p->throttle boost:p->boost hull:p->hull alive:YES dt:_dt];
    _engineLight.light.intensity = alive && _playerView ? 60 + 900 * _playerView.exhaust.level : 0;
    _playerView.model.hidden = interior;
    _cockpit.node.hidden = !interior;
}

- (void)setCamera:(RefCamera)c {
    _cameraNode.simdPosition = c.origin;
    _cameraNode.simdOrientation = c.orientation;
    SCNCamera *cam = _cameraNode.camera;
    if (c.fov > 0) cam.fieldOfView = c.fov;
    if (c.zNear > 0) cam.zNear = c.zNear;
    cam.motionBlurIntensity = c.motionBlur;
    if (_sunLight) {
        _sunLight.simdPosition = c.focus + _sky.sunDirection * 250.0f;
        [_sunLight simdLookAt:c.focus];
    }
    if (_dust) [_sky updateDust:_dust cameraPosition:c.origin velocity:c.velocity];
}

- (SCNNode *)nodeFor:(uint16_t)key {
    if (!key) return nil;
    if (key == _playerKey) return _playerNode;
    return _entities[@(key)].node;
}

#pragma mark - Effects

- (void)showBolt:(int)slot at:(simd_float3)position velocity:(simd_float3)velocity friendly:(BOOL)friendly {
    if (slot < 0 || slot >= REF_MAX_BOLTS) return;
    SCNNode *n = _boltNodes[slot];
    [_fx styleBolt:n player:friendly];
    n.simdPosition = position;
    n.simdOrientation = simd_quaternion(simd_make_float3(0, 1, 0), simd_normalize(velocity));
    n.hidden = NO;
}

- (void)moveBolt:(int)slot to:(simd_float3)position {
    if (slot >= 0 && slot < REF_MAX_BOLTS) _boltNodes[slot].simdPosition = position;
}

- (void)hideBolt:(int)slot {
    if (slot >= 0 && slot < REF_MAX_BOLTS) _boltNodes[slot].hidden = YES;
}

- (void)muzzleFlashOn:(uint16_t)key local:(simd_float3)local friendly:(BOOL)friendly {
    SCNNode *n = [self nodeFor:key];
    if (n) [_fx muzzleFlashOn:n local:local player:friendly];
}

- (void)impactAt:(simd_float3)position friendly:(BOOL)friendly shielded:(BOOL)shielded {
    [_fx impactAt:position player:friendly shielded:shielded];
}

- (SCNMaterial *)hullMaterialForModel:(RefModel)model {
    RefModelEntry *m = [self entry:model];
    if (m.kind == RefKindShip) return [ShipView geometryForDefinition:m.ship].firstMaterial;
    if (m.kind == RefKindCapital)
        return [m.prototype childNodeWithName:@"Body" recursively:NO].geometry.firstMaterial ?: m.prototype.childNodes.firstObject.geometry.firstMaterial;
    return nil;
}

- (void)explosionAt:(simd_float3)position velocity:(simd_float3)velocity model:(RefModel)model scale:(float)scale {
    [_fx explosionAt:position velocity:velocity hullMaterial:[self hullMaterialForModel:model] scale:scale > 0 ? scale : 1];
}

- (void)jumpFlashAt:(simd_float3)position scale:(float)scale {
    SCNNode *s = [_fx streakWithColor:[SKColor colorWithRed:0.6 green:0.8 blue:1 alpha:1] width:400 * fmaxf(scale, 0.3f) height:6];
    s.simdPosition = position;
    [_scene.rootNode addChildNode:s];
    [s runAction:[SCNAction sequence:@[[SCNAction fadeOutWithDuration:0.8], [SCNAction removeFromParentNode]]]];
}

- (void)flashShieldOn:(uint16_t)key {
    if (key && key == _playerKey) [_playerView flashShield];
    else [_entities[@(key)].ship flashShield];
}

#pragma mark - Queries

- (float)radiusOfModel:(RefModel)model {
    RefModelEntry *m = [self entry:model];
    if (m.ship) return m.ship->radius;
    if (m.info) return m.info.radius;
    return 2;
}

- (const GameModelInfo *)infoForModel:(RefModel)model { return [self entry:model].info.info; }

- (id)hologramForModel:(RefModel)model {
    RefModelEntry *m = [self entry:model];
    if (m.kind == RefKindShip) return [ShipView geometryForDefinition:m.ship];
    if (m.kind == RefKindCapital) return [m.prototype childNodeWithName:@"Body" recursively:NO].geometry;
    return nil;
}

- (BOOL)projectPoint:(simd_float3)world to:(CGPoint *)out {
    simd_float3 camFwd = simd_act(_cameraNode.simdOrientation, simd_make_float3(0, 0, -1));
    if (simd_dot(world - _cameraNode.simdPosition, camFwd) <= 0.1f) return NO;
    SCNVector3 p = [_renderer projectPoint:SCNVector3Make(world.x, world.y, world.z)];
#if TARGET_OS_IOS
    // The iOS view counts down from the top. The SpriteKit HUD counts up.
    p.y = self.viewSize.height - p.y;
#endif
    *out = CGPointMake(p.x, p.y);
    return YES;
}

- (BOOL)traceOpaqueFrom:(simd_float3)from to:(simd_float3)to {
    NSArray *hits = [_scene.rootNode hitTestWithSegmentFromPoint:SCNVector3Make(from.x, from.y, from.z)
                                                         toPoint:SCNVector3Make(to.x, to.y, to.z)
                                                         options:@{ SCNHitTestOptionSearchMode : @(SCNHitTestSearchModeAll),
                                                                    SCNHitTestBackFaceCullingKey : @YES,
                                                                    SCNHitTestIgnoreHiddenNodesKey : @YES }];
    for (SCNHitTestResult *h in hits) {
        // Ignore additive effects and transparent canopy glass, but keep
        // searching: a hull behind them can still block the segment.
        SCNMaterial *material = h.node.geometry.firstMaterial;
        if (!material || h.node.particleSystems || h.node == _dust ||
            material.blendMode != SCNBlendModeReplace || material.transparency < 0.95) continue;
        return YES;
    }
    return NO;
}

#pragma mark - Cockpit

- (void)updateCockpit:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count {
    [_cockpit updateFrame:frame contacts:contacts count:count];
}

- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time {
    [_cockpit renderDisplaysWithQueue:queue time:time];
}

@end
