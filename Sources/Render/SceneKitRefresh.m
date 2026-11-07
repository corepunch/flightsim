#import "Render.h"
#import "Shared.h"
#import "Common.h"
#import <mach/mach.h>
#import <QuartzCore/CAMetalLayer.h>


typedef NS_ENUM(int, RefModelKind) { RefKindNone, RefKindShip, RefKindCapital, RefKindProjectile, RefKindPickup };

// A registered model: what its name says and the prototype that keeps it on the GPU.
@interface RefModelEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) RefModelKind kind;
@property (nonatomic) const ShipDef *ship;
@property (nonatomic) const ProjectileDef *projectile;
@property (nonatomic) const PickupDef *pickup;
@property (nonatomic, copy) NSString *asset, *style;
@property (nonatomic, strong) ModelInfo *info;
@property (nonatomic, strong) SCNNode *prototype;
@property (nonatomic, strong) SCNNode *preview;   // -previewForModel:, built on first use
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
@property (nonatomic, strong) SCNNode *spinner;     // pickups: the mesh, turned about its up axis each frame
@property (nonatomic, strong) SCNNode *halo;        // pickups: the glow, pulsing with the mesh
@property (nonatomic) float spin;                   // radians per second
@property (nonatomic) float phase;                  // pickups: where in the pulse this one starts
@property (nonatomic) BOOL seen;
@end
@implementation RefEntityNode
@end

// Scenery is game data: an authored model with a panorama, or the procedural terrain
// with its own sky dome. This view owns whichever the level asks for, and the haze.
@interface WorldBackdrop : NSObject
@property (nonatomic, readonly) SCNNode *node;
@property (nonatomic, readonly) LevelEnvironment definition;
@property (nonatomic, readonly) NSURL *sky;
@property (nonatomic, readonly) ProceduralTerrain *terrain;
- (instancetype)initWithDefinition:(LevelEnvironment)definition device:(id<MTLDevice>)device cells:(NSUInteger)cells hdr:(BOOL)hdr;
@end
@implementation WorldBackdrop
- (instancetype)initWithDefinition:(LevelEnvironment)definition device:(id<MTLDevice>)device cells:(NSUInteger)cells hdr:(BOOL)hdr {
    if ((self = [super init])) {
        _definition = definition;
        if (definition.terrain) {
            NSURL *shaders = [[NSBundle.mainBundle URLForResource:@"Terrain" withExtension:@"metal" subdirectory:@"Shaders"] URLByDeletingLastPathComponent];
            _terrain = [[ProceduralTerrain alloc] initWithLibrary:[ProceduralTerrain libraryWithDevice:device shaderDirectory:shaders] cells:cells hdr:hdr];
            _terrain.environment = definition;
            _node = _terrain.node;
        } else {
            NSURL *url = FSURL(@"Models", definition.model, @"scn");
            SCNScene *scene = url ? [SCNScene sceneWithURL:url options:nil error:nil] : nil;
            _node = [scene.rootNode clone] ?: [SCNNode node];
            [_node enumerateHierarchyUsingBlock:^(SCNNode *child, BOOL *stop) {
                for (SCNMaterial *material in child.geometry.materials) {
                    material.lightingModelName = SCNLightingModelPhysicallyBased;
                    material.roughness.contents = @1;
                    material.metalness.contents = @0;
                }
            }];
        }
        _sky = FSURL(@"Textures", definition.sky, @"jpg");
    }
    return self;
}
@end

@implementation SceneKitRefresh {
    __weak id<SCNSceneRenderer> _renderer;
    CGSize _size;
    id<MTLDevice> _device;

    NSMutableArray<RefModelEntry *> *_models;          // handle - 1
    NSMutableDictionary<NSString *, NSNumber *> *_handles;
    NSMutableArray *_pending;                           // built, not yet uploaded

    SpaceSky *_sky, *_nextSky;
    WorldBackdrop *_backdrop, *_nextBackdrop;
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
    SCNMaterial *_tracer;
    Cvar *_motionBlur, *_shadowSize, *_terrainGrid;
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
        _motionBlur = [Cvar get:@"r_motionBlur" defaultValue:TARGET_OS_IOS ? @"0" : @"1" flags:CVAR_ARCHIVE
                          help:@"Scale full-scene motion blur; 0 disables its velocity buffers and postprocessing pass"];
        _shadowSize = [Cvar get:@"r_shadowSize" defaultValue:TARGET_OS_IOS ? @"1024" : @"2048" flags:CVAR_ARCHIVE
                          help:@"Sun shadow map edge in pixels (restart required)"];
        _terrainGrid = [Cvar get:@"r_terrainGrid" defaultValue:TARGET_OS_IOS ? @"96" : @"128" flags:CVAR_ARCHIVE
                           help:@"Cells per edge of each procedural terrain ring, a multiple of 4 from 16 to 252 (applies on the next level)"];
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

- (void)printStats {
    task_vm_info_data_t memory = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count) == KERN_SUCCESS)
        NSLog(@"Render: app footprint %.1f MiB, resident %.1f MiB, Metal allocations %.1f MiB, %lu models, %lu entities",
              memory.phys_footprint / 1048576.0, memory.resident_size / 1048576.0,
              _device.currentAllocatedSize / 1048576.0, (unsigned long)_models.count, (unsigned long)_entities.count);
    [RenderTextures printStats];
    if (_backdrop.terrain) NSLog(@"%@", _backdrop.terrain.stats);
    NSLog(@"Render pipeline: HDR %@, colour pixel format %lu, camera bloom %.2f",
          _cameraNode.camera.wantsHDR ? @"on" : @"off", (unsigned long)_renderer.colorPixelFormat,
          _cameraNode.camera.bloomIntensity);
#if TARGET_OS_IOS
    if ([(id)_renderer isKindOfClass:SCNView.class]) {
        SCNView *view = (SCNView *)_renderer;
        NSLog(@"Render target: %@ pixels, %.2f pixels/point, HDR off, motion blur %.2f, mesh sky",
              NSStringFromCGSize(((CAMetalLayer *)view.layer).drawableSize), view.contentScaleFactor,
              _motionBlur.value);
    }
#endif
}

- (simd_float3)sunDirection { return _backdrop ? simd_normalize(simd_make_float3(-0.4f, 0.7f, -0.5f)) : _sky.sunDirection; }

#pragma mark - World

- (SCNNode *)makeCamera:(BOOL)studio {
    SCNCamera *cam = [SCNCamera camera];
    cam.fieldOfView = studio ? 60 : 70;
    cam.zNear = 0.3;
    cam.zFar = studio ? 5000 : 40000;
    cam.wantsHDR = NO;
    cam.wantsExposureAdaptation = NO;
    cam.bloomIntensity = 0;
    SCNNode *n = [SCNNode node];
    n.camera = cam;
    return n;
}

// Effects, the bolt pool and the player's rig: shared by the game and the studio.
- (void)buildCommon:(BOOL)studio {
    _tracer = [SCNMaterial material];
    _tracer.lightingModelName = SCNLightingModelConstant;
    _tracer.diffuse.contents = [SKColor colorWithRed:1 green:0.8 blue:0.36 alpha:1];
    _tracer.emission.contents = [SKColor colorWithRed:1 green:0.65 blue:0.15 alpha:1];
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
    [self applySky:[[SpaceSky alloc] initWithDevice:_device seed:1337] dust:nil];

    SCNLight *sun = [SCNLight light];
    sun.type = SCNLightTypeDirectional;
    sun.color = [SKColor colorWithRed:1.0 green:0.94 blue:0.86 alpha:1];
    sun.intensity = 2600;
    sun.castsShadow = YES;
    NSInteger shadowSize = MAX(256, MIN(2048, _shadowSize.integer));
    sun.shadowMapSize = CGSizeMake(shadowSize, shadowSize);
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
    [_sky.node removeFromParentNode];
    _sky = sky;
    _scene.background.contents = nil;
    _scene.lightingEnvironment.contents = nil;
    [_scene.rootNode addChildNode:_sky.node];
    [_dust removeFromParentNode];
    _dust = dust ?: [sky makeDustNode];
    [_scene.rootNode addChildNode:_dust];
}

#pragma mark - Registration

- (void)beginRegistration:(uint32_t)skySeed {
    _nextBackdrop = nil;
    _nextSky = [[SpaceSky alloc] initWithDevice:_device seed:skySeed ?: 1337];
    _nextDust = [_nextSky makeDustNode];
    @synchronized (_pending) { [_pending addObject:_nextSky.node]; [_pending addObject:_nextDust]; }
}

- (void)registerEnvironment:(LevelEnvironment)environment {
    if (!environment.model.length && !environment.terrain) return;
    _nextBackdrop = [[WorldBackdrop alloc] initWithDefinition:environment device:_device
                                                        cells:(NSUInteger)MAX(0, _terrainGrid.integer) hdr:_cameraNode.camera.wantsHDR];
    @synchronized (_pending) {
        [_pending addObject:_nextBackdrop.node];
        if (_nextBackdrop.terrain) [_pending addObject:_nextBackdrop.terrain.skyNode];
    }
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
    } else if ([name hasPrefix:@"pickup:"]) {
        m.pickup = PickupDefForModel(name);
        if (!m.pickup) NSLog(@"Refresh: no pickup definition for model \"%@\"", name);
        else {
            m.kind = RefKindPickup;
            m.asset = @(m.pickup->asset);
            m.style = @(m.pickup->style);
            m.info = [ModelInfo capitalAsset:m.asset];
            m.prototype = [CapitalView prototypeForAsset:m.asset style:m.style];
        }
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
    [_backdrop.node removeFromParentNode];
    _backdrop = _nextBackdrop;
    _nextBackdrop = nil;
    _scene.fogStartDistance = _backdrop ? _backdrop.definition.fogStart : 0;
    _scene.fogEndDistance = _backdrop ? _backdrop.definition.fogEnd : 0;
    if (_backdrop) {
        LevelEnvironment environment = _backdrop.definition;
        _scene.fogColor = [SKColor colorWithRed:environment.fogColor.x green:environment.fogColor.y blue:environment.fogColor.z alpha:1];
        [_sky.node removeFromParentNode];
        // The procedural sky dome draws the background itself; the panorama, when the
        // level has one, still lights the aircraft.
        _scene.background.contents = _backdrop.terrain ? nil : _backdrop.sky;
        _scene.lightingEnvironment.contents = _backdrop.sky;
        _scene.lightingEnvironment.intensity = 0.8;
        [_dust removeFromParentNode];
        _dust = nil;
        [_world addChildNode:_backdrop.node];
        if (_backdrop.terrain) {
            _backdrop.terrain.sunDirection = self.sunDirection;
            [_world addChildNode:_backdrop.terrain.skyNode];
        }
    }
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
    if (e->kind == EntityPickup && m.kind == RefKindPickup) {
        // The mesh turning inside a camera-facing glow, both from the pickup definition.
        const PickupDef *p = m.pickup;
        SCNNode *n = [SCNNode node];
        v.capital = [[CapitalView alloc] initWithAsset:m.asset style:m.style];
        v.spinner = v.capital.node;
        v.spin = p->spin * (float)M_PI / 180;
        [n addChildNode:v.spinner];
        SCNPlane *glow = [SCNPlane planeWithWidth:p->size height:p->size];
        glow.firstMaterial = [Effects additiveTextureMaterial:@(p->glow) tint:p->tint];
        SCNNode *g = [SCNNode nodeWithGeometry:glow];
        g.constraints = @[[SCNBillboardConstraint billboardConstraint]];
        g.castsShadow = NO;
        [n addChildNode:g];
        v.halo = g;
        v.phase = (float)(e->key % 7) / 7.0f;
        v.node = n;
    } else if (e->kind == EntityProjectile) {
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
    if (v.spinner) {
        // Turning, and pulsing about once a second: the halo brightens and
        // grows, the mesh swells a little.
        v.spinner.simdOrientation = simd_quaternion((float)fmod(_time * v.spin, 2 * M_PI), simd_make_float3(0, 1, 0));
        float pulse = 0.5f + 0.5f * sinf((float)(2 * M_PI * fmod(_time * 1.1 + v.phase, 1.0)));
        float swell = 1 + 0.08f * pulse;
        v.spinner.simdScale = simd_make_float3(swell, swell, swell);
        v.halo.opacity = 0.5 + 0.5 * pulse;
        float grow = 0.85f + 0.3f * pulse;
        v.halo.simdScale = simd_make_float3(grow, grow, grow);
    } else if (v.ship) {
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
    BOOL aircraft = _playerView.definition && _playerView.definition->params.gravity > 0;
    _engineLight.light.intensity = alive && _playerView && !aircraft ? 60 + 900 * _playerView.exhaust.level : 0;
    _playerView.model.hidden = interior && !aircraft;
    _cockpit.node.hidden = !interior || aircraft;
}

- (void)setCamera:(RefCamera)c {
    _cameraNode.simdPosition = c.origin;
    _cameraNode.simdOrientation = c.orientation;
    SCNCamera *cam = _cameraNode.camera;
    if (c.fov > 0) cam.fieldOfView = c.fov;
    if (c.zNear > 0) cam.zNear = c.zNear;
    // Even a tiny nonzero blur retains SceneKit's velocity buffers and full
    // screen pass. The smoothed boost value otherwise keeps them alive.
    cam.motionBlurIntensity = c.motionBlur * clampf(_motionBlur.value, 0, 1);
    if (_sunLight) {
        _sunLight.simdPosition = c.focus + self.sunDirection * 250.0f;
        [_sunLight simdLookAt:c.focus];
    }
    _sky.node.simdPosition = c.origin;
    if (_dust) [_sky updateDust:_dust cameraPosition:c.origin velocity:c.velocity];
    [_backdrop.terrain updateForCamera:c.origin time:_time];
}

- (SCNNode *)nodeFor:(uint16_t)key {
    if (!key) return nil;
    if (key == _playerKey) return _playerNode;
    return _entities[@(key)].node;
}

#pragma mark - Effects

- (void)showBolt:(int)slot at:(simd_float3)position velocity:(simd_float3)velocity friendly:(BOOL)friendly ion:(BOOL)ion {
    if (slot < 0 || slot >= REF_MAX_BOLTS) return;
    SCNNode *n = _boltNodes[slot];
    [_fx styleBolt:n player:friendly ion:ion];
    [n childNodeWithName:@"glow" recursively:NO].hidden = _backdrop != nil;
    n.simdScale = _backdrop ? simd_make_float3(0.4f, 0.22f, 0.4f) : simd_make_float3(1, 1, 1);
    if (_backdrop) [n childNodeWithName:@"core" recursively:NO].geometry.firstMaterial = _tracer;
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

- (void)flashShieldOn:(uint16_t)key from:(simd_float3)direction {
    if (key && key == _playerKey) [_playerView flashShieldFrom:direction];
    else [_entities[@(key)].ship flashShieldFrom:direction];
}

#pragma mark - Queries

- (float)radiusOfModel:(RefModel)model {
    RefModelEntry *m = [self entry:model];
    if (m.ship) return m.ship->radius;
    if (m.info) return m.info.radius;
    return 2;
}

- (const GameModelInfo *)infoForModel:(RefModel)model { return [self entry:model].info.info; }

- (id)previewForModel:(RefModel)model {
    RefModelEntry *m = [self entry:model];
    if (!m.preview) {
        if (m.kind == RefKindShip) {
            SCNNode *holder = [SCNNode node];
            SCNNode *mesh = [SCNNode nodeWithGeometry:[ShipView geometryForDefinition:m.ship]];
            mesh.eulerAngles = SCNVector3Make(0, M_PI, 0);   // OBJ +Z nose -> ship -Z nose, as ShipView
            [holder addChildNode:mesh];
            m.preview = holder;
        } else if (m.kind == RefKindCapital || m.kind == RefKindPickup) {
            m.preview = m.prototype;
        }
    }
    return m.preview;
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
                                                                    SCNHitTestOptionCategoryBitMask : @(RenderCategoryGeometry),
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
