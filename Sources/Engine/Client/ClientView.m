#import "ClientView.h"
#import "ShipView.h"
#import "CapitalView.h"
#import "SpaceSky.h"
#import "Effects.h"
#import "Cockpit.h"
#import "Assets.h"
#include "SharedMath.h"

#define MAX_BOLT_NODES 480
#define MAX_HUD 64

static const NSUInteger kSkyFaceSize = TARGET_OS_IOS ? 1024 : 1536;
static const simd_float3 kCockpitEye = {0, 1.0f, -2.2f};

typedef struct {
    simd_float3 position, velocity;
    float life;
    uint16_t id;
    BOOL active;
    BOOL awaitingId;        // predicted: the server's id comes with its EV_BOLT
} ClientBolt;

// The view of one entity: a fighter, capital (or prop, rock, buoy) or torpedo.
@interface EntityView : NSObject
@property (nonatomic) uint16_t number, model;
@property (nonatomic) uint8_t kind;
@property (nonatomic, strong) SCNNode *node;
@property (nonatomic, strong) ShipView *ship;
@property (nonatomic, strong) CapitalView *capital;
@property (nonatomic) EntityState state;
@property (nonatomic) BOOL seen;
@end
@implementation EntityView
@end

@implementation ClientView {
    __weak SCNView *_view;
    Input *_input;
    SpaceSky *_sky, *_nextSky;
    SCNNode *_sunLight, *_engineLight, *_dust, *_nextDust, *_world;
    Cockpit *_cockpitModel;
    Effects *_fx;
    ShipView *_playerView;

    NSMutableDictionary<NSNumber *, EntityView *> *_views;
    ClientBolt _bolts[MAX_BOLT_NODES];
    SCNNode *_boltNodes[MAX_BOLT_NODES];
    uint32_t _boltSerial[MAX_BOLT_NODES], _nextBoltSerial;

    simd_quatf _camOrientation;
    float _shake, _damageFlash, _lookYaw, _lookPitch, _boostFx;
    double _time;
    NSString *_status, *_objectiveSummary, *_lastInputText;
    uint16_t _playerEntity;
    BOOL _hadPlayer;
}

- (instancetype)initWithView:(SCNView *)view input:(Input *)input {
    if ((self = [super init])) {
        _view = view;
        _input = input;
        _hud = [[HUD alloc] initWithSize:view.bounds.size];
        _views = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Configstrings

- (NSString *)cs:(int)index {
    NSArray *cs = self.configStrings;
    return index >= 0 && index < (int)cs.count ? cs[index] : @"";
}
- (NSString *)stringAt:(uint16_t)i { return i ? [self cs:CS_STRINGS + i] : nil; }
- (NSString *)modelAt:(uint16_t)i { return i ? [self cs:CS_MODELS + i] : @""; }

#pragma mark - Scene

- (void)buildScene {
    _scene = [SCNScene scene];
    [self applySky:[[SpaceSky alloc] initWithDevice:_view.device faceSize:kSkyFaceSize seed:1337] dust:nil];

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

    SCNCamera *cam = [SCNCamera camera];
    cam.fieldOfView = 70;
    cam.zNear = 0.3;
    cam.zFar = 40000;
    cam.wantsHDR = YES;
    cam.wantsExposureAdaptation = NO;
    cam.exposureOffset = 0.0;
    // Screen-space bloom does the glow work: emitters write HDR values > 1.
    cam.bloomIntensity = 1.35;
    cam.bloomThreshold = 0.9;
    cam.bloomBlurRadius = 18;
    cam.bloomIterationCount = 2;
    cam.bloomIterationSpread = 1.0;
    cam.vignettingIntensity = 0.7;
    cam.vignettingPower = 0.9;
    cam.colorFringeStrength = 0.5;
    cam.colorFringeIntensity = 0.6;
    cam.saturation = 1.08;
    cam.contrast = 0.05;
    _cameraNode = [SCNNode node];
    _cameraNode.camera = cam;
    [_scene.rootNode addChildNode:_cameraNode];

    _playerView = [ShipView shipWithClass:ShipClassExecutioner smoke:YES];
    [_scene.rootNode addChildNode:_playerView.node];

    SCNLight *glow = [SCNLight light];
    glow.type = SCNLightTypeOmni;
    glow.color = [SKColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1];
    glow.attenuationStartDistance = 0;
    glow.attenuationEndDistance = 18;
    glow.intensity = 0;
    _engineLight = [SCNNode node];
    _engineLight.light = glow;
    _engineLight.position = SCNVector3Make(0, 0.5, 6.0);
    [_playerView.node addChildNode:_engineLight];

    _cockpitModel = [[Cockpit alloc] initWithDevice:_view.device];
    _cockpitModel.node.simdPosition = kCockpitEye;
    _cockpitModel.node.hidden = YES;
    [_playerView.node addChildNode:_cockpitModel.node];
    _cockpit = getenv("SF_COCKPIT") != NULL;

    _fx = [[Effects alloc] initWithScene:_scene];
    for (int i = 0; i < MAX_BOLT_NODES; i++) {
        SCNNode *n = [_fx makeBoltNode];
        n.hidden = YES;
        [_scene.rootNode addChildNode:n];
        _boltNodes[i] = n;
    }
    _playerView.node.hidden = YES;
    _camOrientation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
}

- (NSArray *)warmupObjects {
    NSMutableArray *objects = [NSMutableArray arrayWithObject:_scene];
    [objects addObjectsFromArray:[_fx warmupNodes]];
    return objects;
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

- (NSArray *)loadMissionAssets:(float *)progress {
    [SCNTransaction begin];
    [SCNTransaction setDisableActions:YES];
    uint32_t seed = (uint32_t)[self cs:CS_SKY].longLongValue;
    _nextSky = [[SpaceSky alloc] initWithDevice:_view.device faceSize:kSkyFaceSize seed:seed ?: 1337];
    _nextDust = [_nextSky makeDustNode];
    *progress = 0.3f;

    // Every model the mission can show: one throwaway instance of each, so
    // ships that jump in later are already on the GPU.
    NSMutableArray *objects = [NSMutableArray arrayWithObject:_nextDust];
    NSMutableArray *models = [NSMutableArray array];
    for (int i = 1; i < MAX_MODELS; i++) {
        NSString *m = [self cs:CS_MODELS + i];
        if (m.length) [models addObject:m];
    }
    for (NSUInteger i = 0; i < models.count; i++) {
        NSString *m = models[i];
        if ([m hasPrefix:@"cap:"]) {
            NSArray *f = [m componentsSeparatedByString:@":"];
            if (f.count >= 3) [objects addObject:[CapitalView prototypeForAsset:f[1] style:f[2]]];
        } else {
            ShipView *s = [ShipView viewWithModel:m];
            if (s) [objects addObject:s.node];
        }
        *progress = 0.3f + 0.3f * (float)(i + 1) / (float)models.count;
    }
    [SCNTransaction commit];
    [SCNTransaction flush];
    return objects;
}

- (void)attachMission {
    if (_nextSky) [self applySky:_nextSky dust:_nextDust];
    _nextSky = nil;
    _nextDust = nil;
    [_world removeFromParentNode];
    _world = [SCNNode node];
    _world.name = @"World";
    [_scene.rootNode addChildNode:_world];
    [_hud clearMessages];
    [_hud setHelpVisible:NO];
    [_hud setObjectives:@[] states:@[]];
    _status = nil;
    _objectiveSummary = nil;
    _hadPlayer = NO;
    _damageFlash = 0;
    _shake = 0;
}

- (void)clearMission {
    [_views removeAllObjects];
    [_world removeFromParentNode];
    _world = nil;
    for (int i = 0; i < MAX_BOLT_NODES; i++) { _bolts[i].active = NO; _boltNodes[i].hidden = YES; }
    _playerView.node.hidden = YES;
    _cockpitModel.node.hidden = YES;
    _playerEntity = 0;
}

#pragma mark - Entities

- (EntityView *)makeView:(const EntityState *)s {
    EntityView *v = [EntityView new];
    v.number = s->number;
    v.model = s->model;
    v.kind = s->kind;
    NSString *model = [self modelAt:s->model];
    if (s->kind == EntityTorpedo) {
        SCNNode *n = [SCNNode node];
        SCNPlane *glow = [SCNPlane planeWithWidth:7 height:7];
        glow.firstMaterial = [Effects additiveTextureMaterial:@"flare_01" tint:simd_make_float3(3.0f, 1.6f, 0.6f)];
        SCNNode *g = [SCNNode nodeWithGeometry:glow];
        g.constraints = @[[SCNBillboardConstraint billboardConstraint]];
        g.castsShadow = NO;
        [n addChildNode:g];
        v.node = n;
    } else if (s->kind == EntityFighter) {
        v.ship = [ShipView viewWithModel:model] ?: [ShipView shipWithClass:ShipClassSpitfire smoke:YES];
        v.node = v.ship.node;
    } else {
        v.capital = [CapitalView viewWithModel:model];
        v.node = v.capital.node ?: [SCNNode node];
    }
    [_world addChildNode:v.node];
    return v;
}

- (void)drawEntity:(EntityView *)v state:(const EntityState *)s dt:(float)dt {
    v.state = *s;
    v.node.simdPosition = s->origin;
    if (s->kind != EntityTorpedo) v.node.simdOrientation = s->orientation;
    if (v.ship) {
        [v.ship updateThrottle:s->throttle boost:(s->flags & EF_BOOST) != 0 hull:s->hull alive:YES dt:dt];
    } else if (v.capital) {
        float k = s->scale > 0 ? s->scale : 1;
        v.node.simdScale = simd_make_float3(k, k, k);
        v.capital.deadParts = s->deadParts;
    }
}

- (EntityView *)viewFor:(uint16_t)number { return number ? _views[@(number)] : nil; }

- (SCNNode *)nodeFor:(uint16_t)number {
    if (number && number == _playerEntity) return _playerView.node;
    return [self viewFor:number].node;
}

- (float)radiusOf:(EntityView *)v {
    if (v.ship) return v.ship.radius;
    if (v.capital) return v.capital.info.radius * (v.state.scale > 0 ? v.state.scale : 1);
    return 2;
}

- (SCNMaterial *)hullMaterialForModel:(uint16_t)model {
    NSString *m = [self modelAt:model];
    if ([m hasPrefix:@"ship:"]) {
        int c = FighterClassForMesh([m substringFromIndex:5]);
        return c >= 0 ? [ShipView geometryForClass:(ShipClass)c].firstMaterial : nil;
    }
    if ([m hasPrefix:@"cap:"]) {
        NSArray *f = [m componentsSeparatedByString:@":"];
        if (f.count < 3) return nil;
        SCNNode *proto = [CapitalView prototypeForAsset:f[1] style:f[2]];
        return [proto childNodeWithName:@"Body" recursively:NO].geometry.firstMaterial ?: proto.childNodes.firstObject.geometry.firstMaterial;
    }
    return nil;
}

#pragma mark - Events

- (int)spawnBolt:(simd_float3)pos velocity:(simd_float3)vel team:(int)team id:(uint16_t)boltId {
    for (int i = 0; i < MAX_BOLT_NODES; i++) {
        if (_bolts[i].active) continue;
        _bolts[i] = (ClientBolt){ pos, vel, BOLT_LIFE, boltId, YES, NO };
        SCNNode *n = _boltNodes[i];
        [_fx styleBolt:n player:team == TeamFriend];
        n.simdPosition = pos;
        n.simdOrientation = simd_quaternion(simd_make_float3(0, 1, 0), simd_normalize(vel));
        n.hidden = NO;
        return i;
    }
    return -1;
}

- (void)predictedShotFrom:(simd_float3)pos velocity:(simd_float3)velocity gun:(simd_float3)gunLocal {
    int i = [self spawnBolt:pos velocity:velocity team:TeamFriend id:0];
    if (i >= 0) {
        _bolts[i].awaitingId = YES;
        _boltSerial[i] = ++_nextBoltSerial;
    }
    [_fx muzzleFlashOn:_playerView.node local:gunLocal player:YES];
}

- (void)handleEvent:(const GameEvent *)e player:(const PlayerState *)ps {
    simd_float3 me = ps->move.origin;
    if (_predictedEntity && e->entity == _predictedEntity) {
        if (e->type == EV_MUZZLE) return;      // already flashed
        if (e->type == EV_BOLT) {
            // Our own shot: give its id to the oldest predicted bolt still waiting.
            int best = -1;
            for (int i = 0; i < MAX_BOLT_NODES; i++)
                if (_bolts[i].active && _bolts[i].awaitingId && (best < 0 || _boltSerial[i] < _boltSerial[best])) best = i;
            if (best >= 0) {
                _bolts[best].awaitingId = NO;
                _bolts[best].id = e->id;
                return;
            }
        }
    }
    switch (e->type) {
        case EV_BOLT:
            [self spawnBolt:e->pos velocity:e->vel team:e->team id:e->id];
            break;
        case EV_IMPACT:
            if (e->id)
                for (int i = 0; i < MAX_BOLT_NODES; i++)
                    if (_bolts[i].active && _bolts[i].id == e->id) { _bolts[i].active = NO; _boltNodes[i].hidden = YES; break; }
            [_fx impactAt:e->pos player:e->team == TeamFriend shielded:(e->flags & EVF_SHIELDED) != 0];
            break;
        case EV_MUZZLE: {
            SCNNode *n = [self nodeFor:e->entity];
            if (n) [_fx muzzleFlashOn:n local:e->pos player:e->team == TeamFriend];
            break;
        }
        case EV_DAMAGE:
            if (e->flags & EVF_SHIELDED) {
                if (e->entity == _playerEntity) [_playerView flashShield];
                else [[self viewFor:e->entity].ship flashShield];
            }
            if (e->entity && e->entity == ps->entity) {
                _damageFlash = 1;
                _shake = fmaxf(_shake, e->scale);
            }
            break;
        case EV_EXPLOSION:
            [_fx explosionAt:e->pos velocity:e->vel hullMaterial:[self hullMaterialForModel:e->model] scale:e->scale > 0 ? e->scale : 1];
            if (e->radius > 0) _shake = fmaxf(_shake, clampf(1.0f - simd_distance(e->pos, me) / e->radius, 0, 1));
            break;
        case EV_JUMP: {
            SCNNode *s = [_fx streakWithColor:[SKColor colorWithRed:0.6 green:0.8 blue:1 alpha:1] width:400 * fmaxf(e->scale, 0.3f) height:6];
            s.simdPosition = e->pos;
            [_scene.rootNode addChildNode:s];
            [s runAction:[SCNAction sequence:@[[SCNAction fadeOutWithDuration:0.8], [SCNAction removeFromParentNode]]]];
            break;
        }
    }
}

- (void)serverCommand:(int)type a:(NSString *)a b:(NSString *)b c:(NSString *)c {
    switch (type) {
        case SVC_RADIO: [_hud showMessage:a from:b]; break;
        case SVC_BANNER:
            [_hud showBanner:a color:[b isEqualToString:@"red"] ? [SKColor colorWithRed:1 green:0.4 blue:0.3 alpha:1] : nil];
            break;
        case SVC_OBJECTIVES: {
            NSArray *lines = a.length ? [a componentsSeparatedByString:@"\n"] : @[];
            NSMutableArray *states = [NSMutableArray array];
            for (NSUInteger i = 0; i < b.length; i++) [states addObject:@([b characterAtIndex:i] - '0')];
            while (states.count < lines.count) [states addObject:@0];
            [_hud setObjectives:lines states:states];
            _objectiveSummary = c.length ? c : nil;
            break;
        }
        case SVC_STATUS: _status = a.length ? a : nil; break;
    }
}

#pragma mark - Frame

- (void)menuFrame:(double)time {
    _playerView.node.hidden = YES;
    _cockpitModel.node.hidden = YES;
    _cameraNode.simdPosition = simd_make_float3(0, 0, 0);
    _cameraNode.simdOrientation = simd_quaternion((float)time * 0.02f, simd_make_float3(0, 1, 0));
}

- (void)updateBolts:(float)dt {
    for (int i = 0; i < MAX_BOLT_NODES; i++) {
        ClientBolt *b = &_bolts[i];
        if (!b->active) continue;
        b->position += b->velocity * dt;
        b->life -= dt;
        if (b->life <= 0) { b->active = NO; _boltNodes[i].hidden = YES; }
        else _boltNodes[i].simdPosition = b->position;
    }
}

- (void)drawEntities:(const EntityState *)entities count:(NSUInteger)count player:(const PlayerState *)ps
            controls:(ControlState)controls time:(double)time dt:(float)dt {
    _time = time;
    [CapitalView updateSharedMaterials:time];
    _playerEntity = ps->entity;

    for (EntityView *v in _views.allValues) v.seen = NO;
    for (NSUInteger i = 0; i < count; i++) {
        const EntityState *s = &entities[i];
        if (s->number == ps->entity) continue;      // drawn from the player state
        EntityView *v = _views[@(s->number)];
        if (v && (v.model != s->model || v.kind != s->kind)) {
            [v.node removeFromParentNode];
            v = nil;
        }
        if (!v) _views[@(s->number)] = v = [self makeView:s];
        v.seen = YES;
        [self drawEntity:v state:s dt:dt];
    }
    for (NSNumber *k in _views.allKeys) {
        EntityView *v = _views[k];
        if (v.seen) continue;
        [v.node removeFromParentNode];
        [_views removeObjectForKey:k];
    }

    // Own ship.
    BOOL alive = ps->alive && ps->entity;
    if (alive != !_playerView.node.hidden || !_hadPlayer) [_playerView setAlive:alive];
    _hadPlayer = YES;
    _playerView.node.simdPosition = ps->move.origin;
    _playerView.node.simdOrientation = ps->move.orientation;
    if (alive) [_playerView updateThrottle:ps->move.throttle boost:ps->move.boosting hull:ps->hull alive:YES dt:dt];
    _engineLight.light.intensity = alive ? 60 + 900 * _playerView.exhaust.level : 0;

    [self updateBolts:dt];
    [self updateCamera:dt player:ps controls:controls];
    _sunLight.simdPosition = ps->move.origin + _sky.sunDirection * 250.0f;
    [_sunLight simdLookAt:ps->move.origin];
    [_sky updateDust:_dust cameraPosition:_cameraNode.simdPosition velocity:ps->move.velocity];
    _damageFlash = fmaxf(0, _damageFlash - dt * 2.5f);
    [self updateHUD:ps controls:controls];
}

- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time {
    [_cockpitModel renderDisplaysWithQueue:queue time:time];
}

#pragma mark - Camera

/// Places the chase or cockpit camera for this frame.
///
/// Everything here is smoothed over time so the view never moves abruptly:
/// - Free-look (hat) and the chase camera's orientation lag behind the ship using
///   exponential easing, `1 - exp(-k*dt)`, which doesn't depend on frame rate.
/// - Boost effects (pull-back, FOV, motion blur) are scaled by `_boostFx`, which
///   eases in and out instead of snapping between 0 and 1.
/// - Shake is a deterministic sum of sines, not per-frame random noise. Random
///   noise jumps to a new spot every frame, so it shows up as jitter (worse at
///   higher frame rates) rather than rumble.
///
/// Tuning: boost rumble amplitude is `boostFx * 0.015f`; the cockpit scale is `0.15f`.
- (void)updateCamera:(float)dt player:(const PlayerState *)ps controls:(ControlState)c {
    float targetYaw = 0, targetPitch = 0;
    if (c.hat >= 0) {
        float a = c.hat * (float)M_PI / 4.0f;
        targetYaw = sinf(a) * 1.4f;
        targetPitch = cosf(a) * 0.7f;
        if (c.hat == 4) { targetYaw = (float)M_PI * 0.95f; targetPitch = 0.1f; }
    }
    _lookYaw += (targetYaw - _lookYaw) * (1.0f - expf(-6.0f * dt));
    _lookPitch += (targetPitch - _lookPitch) * (1.0f - expf(-6.0f * dt));
    simd_quatf look = simd_mul(simd_quaternion(-_lookYaw, simd_make_float3(0, 1, 0)),
                               simd_quaternion(_lookPitch, simd_make_float3(1, 0, 0)));

    simd_quatf shipQ = ps->move.orientation;
    if (!_hadPlayer || simd_length(_camOrientation.vector) < 0.5f) _camOrientation = shipQ;
    _camOrientation = simd_slerp(_camOrientation, shipQ, 1.0f - expf(-(_cockpit ? 30.0f : 7.0f) * dt));
    simd_quatf q = simd_mul(_cockpit ? shipQ : _camOrientation, look);

    float speed = simd_length(ps->move.velocity);
    // Ease boost effects in and out so toggling boost never pops the camera.
    _boostFx += ((ps->move.boosting ? 1.0f : 0.0f) - _boostFx) * (1.0f - expf(-4.0f * dt));
    float boostFx = _boostFx;
    simd_float3 offset = _cockpit ? kCockpitEye
                                  : simd_make_float3(0, 3.4f, 17.0f + speed * 0.012f + boostFx * 3.0f);
    simd_float3 pos = ps->move.origin + simd_act(_cockpit ? shipQ : _camOrientation, simd_act(look, offset));
    if (_cockpit) pos = ps->move.origin + simd_act(shipQ, offset);

    _shake = fmaxf(0, _shake - dt * 1.5f);
    // Smooth shake: two sines per axis, ~3-7 Hz, at frequencies with no common
    // pattern so it never visibly loops. The wobble is applied in camera space,
    // so shake stays the same relative to the screen whichever way the camera faces.
    // _shake (hits, explosions) falls off with a square curve; boost only adds a faint
    // rumble. The cockpit eye gets 15% of it all because the interior is centimetres
    // away and any movement makes the whole cockpit swim.
    float sh = _shake * _shake * 0.6f + boostFx * 0.015f;
    if (_cockpit) sh *= 0.15f;
    float t = (float)_time;
    simd_float3 wobble = simd_make_float3(sinf(t * 23.1f) * 0.6f + sinf(t * 37.7f + 1.3f) * 0.4f,
                                          sinf(t * 29.3f + 2.1f) * 0.6f + sinf(t * 41.9f + 0.7f) * 0.4f,
                                          sinf(t * 19.7f + 4.2f) * 0.6f + sinf(t * 33.1f + 3.3f) * 0.4f);
    pos += simd_act(q, wobble) * sh;

    _cameraNode.simdPosition = pos;
    _cameraNode.simdOrientation = q;
    _playerView.model.hidden = _cockpit;
    _cockpitModel.node.hidden = !_cockpit;

    SCNCamera *cam = _cameraNode.camera;
    cam.zNear = _cockpit ? 0.08 : 0.3;
    float fov = 68.0f + speed * 0.03f + boostFx * 8.0f;
    cam.fieldOfView += (fov - cam.fieldOfView) * (1.0f - expf(-3.0f * dt));
    cam.motionBlurIntensity = boostFx * 0.25f;
}

#pragma mark - HUD

- (BOOL)project:(simd_float3)world into:(CGPoint *)out {
    simd_float3 camFwd = simd_act(_cameraNode.simdOrientation, simd_make_float3(0, 0, -1));
    if (simd_dot(world - _cameraNode.simdPosition, camFwd) <= 0.1f) return NO;
    SCNVector3 p = [_view projectPoint:SCNVector3Make(world.x, world.y, world.z)];
    *out = CGPointMake(p.x, p.y);
    return YES;
}

- (void)fillTarget:(HUDTarget *)t at:(simd_float3)pos velocity:(simd_float3)vel radius:(float)radius size:(CGSize)size
            player:(const PlayerState *)ps {
    simd_float3 camPos = _cameraNode.simdPosition, me = ps->move.origin;
    CGPoint mid = CGPointMake(size.width / 2, size.height / 2);
    t->distance = simd_distance(pos, me);
    CGPoint p;
    BOOL front = [self project:pos into:&p];
    BOOL inside = front && p.x > 20 && p.y > 20 && p.x < size.width - 20 && p.y < size.height - 20;
    if (inside) {
        t->onScreen = YES;
        t->point = p;
        float d = simd_distance(pos, camPos);
        t->size = clampf(radius * 2.6f / fmaxf(d, 1.0f) * (float)size.height * 0.75f, 22, 260);
        simd_float3 relV = vel - ps->move.velocity;
        float tHit = t->distance / BOLT_SPEED;
        for (int k = 0; k < 2; k++) tHit = simd_distance(pos + relV * tHit, me) / BOLT_SPEED;
        CGPoint lp = CGPointZero;
        t->hasLead = t->distance < 1500 && [self project:pos + relV * tHit into:&lp];
        t->lead = lp;
    } else {
        simd_float3 local = simd_act(simd_inverse(_cameraNode.simdOrientation), pos - camPos);
        float ang = atan2f(local.y, local.x);
        float rx = size.width * 0.5f - 40, ry = size.height * 0.5f - 40;
        float cx = cosf(ang), cy = sinf(ang);
        float k = fminf(rx / fmaxf(fabsf(cx), 1e-3f), ry / fmaxf(fabsf(cy), 1e-3f));
        t->point = CGPointMake(mid.x + cx * k, mid.y + cy * k);
        t->angle = ang;
    }
}

- (BOOL)visible:(const EntityState *)s player:(const PlayerState *)ps {
    return s->stealthRange <= 0 || simd_distance(s->origin, ps->move.origin) < s->stealthRange;
}

- (BOOL)navPosition:(int)stat position:(simd_float3 *)p name:(NSString **)name {
    if (stat <= 0) return NO;
    NSArray *f = [[self cs:CS_NAVS + stat - 1] componentsSeparatedByString:@"|"];
    if (f.count < 4) return NO;
    *name = f[0];
    *p = simd_make_float3([f[1] floatValue], [f[2] floatValue], [f[3] floatValue]);
    return YES;
}

- (void)updateHUD:(const PlayerState *)ps controls:(ControlState)c {
    simd_float3 me = ps->move.origin, fwd = QuatForward(ps->move.orientation);
    uint16_t selected = (uint16_t)ps->stats[STAT_TARGET];
    EntityView *target = [self viewFor:selected];

    HUDFrame f = {0};
    CGSize size = _view.bounds.size;
    f.boresightVisible = [self project:me + fwd * 400.0f into:&f.boresight];
    f.mouseStick = _input.mouseStick;
    f.mouseCaptured = _input.mouseCaptured;
    f.throttle = ps->move.throttle;
    f.boosting = ps->move.boosting;
    f.boostEnergy = ps->move.boostEnergy;
    f.speed = simd_length(ps->move.velocity);
    f.hull = ps->hull;
    f.shield = ps->shield;
    f.kills = ps->stats[STAT_KILLS];
    f.deaths = ps->stats[STAT_DEATHS];
    f.playerDead = !ps->alive;
    f.damageFlash = _damageFlash;
    f.cockpit = _cockpit;
    f.torpedoes = ps->stats[STAT_TORPEDOES];
    f.status = _status;
    int aim = ps->stats[STAT_AIM_PART] - 1;
    if (target.capital && aim >= 0 && aim < target.capital.info.info->numParts) {
        EntityState ts = target.state;
        simd_float3 p = simd_act(ts.orientation, target.capital.info.info->parts[aim].center) + ts.origin;
        f.aimVisible = [self project:p into:&f.aim];
    }

    simd_float3 camPos = _cameraNode.simdPosition;
    simd_float3 sunPoint = camPos + _sky.sunDirection * 20000.0f;
    CGPoint sp;
    if ([self project:sunPoint into:&sp]) {
        float edge = fminf(fminf(sp.x, size.width - sp.x), fminf(sp.y, size.height - sp.y));
        float vis = clampf(edge / 150.0f + 0.3f, 0, 1);
        if (vis > 0) {
            NSArray *hits = [_scene.rootNode hitTestWithSegmentFromPoint:SCNVector3Make(camPos.x, camPos.y, camPos.z)
                                                                 toPoint:SCNVector3Make(camPos.x + _sky.sunDirection.x * 5000,
                                                                                        camPos.y + _sky.sunDirection.y * 5000,
                                                                                        camPos.z + _sky.sunDirection.z * 5000)
                                                                 options:@{ SCNHitTestOptionFirstFoundOnly : @YES,
                                                                            SCNHitTestBackFaceCullingKey : @YES,
                                                                            SCNHitTestIgnoreHiddenNodesKey : @YES }];
            for (SCNHitTestResult *h in hits) {
                if (!h.node.geometry || h.node.particleSystems || h.node == _dust) continue;
                if (_cockpit && [h.node.parentNode isEqual:_cockpitModel.node]) continue;
                vis = 0;
                break;
            }
        }
        f.sun = sp;
        f.sunVisibility = vis;
    }

    HUDTarget targets[MAX_HUD];
    NSUInteger n = 0;
    NSArray<EntityView *> *views = _views.allValues;
    for (EntityView *v in views) {
        if (v.kind != EntityFighter || n >= MAX_HUD) continue;
        EntityState s = v.state;
        HUDTarget t = {0};
        t.kind = s.team == TeamEnemy ? HUDKindEnemy : HUDKindFriend;
        t.selected = s.number == selected;
        t.health = s.hull;
        t.label = [self stringAt:s.name];
        [self fillTarget:&t at:s.origin velocity:s.velocity radius:v.ship.radius size:size player:ps];
        targets[n++] = t;
    }
    for (EntityView *v in views) {
        if (v.kind != EntityCapital || n >= MAX_HUD) continue;
        EntityState s = v.state;
        if ((s.flags & EF_DEAD) || ![self visible:&s player:ps]) continue;
        BOOL prop = (s.flags & EF_PROP) != 0, sel = s.number == selected;
        float d = simd_distance(s.origin, me);
        if (prop && d > ((s.flags & EF_MINE) ? 1500 : 3000) && !sel) continue;
        HUDTarget t = {0};
        t.kind = s.team == TeamEnemy ? HUDKindEnemy : (s.team == TeamFriend ? HUDKindFriend : HUDKindNeutral);
        t.capital = !prop;
        t.selected = sel;
        NSString *name = [self stringAt:s.name];
        t.label = prop ? (sel ? name : nil) : name;
        [self fillTarget:&t at:s.origin velocity:s.velocity radius:[self radiusOf:v] * 0.6f size:size player:ps];
        targets[n++] = t;
    }
    simd_float3 navPos;
    NSString *navName = nil;
    if (n < MAX_HUD && [self navPosition:ps->stats[STAT_NAV] position:&navPos name:&navName]) {
        HUDTarget t = {0};
        t.kind = HUDKindNav;
        t.label = navName;
        [self fillTarget:&t at:navPos velocity:ps->move.velocity radius:5 size:size player:ps];
        t.hasLead = NO;
        targets[n++] = t;
    }
    [_hud updateFrame:f targets:targets count:n];
    if (_cockpit) [self updateCockpit:ps controls:c];

#if TARGET_OS_IOS
    NSString *controller = _input.joystickName;
    NSString *inputText = controller ? [NSString stringWithFormat:@"CONTROLLER: %@", controller] : @"";
#else
    NSString *inputText = [NSString stringWithFormat:@"%@%@  |  %@  |  T target  G torpedo  H help  ESC menu",
                           _input.joystickName ? [NSString stringWithFormat:@"Joystick: %@ (%@)", _input.joystickName, _input.axisDescription] : @"No joystick",
                           _input.throttleFromJoystick ? @" [throttle: stick]" : @" [throttle: keys]",
                           _input.mouseCaptured ? @"mouse captured (ESC releases)" : @"click to capture mouse"];
#endif
    if (![inputText isEqualToString:_lastInputText]) {
        _lastInputText = inputText;
        [_hud setInputText:inputText];
    }
}

#pragma mark - Cockpit

- (void)updateCockpit:(const PlayerState *)ps controls:(ControlState)c {
    simd_float3 me = ps->move.origin, fwd = QuatForward(ps->move.orientation);
    uint16_t selected = (uint16_t)ps->stats[STAT_TARGET];
    CockpitFrame f = {0};
    f.throttle = ps->move.throttle;
    f.speed = simd_length(ps->move.velocity);
    f.maxSpeed = ps->params.maxSpeed;
    f.boostEnergy = ps->move.boostEnergy;
    f.hull = ps->hull;
    f.shield = ps->shield;
    f.damageFlash = _damageFlash;
    f.boosting = ps->move.boosting;
    f.alive = ps->alive;
    f.firing = c.fire && ps->alive;
    f.pitch = c.pitch;
    f.yaw = c.yaw;
    f.roll = c.roll;
    f.kills = ps->stats[STAT_KILLS];
    f.deaths = ps->stats[STAT_DEATHS];
    f.time = ps->missionTime;
    f.target = -1;
    f.nearest = FLT_MAX;
    f.torpedoes = ps->stats[STAT_TORPEDOES];
    f.objective = _objectiveSummary;

    simd_quatf inv = simd_inverse(ps->move.orientation);
    CockpitContact contacts[COCKPIT_MAX_CONTACTS];
    NSUInteger n = 0;
    NSMutableArray<EntityView *> *bodies = [NSMutableArray array];
    for (EntityView *v in _views.allValues) {
        EntityState s = v.state;
        if (v.kind == EntityFighter) [bodies addObject:v];
        else if (v.kind == EntityCapital && !(s.flags & EF_DEAD) && [self visible:&s player:ps]) [bodies addObject:v];
    }
    // Nearest first, so the scanner keeps what matters when it overflows.
    [bodies sortUsingComparator:^NSComparisonResult(EntityView *a, EntityView *b) {
        if (a.number == selected) return NSOrderedAscending;
        if (b.number == selected) return NSOrderedDescending;
        float da = simd_distance(a.state.origin, me), db = simd_distance(b.state.origin, me);
        return da < db ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (EntityView *v in bodies) {
        if (n >= COCKPIT_MAX_CONTACTS) break;
        EntityState s = v.state;
        BOOL fighter = v.kind == EntityFighter;
        simd_float3 rel = s.origin - me;
        float dist = simd_length(rel);
        float radius = [self radiusOf:v];
        CockpitContact k = {0};
        k.local = simd_act(inv, rel);
        k.team = (Team)s.team;
        k.orientation = simd_mul(inv, s.orientation);
        k.hull = s.hull;
        k.shield = s.shield;
        if (fighter) {
            k.geometry = [ShipView geometryForClass:v.ship.shipClass];
            k.holoScale = 0.0075f;
            k.name = [self stringAt:s.name] ?: @(FighterSpecFor(v.ship.shipClass).displayName);
            k.className = s.team == TeamEnemy ? @"Skarn fighter" : @"Concord fighter";
            k.attacking = s.team == TeamEnemy && (s.flags & EF_ATTACKING) && s.target == ps->entity &&
                          simd_dot(QuatForward(s.orientation), -rel / fmaxf(dist, 1)) > 0.8f;
            if (k.attacking && dist < 700 && k.local.z > 0) f.six = YES;
            if (s.team == TeamEnemy) f.nearest = fminf(f.nearest, dist);
        } else {
            BOOL prop = (s.flags & EF_PROP) != 0;
            k.capital = !prop;
            k.geometry = v.capital.body.geometry;
            k.holoScale = 0.04f / fmaxf(radius, 1);
            k.name = [self stringAt:s.name];
            k.className = [self stringAt:s.className];
            k.shielded = (s.flags & EF_SHIELDED) != 0;
            if (s.team == TeamEnemy && ((s.flags & EF_MINE) || !prop)) f.nearest = fminf(f.nearest, dist - radius);
        }
        if (s.number == selected) {
            f.target = (int)n;
            simd_float3 relV = s.velocity - ps->move.velocity;
            f.closingSpeed = -simd_dot(relV, rel / fmaxf(dist, 1));
            float tHit = dist / BOLT_SPEED;
            for (int kk = 0; kk < 2; kk++) tHit = simd_distance(s.origin + relV * tHit, me) / BOLT_SPEED;
            simd_float3 lead = simd_normalize(s.origin + relV * tHit - me);
            float cone = fighter ? 2.5f : 2.5f + atanf(radius / fmaxf(dist, 1)) * 57.3f;
            f.lock = dist < 1200 + (fighter ? 0 : radius) && simd_dot(lead, fwd) > cosf(cone * (float)M_PI / 180.0f);
        }
        contacts[n++] = k;
    }
    [_cockpitModel updateFrame:f contacts:contacts count:n];
}

@end
