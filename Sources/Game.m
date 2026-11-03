#import "Game.h"
#import "Ship.h"
#import "SpaceSky.h"
#import "HUD.h"
#import "Effects.h"

#define ENEMY_COUNT 5
#define MAX_BOLTS 160

static const float kBoltSpeed = 900.0f;
static const float kBoltLife = 1.4f;

typedef struct {
    simd_float3 position, velocity;
    float life;
    BOOL fromPlayer;
    BOOL active;
} Bolt;

typedef NS_ENUM(NSInteger, AIMode) { AIModeAttack, AIModeEvade, AIModeReposition };

static float frand(void) { return (float)arc4random_uniform(1000000) / 1000000.0f; }
static float srand1(void) { return frand() * 2.0f - 1.0f; }
static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
static simd_float3 randomUnit(void) {
    simd_float3 v;
    do { v = simd_make_float3(srand1(), srand1(), srand1()); } while (simd_length_squared(v) > 1 || simd_length_squared(v) < 0.01f);
    return simd_normalize(v);
}

static simd_quatf LookRotation(simd_float3 forward, simd_float3 up) {
    simd_float3 f = simd_normalize(forward);
    simd_float3 r = simd_normalize(simd_cross(f, up));
    simd_float3 u = simd_cross(r, f);
    simd_float3x3 m = simd_matrix(r, u, -f);
    return simd_quaternion(m);
}

@interface Enemy : NSObject
@property (nonatomic, strong) Ship *ship;
@property (nonatomic) AIMode mode;
@property (nonatomic) double modeUntil;
@property (nonatomic) simd_float3 evadePoint;
@property (nonatomic) float aimError;
@end
@implementation Enemy
@end

@implementation Game {
    __weak SCNView *_view;
    Input *_input;
    SCNScene *_scene;
    SpaceSky *_sky;
    HUD *_hud;

    Ship *_player;
    NSMutableArray<Enemy *> *_enemies;
    SCNNode *_cameraNode;
    SCNNode *_sunLight;
    SCNNode *_engineLight;
    SCNNode *_dust;

    Bolt _bolts[MAX_BOLTS];
    SCNNode *_boltNodes[MAX_BOLTS];
    Effects *_fx;

    double _lastTime;
    double _time;
    simd_quatf _camOrientation;
    simd_float3 _camPosition;
    BOOL _cockpit;
    float _shake;
    float _damageFlash;
    float _lookYaw, _lookPitch;
    int _kills, _deaths;
    NSString *_lastInputText;
}

- (instancetype)initWithView:(SCNView *)view input:(Input *)input {
    if ((self = [super init])) {
        _view = view;
        _input = input;
        [self buildScene];
        view.scene = _scene;
        view.pointOfView = _cameraNode;
        view.delegate = self;
        view.playing = YES;
        view.loops = YES;
        view.rendersContinuously = YES;
        view.preferredFramesPerSecond = 120;
        view.antialiasingMode = SCNAntialiasingModeMultisampling4X;
        view.backgroundColor = [NSColor blackColor];
        // Compile effect shaders now rather than on the first explosion.
        [view prepareObjects:[_fx warmupNodes] withCompletionHandler:nil];
        _hud = [[HUD alloc] initWithSize:view.bounds.size];
        view.overlaySKScene = _hud;
    }
    return self;
}

#pragma mark - Scene

- (void)buildScene {
    _scene = [SCNScene scene];

    _sky = [[SpaceSky alloc] initWithDevice:_view.device faceSize:1536 seed:1337];
    NSLog(@"Game: sky baked in %.2fs", _sky.bakeSeconds);
    _scene.background.contents = _sky.cubeTexture;
    _scene.lightingEnvironment.contents = _sky.cubeTexture;
    _scene.lightingEnvironment.intensity = 1.6;

    SCNLight *sun = [SCNLight light];
    sun.type = SCNLightTypeDirectional;
    sun.color = [NSColor colorWithRed:1.0 green:0.94 blue:0.86 alpha:1];
    sun.intensity = 2600;
    sun.castsShadow = YES;
    sun.shadowMapSize = CGSizeMake(2048, 2048);
    sun.shadowSampleCount = 8;
    sun.shadowRadius = 2;
    sun.orthographicScale = 40;
    sun.zNear = 1;
    sun.zFar = 600;
    sun.shadowColor = [NSColor colorWithWhite:0 alpha:0.85];
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
    // Screen-space bloom does the glow work: emitters write HDR values > 1
    // (bolt cores, flames, fire spheres, sun) instead of piling up particles.
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

    _dust = [_sky makeDustNode];
    [_scene.rootNode addChildNode:_dust];

    _player = [Ship shipWithClass:ShipClassExecutioner smoke:YES];
    _player.maxSpeed = 160;
    [_scene.rootNode addChildNode:_player.node];
    simd_float3 startDir = simd_make_float3(0, 0, -1);
    const char *look = getenv("SF_LOOK");  // debug: start facing "sun" or "planet"
    if (look && !strcmp(look, "sun")) startDir = simd_normalize(_sky.sunDirection + simd_make_float3(0, -0.25f, 0));
    if (look && !strcmp(look, "planet")) startDir = simd_normalize(_sky.planetDirection + simd_make_float3(0, -0.1f, 0));
    float lx, ly, lz;
    if (look && sscanf(look, "%f,%f,%f", &lx, &ly, &lz) == 3) startDir = simd_normalize(simd_make_float3(lx, ly, lz));
    [_player resetAt:simd_make_float3(0, 0, 0) facing:LookRotation(startDir, simd_make_float3(0, 1, 0))];
    _player.throttle = 0;

    // Engine glow lights up the rear of the player's ship.
    SCNLight *glow = [SCNLight light];
    glow.type = SCNLightTypeOmni;
    glow.color = [NSColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1];
    glow.attenuationStartDistance = 0;
    glow.attenuationEndDistance = 18;
    glow.intensity = 0;
    _engineLight = [SCNNode node];
    _engineLight.light = glow;
    _engineLight.position = SCNVector3Make(0, 0.5, 6.0);
    [_player.node addChildNode:_engineLight];

    _enemies = [NSMutableArray array];
    for (int i = 0; i < ENEMY_COUNT; i++) {
        Enemy *e = [Enemy new];
        e.ship = [Ship shipWithClass:(i % 2 ? ShipClassInsurgent : ShipClassSpitfire) smoke:YES];
        e.ship.maxSpeed = 135 + 10 * (i % 3);
        e.ship.turnRate = 0.8f;
        [_scene.rootNode addChildNode:e.ship.node];
        [self spawnEnemy:e distance:700 + i * 150];
        [_enemies addObject:e];
    }

    _fx = [[Effects alloc] initWithScene:_scene];
    [self buildBolts];

    _camOrientation = _player.orientation;
    _camPosition = _player.position + simd_act(_camOrientation, simd_make_float3(0, 3.4f, 17));
}

- (void)buildBolts {
    for (int i = 0; i < MAX_BOLTS; i++) {
        SCNNode *n = [_fx makeBoltNode];
        n.hidden = YES;
        [_scene.rootNode addChildNode:n];
        _boltNodes[i] = n;
    }
}

- (void)spawnEnemy:(Enemy *)e distance:(float)distance {
    simd_float3 dir = randomUnit();
    simd_float3 pos = _player.position + dir * distance;
    simd_float3 toPlayer = simd_normalize(_player.position - pos);
    [e.ship resetAt:pos facing:LookRotation(toPlayer + randomUnit() * 0.3f, simd_make_float3(0, 1, 0))];
    e.ship.velocity = e.ship.forward * 100;
    e.mode = AIModeReposition;
    e.modeUntil = _time + 1.5;
    e.aimError = 0.6f + frand() * 0.8f;
}

#pragma mark - Loop

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    float dt = _lastTime > 0 ? (float)(time - _lastTime) : 1.0f / 60.0f;
    _lastTime = time;
    dt = clampf(dt, 0.0005f, 1.0f / 20.0f);
    _time += dt;

    InputAction actions = [_input consumeActions];
    if (actions & InputActionToggleCamera) _cockpit = !_cockpit;
    if (actions & InputActionToggleHelp) [_hud toggleHelp];
    if (actions & InputActionRestart) [self restart];

    ControlState controls = [_input poll:dt];
    static double lastLog;
    static int frames;
    frames++;
    if (getenv("SF_DEBUGINPUT") && _time - lastLog > 0.5) {
        NSLog(@"fps %.0f", frames / (_time - lastLog));
        frames = 0;
        lastLog = _time;
        NSLog(@"controls p=%.2f y=%.2f r=%.2f thr=%.2f hat=%d fire=%d | angVel=(%.2f %.2f %.2f) hull=%.2f",
              controls.pitch, controls.yaw, controls.roll, controls.throttle, controls.hat, controls.fire,
              _player.angularVelocity.x, _player.angularVelocity.y, _player.angularVelocity.z, _player.hull);
    }

    if (_player.alive) {
        [_player stepWithControls:controls dt:dt];
        if (controls.fire && _time - _player.lastShot > 0.11) {
            _player.lastShot = _time;
            [self fireFrom:_player direction:_player.forward player:YES];
        }
    } else if (_time - _player.deathTime > 3.0) {
        [self respawnPlayer];
    }
    _engineLight.light.intensity = _player.alive ? 60 + 900 * _player.exhaust.level : 0;

    for (Enemy *e in _enemies) [self thinkEnemy:e dt:dt];
    [self debugEffects];
    [self updateBolts:dt];
    [self updateCamera:dt controls:controls];

    // Directional shadow volume follows the player.
    _sunLight.simdPosition = _player.position + _sky.sunDirection * 250.0f;
    [_sunLight simdLookAt:_player.position];
    [_sky updateDust:_dust cameraPosition:_cameraNode.simdPosition velocity:_player.velocity];

    _damageFlash = fmaxf(0, _damageFlash - dt * 2.5f);
    [self updateHUD:controls];
}

- (void)restart {
    _kills = _deaths = 0;
    [self respawnPlayer];
    for (Enemy *e in _enemies) [self spawnEnemy:e distance:700 + frand() * 600];
}

- (void)respawnPlayer {
    [_player resetAt:_player.position facing:_player.orientation];
}

// Debug: SF_BOOM=<seconds> blows up an enemy in front of the player then, and
// shield-hits another one, so effects can be checked in snapshots.
- (void)debugEffects {
    static double next = -1;
    const char *boom = getenv("SF_BOOM");
    if (!boom || _enemies.count < 2) return;
    if (next < 0) next = atof(boom);
    if (_time < next) return;
    const char *every = getenv("SF_BOOMEVERY");  // repeat for stress tests
    next = every ? _time + atof(every) : DBL_MAX;
    Ship *a = _enemies[0].ship, *b = _enemies[1].ship;
    a.position = _player.position + _player.forward * 110.0f + _player.up * 8.0f;
    a.alive = YES;
    [self destroyShip:a];
    b.position = _player.position + _player.forward * 60.0f + _player.right * 16.0f;
    b.orientation = _player.orientation;
    [b takeDamage:0.3f];
    [_fx impactAt:b.position + b.right * 3.0f player:YES shielded:YES];
    [_fx impactAt:b.position - b.right * 2.0f player:YES shielded:NO];
}

#pragma mark - AI

- (void)thinkEnemy:(Enemy *)e dt:(float)dt {
    Ship *s = e.ship;
    if (!s.alive) {
        if (_time - s.deathTime > 4.0) [self spawnEnemy:e distance:1200 + frand() * 600];
        return;
    }

    simd_float3 toPlayer = _player.position - s.position;
    float dist = simd_length(toPlayer);
    simd_float3 dirToPlayer = toPlayer / fmaxf(dist, 1e-3f);

    // Mode changes: break off when too close, re-engage after a while.
    if (e.mode == AIModeAttack && (dist < 70 || !_player.alive)) {
        e.mode = AIModeEvade;
        e.modeUntil = _time + 2.0 + frand() * 2.0;
        e.evadePoint = s.position + (randomUnit() + s.forward) * 600.0f;
    } else if (e.mode != AIModeAttack && _time > e.modeUntil && _player.alive) {
        e.mode = AIModeAttack;
    }
    if (dist > 2500) e.mode = AIModeAttack;

    simd_float3 aimPoint;
    float throttle = 0.85f;
    BOOL boost = NO;
    if (e.mode == AIModeAttack) {
        // Lead the target, with a per-pilot wobble so they are not aimbots.
        float tLead = dist / kBoltSpeed;
        simd_float3 wobble = simd_make_float3(sinf(_time * 1.3f + s.radius), cosf(_time * 0.9f), sinf(_time * 0.7f)) * e.aimError * 6.0f;
        aimPoint = _player.position + (_player.velocity - s.velocity * 0.0f) * tLead + wobble;
        float facing = simd_dot(s.forward, dirToPlayer);
        if (facing < -0.2f && dist < 400) boost = s.boostEnergy > 0.5f;   // target behind: extend
        if (dist < 220 && facing > 0.7f) throttle = 0.55f;               // don't overshoot
        if (dist > 900) boost = s.boostEnergy > 0.3f;
    } else {
        aimPoint = e.evadePoint;
        throttle = 1.0f;
        boost = s.boostEnergy > 0.4f;
    }

    // Steering: express the aim direction in ship space, roll so the target
    // sits "above" the canopy, then pull — the way a pilot turns.
    simd_float3 local = simd_act(simd_inverse(s.orientation), simd_normalize(aimPoint - s.position));
    float yawErr = atan2f(local.x, -local.z);
    float pitchErr = atan2f(local.y, -local.z);
    float offAxis = acosf(clampf(-local.z, -1, 1));
    float rollErr = atan2f(local.x, local.y);
    ControlState c = {0};
    c.throttle = throttle;
    c.boost = boost;
    float bankWeight = clampf((offAxis - 0.15f) * 2.0f, 0, 1);
    c.roll = clampf(rollErr * 1.8f * bankWeight, -1, 1);
    c.pitch = clampf(pitchErr * 2.5f, -1, 1);
    c.yaw = clampf(yawErr * 1.5f, -1, 1);
    [s stepWithControls:c dt:dt];

    // Fire when the target is near the nose.
    if (e.mode == AIModeAttack && _player.alive && dist < 750) {
        simd_float3 leadDir = simd_normalize(aimPoint - s.position);
        if (simd_dot(s.forward, leadDir) > 0.992f && _time - s.lastShot > 0.22 + frand() * 0.25) {
            s.lastShot = _time;
            [self fireFrom:s direction:simd_normalize(s.forward + randomUnit() * 0.008f) player:NO];
        }
    }
}

#pragma mark - Weapons

- (void)fireFrom:(Ship *)ship direction:(simd_float3)dir player:(BOOL)player {
    for (int i = 0; i < MAX_BOLTS; i++) {
        if (_bolts[i].active) continue;
        Bolt *b = &_bolts[i];
        b->active = YES;
        b->fromPlayer = player;
        b->life = kBoltLife;
        b->position = [ship nextGunWorldPosition];
        b->velocity = ship.velocity + dir * kBoltSpeed;
        SCNNode *n = _boltNodes[i];
        [_fx styleBolt:n player:player];
        [_fx muzzleFlashOn:ship.node local:ship.lastGunLocal player:player];
        n.simdPosition = b->position;
        n.simdOrientation = simd_quaternion(simd_make_float3(0, 1, 0), simd_normalize(b->velocity));
        n.hidden = NO;
        return;
    }
}

// Segment vs sphere: does p0->p1 pass within r of c?
static BOOL SegmentHits(simd_float3 p0, simd_float3 p1, simd_float3 c, float r) {
    simd_float3 d = p1 - p0;
    float len2 = simd_length_squared(d);
    float t = len2 > 0 ? clampf(simd_dot(c - p0, d) / len2, 0, 1) : 0;
    return simd_distance_squared(p0 + d * t, c) < r * r;
}

- (void)updateBolts:(float)dt {
    for (int i = 0; i < MAX_BOLTS; i++) {
        Bolt *b = &_bolts[i];
        if (!b->active) continue;
        simd_float3 p0 = b->position;
        simd_float3 p1 = p0 + b->velocity * dt;
        b->position = p1;
        b->life -= dt;
        BOOL hit = NO;
        if (b->fromPlayer) {
            for (Enemy *e in _enemies) {
                Ship *s = e.ship;
                if (s.alive && SegmentHits(p0, p1, s.position, s.radius * 0.85f)) {
                    BOOL shielded = [s takeDamage:0.12f];
                    [_fx impactAt:p1 player:YES shielded:shielded];
                    if (e.mode == AIModeAttack && frand() < 0.35f) {
                        e.mode = AIModeEvade;
                        e.modeUntil = _time + 1.5 + frand() * 1.5;
                        e.evadePoint = s.position + (randomUnit() + s.right * (frand() < 0.5f ? -1.0f : 1.0f)) * 500.0f;
                    }
                    if (!s.alive) [self destroyShip:s];
                    hit = YES;
                    break;
                }
            }
        } else if (_player.alive && SegmentHits(p0, p1, _player.position, _player.radius * 0.8f)) {
            BOOL shielded = [_player takeDamage:0.07f];
            [_fx impactAt:p1 player:NO shielded:shielded];
            _damageFlash = 1;
            _shake = fmaxf(_shake, 0.35f);
            if (!_player.alive) {
                _deaths++;
                [self destroyShip:_player];
            }
            hit = YES;
        }
        if (hit || b->life <= 0) {
            b->active = NO;
            _boltNodes[i].hidden = YES;
        } else {
            _boltNodes[i].simdPosition = p1;
        }
    }
}

#pragma mark - Effects

- (void)destroyShip:(Ship *)s {
    s.alive = NO;
    s.deathTime = _time;
    s.node.hidden = YES;
    [s.exhaust setEnabled:NO];
    if (s != _player) _kills++;
    [_fx explosionAt:s.position velocity:s.velocity hullMaterial:s.model.geometry.firstMaterial];
    float d = simd_distance(s.position, _player.position);
    _shake = fmaxf(_shake, clampf(1.0f - d / 300.0f, 0, 1));
}

#pragma mark - Camera

- (void)updateCamera:(float)dt controls:(ControlState)c {
    // Hat switch looks around the ship.
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

    // Chase camera lags the ship's rotation a little, which sells the turns.
    simd_quatf shipQ = _player.orientation;
    _camOrientation = simd_slerp(_camOrientation, shipQ, 1.0f - expf(-(_cockpit ? 30.0f : 7.0f) * dt));
    simd_quatf q = simd_mul(_cockpit ? shipQ : _camOrientation, look);

    float speed = simd_length(_player.velocity);
    float boostFx = _player.boosting ? 1.0f : 0.0f;
    simd_float3 offset = _cockpit ? simd_make_float3(0, 1.0f, -2.2f)
                                  : simd_make_float3(0, 3.4f, 17.0f + speed * 0.012f + boostFx * 3.0f);
    simd_float3 pos = _player.position + simd_act(_cockpit ? shipQ : _camOrientation, simd_act(look, offset));
    if (_cockpit) pos = _player.position + simd_act(shipQ, offset);

    _shake = fmaxf(0, _shake - dt * 1.5f);
    float sh = _shake * _shake * 0.6f + boostFx * 0.04f;
    pos += randomUnit() * sh;

    _cameraNode.simdPosition = pos;
    _cameraNode.simdOrientation = q;
    _player.model.hidden = _cockpit;

    SCNCamera *cam = _cameraNode.camera;
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

- (void)updateHUD:(ControlState)c {
    HUDFrame f = {0};
    CGSize size = _view.bounds.size;
    f.boresightVisible = [self project:_player.position + _player.forward * 400.0f into:&f.boresight];
    f.mouseStick = _input.mouseStick;
    f.mouseCaptured = _input.mouseCaptured;
    f.throttle = _player.throttle;
    f.boosting = _player.boosting;
    f.boostEnergy = _player.boostEnergy;
    f.speed = simd_length(_player.velocity);
    f.hull = _player.hull;
    f.shield = _player.shield;
    f.kills = _kills;
    f.deaths = _deaths;
    f.playerDead = !_player.alive;
    f.damageFlash = _damageFlash;

    // Lens flare when the sun is in view and not blocked by a ship.
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
                                                                            SCNHitTestBackFaceCullingKey : @YES }];
            for (SCNHitTestResult *h in hits) if (h.node.geometry && !h.node.particleSystems && h.node != _dust) { vis = 0; break; }
        }
        f.sun = sp;
        f.sunVisibility = vis;
    }

    HUDTarget targets[ENEMY_COUNT];
    NSUInteger n = 0;
    CGPoint mid = CGPointMake(size.width / 2, size.height / 2);
    for (Enemy *e in _enemies) {
        Ship *s = e.ship;
        if (!s.alive) continue;
        HUDTarget t = {0};
        t.distance = simd_distance(s.position, _player.position);
        t.health = s.hull;
        CGPoint p;
        BOOL front = [self project:s.position into:&p];
        BOOL inside = front && p.x > 20 && p.y > 20 && p.x < size.width - 20 && p.y < size.height - 20;
        if (inside) {
            t.onScreen = YES;
            t.point = p;
            float d = simd_distance(s.position, camPos);
            t.size = clampf(s.radius * 2.6f / fmaxf(d, 1.0f) * (float)size.height * 0.75f, 22, 160);
            // Lead indicator: where to shoot so a bolt meets the target.
            simd_float3 relV = s.velocity - _player.velocity;
            float tHit = t.distance / kBoltSpeed;
            for (int k = 0; k < 2; k++) tHit = simd_distance(s.position + relV * tHit, _player.position) / kBoltSpeed;
            CGPoint lp = CGPointZero;
            t.hasLead = t.distance < 1500 && [self project:s.position + relV * tHit into:&lp];
            t.lead = lp;
        } else {
            // Edge arrow pointing toward the enemy in camera space.
            simd_float3 local = simd_act(simd_inverse(_cameraNode.simdOrientation), s.position - camPos);
            float ang = atan2f(local.y, local.x);
            float rx = size.width * 0.5f - 40, ry = size.height * 0.5f - 40;
            float cx = cosf(ang), cy = sinf(ang);
            float k = fminf(rx / fmaxf(fabsf(cx), 1e-3f), ry / fmaxf(fabsf(cy), 1e-3f));
            t.point = CGPointMake(mid.x + cx * k, mid.y + cy * k);
            t.angle = ang;
        }
        targets[n++] = t;
    }
    [_hud updateFrame:f targets:targets count:n];

    NSString *inputText = [NSString stringWithFormat:@"%@%@  |  %@  |  H help",
                           _input.joystickName ? [NSString stringWithFormat:@"Joystick: %@ (%@)", _input.joystickName, _input.axisDescription] : @"No joystick",
                           _input.throttleFromJoystick ? @" [throttle: stick]" : @" [throttle: keys]",
                           _input.mouseCaptured ? @"mouse captured (ESC releases)" : @"click to capture mouse"];
    if (![inputText isEqualToString:_lastInputText]) {
        _lastInputText = inputText;
        [_hud setInputText:inputText];
    }
}

@end
