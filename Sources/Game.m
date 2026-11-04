#import "Game.h"
#import "Ship.h"
#import "SpaceSky.h"
#import "HUD.h"
#import "Effects.h"
#import "Cockpit.h"
#import "Capital.h"
#import "Mission.h"
#import "Briefing.h"
#import "Loading.h"
#import <stdatomic.h>

#define MAX_BOLTS 480
#define MAX_TORPEDOES 12
#define MAX_HUD 64

static const float kBoltSpeed = 900.0f;
static const float kTurretBoltSpeed = 700.0f;
static const float kBoltLife = 1.6f;
static const simd_float3 kCockpitEye = {0, 1.0f, -2.2f};

typedef struct {
    simd_float3 position, velocity;
    float life;
    float damage;        // against fighters
    float capDamage;     // against capital ships and props
    Team team;
    BOOL fromPlayer;
    BOOL active;
} Bolt;

typedef NS_ENUM(NSInteger, AIMode) { AIModeAttack, AIModeEvade, AIModeReposition };
typedef NS_ENUM(NSInteger, GameState) { GameStateLoading, GameStateMenu, GameStateFlying, GameStateOver };

// What the loading screen says while the background queue is on each step.
typedef NS_ENUM(int, LoadStage) {
    LoadStageStart, LoadStageSky, LoadStageCockpit, LoadStageFleet, LoadStageFields,
    LoadStageWings, LoadStageUpload, LoadStageShaders, LoadStageReady,
};
static NSString *LoadStatus(LoadStage s) {
    switch (s) {
        case LoadStageStart: return @"LOADING";
        case LoadStageSky: return @"CHARTING STARFIELD";
        case LoadStageCockpit: return @"POWERING UP COCKPIT";
        case LoadStageFleet: return @"PLOTTING CAPITAL SHIPS";
        case LoadStageFields: return @"SURVEYING DEBRIS FIELDS";
        case LoadStageWings: return @"SCRAMBLING FIGHTER WINGS";
        case LoadStageUpload: return @"UPLOADING GEOMETRY AND TEXTURES";
        case LoadStageShaders: return @"COMPILING SHADERS";
        case LoadStageReady: return @"READY";
    }
    return @"LOADING";
}

static const double kMinMissionLoadSeconds = 1.2;   // long enough to read the title card

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
    if (fabsf(simd_dot(f, up)) > 0.98f) up = simd_make_float3(1, 0, 0);
    simd_float3 r = simd_normalize(simd_cross(f, up));
    simd_float3 u = simd_cross(r, f);
    simd_float3x3 m = simd_matrix(r, u, -f);
    return simd_quaternion(m);
}

// simd_float3 has no ObjC type encoding; store it as four floats.
static NSValue *Vec3Value(simd_float3 v) { return [NSValue valueWithBytes:&v objCType:"[4f]"]; }

static Team TeamNamed(NSString *s) {
    if ([s isEqualToString:@"enemy"]) return TeamEnemy;
    if ([s isEqualToString:@"neutral"]) return TeamNeutral;
    return TeamFriend;
}

static ShipClass ClassNamed(NSString *s) {
    if ([s isEqualToString:@"Talon"]) return ShipClassInsurgent;
    if ([s isEqualToString:@"Executioner"]) return ShipClassExecutioner;
    return ShipClassSpitfire;
}

static NSString *DisplayClass(ShipClass c) {
    switch (c) {
        case ShipClassExecutioner: return @"Executioner";
        case ShipClassSpitfire: return @"Wasp";
        case ShipClassInsurgent: return @"Talon";
    }
}

// Segment vs sphere: does p0->p1 pass within r of c?
static BOOL SegmentHits(simd_float3 p0, simd_float3 p1, simd_float3 c, float r) {
    simd_float3 d = p1 - p0;
    float len2 = simd_length_squared(d);
    float t = len2 > 0 ? clampf(simd_dot(c - p0, d) / len2, 0, 1) : 0;
    return simd_distance_squared(p0 + d * t, c) < r * r;
}

#pragma mark - Pilots and projectiles

// An AI-flown fighter: its ship, its team's orders, and its current target
// (a Ship or a Capital).
@interface Pilot : NSObject
@property (nonatomic, strong) Ship *ship;
@property (nonatomic) AIMode mode;
@property (nonatomic) double modeUntil, retargetAt;
@property (nonatomic) simd_float3 evadePoint;
@property (nonatomic) float aimError;
@property (nonatomic, copy) NSString *order, *orderTarget, *wave, *callsign;
@property (nonatomic, weak) id target;
@end
@implementation Pilot
@end

@interface Torpedo : NSObject
@property (nonatomic, strong) SCNNode *node;
@property (nonatomic) simd_float3 position, velocity;
@property (nonatomic) float life;
@property (nonatomic) Team team;
@property (nonatomic, weak) id target;
@property (nonatomic, weak) Subsystem *aim;
@end
@implementation Torpedo
@end

// Generic accessors over the two kinds of things that fly: Ship and Capital.
static simd_float3 BodyPosition(id b) { return [b isKindOfClass:[Ship class]] ? ((Ship *)b).position : ((Capital *)b).position; }
static simd_float3 BodyVelocity(id b) { return [b isKindOfClass:[Ship class]] ? ((Ship *)b).velocity : ((Capital *)b).velocity; }
static float BodyRadius(id b) { return [b isKindOfClass:[Ship class]] ? ((Ship *)b).radius : ((Capital *)b).radius; }
static BOOL BodyAlive(id b) {
    if (!b) return NO;
    if ([b isKindOfClass:[Ship class]]) return ((Ship *)b).alive;
    Capital *c = b;
    return c.alive && !c.departed;
}
static Team BodyTeam(id b) { return [b isKindOfClass:[Ship class]] ? ((Ship *)b).team : ((Capital *)b).team; }

#pragma mark - Game

@implementation Game {
    __weak SCNView *_view;
    Input *_input;
    SCNScene *_scene;
    SpaceSky *_sky;
    HUD *_hud;
    Briefing *_briefing;
    Loading *_loading;
    Cockpit *_cockpitModel;
    Effects *_fx;

    Ship *_player;
    NSMutableArray<Pilot *> *_pilots;
    NSMutableArray<Capital *> *_capitals;
    SCNNode *_cameraNode, *_sunLight, *_engineLight, *_dust;

    Bolt _bolts[MAX_BOLTS];
    SCNNode *_boltNodes[MAX_BOLTS];
    NSMutableArray<Torpedo *> *_torpedoes;

    double _lastTime, _time;
    simd_quatf _camOrientation;
    BOOL _cockpit;
    float _shake, _damageFlash, _lookYaw, _lookPitch;
    float _boostFx;   // 0..1, eased toward _player.boosting; drives every boost camera effect
    double _lastBump;
    int _kills, _deaths;
    NSString *_lastInputText;

    // Mission
    GameState _state;
    NSUInteger _missionIndex;
    NSDictionary *_mission;
    double _missionTime, _endAt;
    BOOL _success;
    NSArray<Objective *> *_objectives;
    NSMutableArray<NSDictionary *> *_pendingWaves, *_pendingEntities, *_pendingMessages;
    NSMutableSet<NSString *> *_spawned, *_navsVisited;
    NSMutableDictionary<NSString *, NSValue *> *_navs;
    NSMutableDictionary<NSString *, NSString *> *_navNames;
    int _torpedoCount;
    id _selected;
    Subsystem *_aimSubsystem;
    NSString *_currentNav, *_status;
    NSString *_objectiveSummary;
    BOOL _objectivesDirty;
    NSMutableArray *_explosionQueue;   // [time, Capital] pairs for break-up sequences
    Pilot *_autopilot;                 // debug: SF_AUTOPILOT flies the player with the AI

    // Loading: content is built on _loadQueue into detached nodes, uploaded to
    // the GPU with -prepareObject:, then attached on the render thread.
    dispatch_queue_t _loadQueue;
    SCNNode *_world;                   // parent of every mission node (identity transform)
    SpaceSky *_nextSky;
    SCNNode *_nextDust;
    _Atomic float _loadProgress;
    _Atomic int _loadStage;
    _Atomic bool _loadDone;
    double _loadStartedAt;
    BOOL _booted, _revealing;
}

- (instancetype)initWithView:(SCNView *)view input:(Input *)input {
    if ((self = [super init])) {
        _view = view;
        _input = input;
        _loadQueue = dispatch_queue_create("SpaceFight.loading", DISPATCH_QUEUE_SERIAL);
        _hud = [[HUD alloc] initWithSize:view.bounds.size];
        _briefing = [[Briefing alloc] initWithSize:view.bounds.size];
        _loading = [[Loading alloc] initWithSize:view.bounds.size];
        [_loading showTitle:@"Kestrel Frontier" kicker:@"SPACE FIGHT"
                     detail:@"CNS BASTION  /  LANCER FLIGHT"];

        // Show the loading card over an empty scene right away; the real scene
        // is built off the main thread and swapped in when it is ready.
        _state = GameStateLoading;
        SCNScene *placeholder = [SCNScene scene];
        placeholder.background.contents = [NSColor blackColor];
        view.scene = placeholder;
        view.overlaySKScene = _loading;
        view.delegate = self;
        view.playing = YES;
        view.loops = YES;
        view.rendersContinuously = YES;
        view.preferredFramesPerSecond = 120;
        view.antialiasingMode = SCNAntialiasingModeMultisampling4X;
        view.backgroundColor = [NSColor blackColor];
        _loadStartedAt = 0;
        dispatch_async(_loadQueue, ^{ [self bootInBackground]; });
    }
    return self;
}

#pragma mark - Loading

- (void)reportStage:(LoadStage)stage progress:(float)progress {
    atomic_store(&_loadStage, stage);
    atomic_store(&_loadProgress, progress);
}

// Upload a hierarchy to the GPU (buffers, textures, shader variants) node by
// node, so the bar moves and the first rendered frame doesn't stall.
- (void)prepare:(NSArray *)objects view:(SCNView *)view from:(float)p0 to:(float)p1 {
    NSUInteger n = objects.count;
    for (NSUInteger i = 0; i < n; i++) {
        [view prepareObject:objects[i] shouldAbortBlock:nil];
        atomic_store(&_loadProgress, p0 + (p1 - p0) * (float)(i + 1) / (float)n);
    }
}

// Load queue: the whole scene, which nobody is rendering yet.
- (void)bootInBackground {
    CFTimeInterval t0 = CACurrentMediaTime();
    SCNView *view = _view;
    [SCNTransaction begin];
    [SCNTransaction setDisableActions:YES];
    [self buildScene];
    [SCNTransaction commit];
    [SCNTransaction flush];
    [self reportStage:LoadStageShaders progress:0.7f];
    NSMutableArray *objects = [NSMutableArray arrayWithObject:_scene];
    [objects addObjectsFromArray:[_fx warmupNodes]];
    [self prepare:objects view:view from:0.7f to:1.0f];
    [self reportStage:LoadStageReady progress:1];
    NSLog(@"Boot loaded in %.2f s", CACurrentMediaTime() - t0);
    atomic_store(&_loadDone, true);
}

// Render thread, once the boot load is done and the bar is full.
- (void)finishBoot {
    _booted = YES;
    SCNView *view = _view;
    SCNScene *scene = _scene;
    SCNNode *camera = _cameraNode;
    dispatch_async(dispatch_get_main_queue(), ^{
        view.scene = scene;
        view.pointOfView = camera;
    });
    const char *m = getenv("SF_MISSION");   // debug: fly mission N straight away
    if (m && atoi(m) >= 1) {
        _state = GameStateMenu;
        [self startMission:(NSUInteger)atoi(m) - 1];
        return;
    }
    _state = GameStateMenu;
    [_briefing showListSelecting:[Mission unlockedCount] - 1];
    const char *b = getenv("SF_BRIEFING");   // debug: open a briefing
    if (b && atoi(b) >= 1) [_briefing showBriefing:(NSUInteger)atoi(b) - 1];
    [self reveal:0.5];
}

// Fade the loading card out, then hand the overlay to the HUD or the menus.
- (void)reveal:(double)seconds {
    _revealing = YES;
    [_loading fadeOut:seconds];
}

- (void)updateLoading {
    [_loading setProgress:atomic_load(&_loadProgress) status:LoadStatus((LoadStage)atomic_load(&_loadStage))];
    [_loading tick:_time];
    double minimum = _booted ? kMinMissionLoadSeconds : 0;
    if (atomic_load(&_loadDone) && _loading.barFull && _time - _loadStartedAt >= minimum) {
        atomic_store(&_loadDone, false);
        if (_booted) [self finishMission];
        else [self finishBoot];
    }
}

- (void)updateReveal {
    [_loading tick:_time];
    if (!_loading.faded) return;
    _revealing = NO;
    SKScene *next = _state == GameStateFlying ? _hud : _briefing;
    if (_state == GameStateFlying) [_hud showBanner:[_mission[@"title"] uppercaseString] color:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.overlaySKScene = next; });
}

#pragma mark - Scene

- (void)buildScene {
    _scene = [SCNScene scene];
    [self reportStage:LoadStageSky progress:0.05f];
    [self loadSky:1337];
    [self reportStage:LoadStageCockpit progress:0.45f];

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

    _player = [Ship shipWithClass:ShipClassExecutioner smoke:YES];
    _player.maxSpeed = 160;
    _player.team = TeamFriend;
    [_scene.rootNode addChildNode:_player.node];

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

    _cockpitModel = [[Cockpit alloc] initWithDevice:_view.device];
    _cockpitModel.node.simdPosition = kCockpitEye;
    _cockpitModel.node.hidden = YES;
    [_player.node addChildNode:_cockpitModel.node];
    _cockpit = getenv("SF_COCKPIT") != NULL;

    _pilots = [NSMutableArray array];
    _capitals = [NSMutableArray array];
    _torpedoes = [NSMutableArray array];
    _explosionQueue = [NSMutableArray array];
    _fx = [[Effects alloc] initWithScene:_scene];
    for (int i = 0; i < MAX_BOLTS; i++) {
        SCNNode *n = [_fx makeBoltNode];
        n.hidden = YES;
        [_scene.rootNode addChildNode:n];
        _boltNodes[i] = n;
    }
    [_player resetAt:simd_make_float3(0, 0, 0) facing:LookRotation(simd_make_float3(0, 0, -1), simd_make_float3(0, 1, 0))];
    _player.node.hidden = YES;
    _camOrientation = _player.orientation;
}

// Each mission gets its own sky: the seed moves the sun, planet and nebula.
- (void)loadSky:(uint32_t)seed {
    SpaceSky *sky = [[SpaceSky alloc] initWithDevice:_view.device faceSize:1536 seed:seed];
    [self applySky:sky dust:[sky makeDustNode]];
}

- (void)applySky:(SpaceSky *)sky dust:(SCNNode *)dust {
    _sky = sky;
    _scene.background.contents = _sky.cubeTexture;
    _scene.lightingEnvironment.contents = _sky.cubeTexture;
    _scene.lightingEnvironment.intensity = 1.6;
    [_dust removeFromParentNode];
    _dust = dust;
    [_scene.rootNode addChildNode:_dust];
}

#pragma mark - Mission setup

- (void)clearWorld {
    for (Pilot *p in _pilots) [p.ship.node removeFromParentNode];
    for (Capital *c in _capitals) [c.node removeFromParentNode];
    for (Torpedo *t in _torpedoes) [t.node removeFromParentNode];
    [_pilots removeAllObjects];
    [_capitals removeAllObjects];
    [_torpedoes removeAllObjects];
    [_explosionQueue removeAllObjects];
    for (int i = 0; i < MAX_BOLTS; i++) { _bolts[i].active = NO; _boltNodes[i].hidden = YES; }
    _selected = nil;
    [_world removeFromParentNode];
    _world = nil;
}

// Render thread: put up the loading card and build the mission off-thread.
- (void)startMission:(NSUInteger)index {
    if (_state == GameStateLoading) return;
    [self clearWorld];
    _state = GameStateLoading;
    _revealing = NO;
    _missionIndex = index;
    _mission = [Mission missionAtIndex:index];
    _player.node.hidden = YES;
    _cockpitModel.node.hidden = YES;

    NSDictionary *b = _mission[@"briefing"];
    NSString *detail = b[@"stardate"] ? [NSString stringWithFormat:@"%@   /   SD %@", b[@"location"] ?: @"", b[@"stardate"]] : b[@"location"];
    [_loading showTitle:_mission[@"title"]
                 kicker:[NSString stringWithFormat:@"KESTREL FRONTIER  /  MISSION %02lu", (unsigned long)index + 1]
                 detail:detail];
    [self reportStage:LoadStageStart progress:0];
    atomic_store(&_loadDone, false);
    _loadStartedAt = _time;
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.overlaySKScene = self->_loading; });

    NSDictionary *mission = _mission;
    dispatch_async(_loadQueue, ^{ [self loadMissionInBackground:mission]; });
}

// Load queue. The render thread only animates the loading card while this
// runs, so the mission state it fills in is not read concurrently; all new
// nodes hang off a detached _world node until -finishMission attaches it.
- (void)loadMissionInBackground:(NSDictionary *)mission {
    CFTimeInterval t0 = CACurrentMediaTime();
    SCNView *view = _view;
    [SCNTransaction begin];
    [SCNTransaction setDisableActions:YES];

    [self reportStage:LoadStageSky progress:0.02f];
    uint32_t seed = 1337 + (uint32_t)[mission[@"id"] intValue] * 7919;
    SpaceSky *sky = [[SpaceSky alloc] initWithDevice:view.device faceSize:1536 seed:seed];
    SCNNode *dust = [sky makeDustNode];
    [self reportStage:LoadStageFleet progress:0.3f];

    _world = [SCNNode node];
    _world.name = @"World";
    _missionTime = 0;
    _endAt = 0;
    _success = NO;
    _kills = 0;
    _torpedoCount = [mission[@"loadout"][@"torpedoes"] intValue];
    _spawned = [NSMutableSet setWithObject:@"start"];
    _navsVisited = [NSMutableSet set];
    _navs = [NSMutableDictionary dictionary];
    _navNames = [NSMutableDictionary dictionary];
    for (NSDictionary *n in mission[@"navs"]) {
        simd_float3 p = Vec3(n[@"pos"]);
        _navs[n[@"id"]] = Vec3Value(p);
        _navNames[n[@"id"]] = n[@"name"];
    }
    _objectives = [Mission objectivesFor:mission];
    _pendingEntities = [NSMutableArray array];
    _pendingWaves = [NSMutableArray array];
    _pendingMessages = [mission[@"messages"] mutableCopy] ?: [NSMutableArray array];

    NSArray *entities = mission[@"entities"], *fields = mission[@"fields"], *waves = mission[@"waves"];
    float steps = (float)MAX(entities.count + fields.count + waves.count, 1), done = 0;
    for (NSDictionary *e in entities) {
        if (e[@"at"] || e[@"after"] || e[@"nav"]) [_pendingEntities addObject:e];
        else [self spawnEntity:e jump:NO];
        atomic_store(&_loadProgress, 0.3f + 0.3f * ++done / steps);
    }
    [self reportStage:LoadStageFields progress:0.3f + 0.3f * done / steps];
    for (NSDictionary *f in fields) {
        [self buildField:f];
        atomic_store(&_loadProgress, 0.3f + 0.3f * ++done / steps);
    }
    [self reportStage:LoadStageWings progress:0.3f + 0.3f * done / steps];
    for (NSDictionary *w in waves) {
        if (w[@"at"] || w[@"after"] || w[@"nav"]) [_pendingWaves addObject:w];
        else [self spawnWave:w jump:NO];
        atomic_store(&_loadProgress, 0.3f + 0.3f * ++done / steps);
    }
    [SCNTransaction commit];
    [SCNTransaction flush];

    // Ships that jump in later are cloned from the same prototypes, so warm
    // those up too: one throwaway instance of each.
    NSMutableArray *objects = [NSMutableArray arrayWithArray:_world.childNodes];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *e in _pendingEntities) {
        NSString *key = [NSString stringWithFormat:@"%@|%@", e[@"asset"], e[@"style"]];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [objects addObject:[Capital capitalWithAsset:e[@"asset"] style:e[@"style"] team:TeamNamed(e[@"team"])].node];
    }
    for (NSDictionary *w in _pendingWaves) {
        NSString *key = [@"ship|" stringByAppendingString:w[@"ship"] ?: @""];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [objects addObject:[Ship shipWithClass:ClassNamed(w[@"ship"]) smoke:YES].node];
    }
    [objects addObject:dust];
    [self reportStage:LoadStageUpload progress:0.6f];
    [self prepare:objects view:view from:0.6f to:1.0f];

    _nextSky = sky;
    _nextDust = dust;
    [self reportStage:LoadStageReady progress:1];
    NSLog(@"Mission %@ loaded in %.2f s (%lu nodes)", mission[@"id"], CACurrentMediaTime() - t0, (unsigned long)objects.count);
    atomic_store(&_loadDone, true);
}

// Render thread: attach what the load queue built and start flying.
- (void)finishMission {
    [self applySky:_nextSky dust:_nextDust];
    _nextSky = nil;
    _nextDust = nil;
    [_scene.rootNode addChildNode:_world];

    NSDictionary *pl = _mission[@"player"];
    simd_float3 facing = pl[@"facing"] ? Vec3(pl[@"facing"]) : simd_make_float3(0, 0, -1);
    [_player resetAt:Vec3(pl[@"pos"]) facing:LookRotation(facing, simd_make_float3(0, 1, 0))];
    _player.throttle = 0.5f;
    const char *warp = getenv("SF_WARP");   // debug: start next to an entity, looking at it
    if (warp)
        for (Capital *c in _capitals)
            if ([c.identifier isEqualToString:@(warp)]) {
                float k = getenv("SF_WARPDIST") ? (float)atof(getenv("SF_WARPDIST")) : 2.2f;
                simd_float3 from = c.position + simd_normalize(simd_make_float3(0.8f, 0.35f, 1.0f)) * fmaxf(c.radius * k, 60);
                [_player resetAt:from facing:LookRotation(c.position - from, simd_make_float3(0, 1, 0))];
                _player.throttle = 0;
                _player.velocity = 0;
            }
    _camOrientation = _player.orientation;
    _player.node.hidden = NO;

    if (getenv("SF_AUTOPILOT")) {
        _autopilot = [Pilot new];
        _autopilot.ship = _player;
        _autopilot.order = @"attack";
        _autopilot.aimError = 0.3f;
    }
    _state = GameStateFlying;
    [_hud clearMessages];
    [_hud setHelpVisible:NO];
    _objectivesDirty = YES;
    [self reveal:0.6];
}

- (void)endMission:(BOOL)success {
    if (_state != GameStateFlying) return;
    NSLog(@"Mission %@ ended: %@ after %.0f s, kills %d", _mission[@"id"], success ? @"SUCCESS" : @"FAILED", _missionTime, _kills);
    _state = GameStateOver;
    _success = success;
    if (success) [Mission markCompleted:_missionIndex];
    NSMutableArray *results = [NSMutableArray array];
    for (Objective *o in _objectives) {
        NSString *mark = o.state == ObjectiveComplete ? @"+" : (o.state == ObjectiveFailed ? @"x" : @"-");
        [results addObject:[NSString stringWithFormat:@"%@ %@%@", mark, o.text, o.optional ? @" (optional)" : @""]];
    }
    [_briefing showDebrief:_missionIndex success:success results:results];
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.overlaySKScene = self->_briefing; });
}

- (Capital *)spawnEntity:(NSDictionary *)e jump:(BOOL)jump {
    Team team = TeamNamed(e[@"team"]);
    Capital *c = [Capital capitalWithAsset:e[@"asset"] style:e[@"style"] team:team];
    c.identifier = e[@"id"];
    c.name = e[@"name"] ?: c.className;
    c.group = e[@"group"];
    c.position = Vec3(e[@"pos"]);
    simd_float3 facing = e[@"facing"] ? Vec3(e[@"facing"]) : simd_make_float3(0, 0, -1);
    c.orientation = LookRotation(facing, simd_make_float3(0, 1, 0));
    NSMutableArray *path = [NSMutableArray array];
    for (NSArray *p in e[@"path"]) {
        [path addObject:Vec3Value(Vec3(p))];
    }
    c.path = path;
    c.speed = [e[@"speed"] floatValue];
    c.loop = [e[@"loop"] boolValue];
    c.spin = [e[@"spin"] floatValue];
    c.stealthRange = [e[@"stealth"] floatValue];
    if (e[@"invulnerable"]) c.invulnerable = [e[@"invulnerable"] boolValue];
    c.noHullDamage = [e[@"noHullDamage"] boolValue];
    if (e[@"hull"]) c.maxHull = c.hull = [e[@"hull"] floatValue];
    if (e[@"hullFraction"]) c.hull = c.maxHull * [e[@"hullFraction"] floatValue];
    [_world addChildNode:c.node];
    [_capitals addObject:c];
    if (c.identifier) [_spawned addObject:c.identifier];
    if (c.group) [_spawned addObject:c.group];
    if (jump) [self jumpFlashAt:c.position scale:c.radius / 30.0f];
    return c;
}

- (void)spawnWave:(NSDictionary *)w jump:(BOOL)jump {
    int count = [w[@"count"] intValue] ?: 1;
    Team team = TeamNamed(w[@"team"]);
    ShipClass cls = ClassNamed(w[@"ship"]);
    simd_float3 centre = Vec3(w[@"pos"]);
    float spread = w[@"spread"] ? [w[@"spread"] floatValue] : 80;
    NSString *order = w[@"order"] ?: @"attack";
    NSRange colon = [order rangeOfString:@":"];
    for (int i = 0; i < count; i++) {
        Pilot *p = [Pilot new];
        p.ship = [Ship shipWithClass:cls smoke:YES];
        p.ship.team = team;
        p.ship.maxSpeed = cls == ShipClassInsurgent ? 120 : (cls == ShipClassExecutioner ? 150 : 140 + 8 * (i % 3));
        p.ship.turnRate = cls == ShipClassInsurgent ? 0.6f : 0.8f;
        simd_float3 pos = centre + randomUnit() * spread * (i == 0 ? 0.2f : 1.0f);
        simd_float3 toward = simd_length(_player.position - pos) > 1 ? simd_normalize(_player.position - pos) : simd_make_float3(0, 0, -1);
        if (team == TeamFriend) toward = _player.forward;
        [p.ship resetAt:pos facing:LookRotation(toward + randomUnit() * 0.2f, simd_make_float3(0, 1, 0))];
        p.ship.velocity = p.ship.forward * 100;
        p.mode = AIModeAttack;
        p.aimError = team == TeamFriend ? 0.5f : 0.6f + frand() * 0.8f;
        p.order = colon.location == NSNotFound ? order : [order substringToIndex:colon.location];
        p.orderTarget = colon.location == NSNotFound ? nil : [order substringFromIndex:colon.location + 1];
        p.wave = w[@"id"];
        if (w[@"name"]) p.callsign = count > 1 ? [NSString stringWithFormat:@"%@ %d", w[@"name"], i + 2] : w[@"name"];
        [_world addChildNode:p.ship.node];
        [_pilots addObject:p];
        if (jump) [self jumpFlashAt:pos scale:0.4f];
    }
    [_spawned addObject:w[@"id"]];
}

- (void)buildField:(NSDictionary *)f {
    NSString *type = f[@"type"];
    srand48([f[@"seed"] intValue] * 101 + 7);
    if ([type isEqualToString:@"asteroids"]) {
        simd_float3 centre = Vec3(f[@"center"]);
        float r = [f[@"radius"] floatValue];
        BOOL small = [f[@"small"] boolValue];
        for (int i = 0, n = [f[@"count"] intValue]; i < n; i++) {
            NSString *asset = small ? @"AsteroidC" : @[@"AsteroidA", @"AsteroidB", @"AsteroidC"][(int)(drand48() * 3)];
            Capital *c = [Capital capitalWithAsset:asset style:@"rock" team:TeamNeutral];
            c.identifier = [NSString stringWithFormat:@"rock%d", i];
            c.name = @"Asteroid";
            simd_float3 p;
            do { p = simd_make_float3(drand48() * 2 - 1, (drand48() * 2 - 1) * 0.45, drand48() * 2 - 1); } while (simd_length(p) > 1);
            c.position = centre + p * r;
            c.orientation = simd_quaternion((float)(drand48() * 6.28), simd_normalize(simd_make_float3(drand48() - 0.5, drand48() - 0.5, drand48() - 0.5) + 0.01f));
            [c setUniformScale:0.6f + (float)drand48() * 1.6f];
            c.spin = (float)(drand48() * 2 - 1) * 6;
            [_world addChildNode:c.node];
            [_capitals addObject:c];
        }
    } else if ([type isEqualToString:@"mines"]) {
        simd_float3 centre = Vec3(f[@"center"]), size = Vec3(f[@"size"]);
        for (int i = 0, n = [f[@"count"] intValue]; i < n; i++) {
            Capital *c = [Capital capitalWithAsset:@"Mine" style:nil team:TeamEnemy];
            c.identifier = [NSString stringWithFormat:@"mine%d", i];
            c.name = @"Mine";
            c.group = f[@"group"];
            c.position = centre + simd_make_float3(drand48() - 0.5, drand48() - 0.5, drand48() - 0.5) * size;
            c.spin = 20;
            [_world addChildNode:c.node];
            [_capitals addObject:c];
        }
        [_spawned addObject:f[@"group"]];
    } else if ([type isEqualToString:@"buoys"]) {
        for (NSString *nav in f[@"navs"]) {
            Capital *c = [Capital capitalWithAsset:@"NavBuoy" style:nil team:TeamNeutral];
            c.identifier = [@"buoy_" stringByAppendingString:nav];
            c.name = _navNames[nav];
            c.invulnerable = YES;
            simd_float3 p;
            [_navs[nav] getValue:&p size:sizeof p];
            c.position = p + simd_make_float3(0, -25, 0);
            c.spin = 10;
            [_world addChildNode:c.node];
            [_capitals addObject:c];
        }
    }
}

- (void)jumpFlashAt:(simd_float3)p scale:(float)scale {
    SCNNode *s = [_fx streakWithColor:[NSColor colorWithRed:0.6 green:0.8 blue:1 alpha:1] width:400 * fmaxf(scale, 0.3f) height:6];
    s.simdPosition = p;
    [_scene.rootNode addChildNode:s];
    [s runAction:[SCNAction sequence:@[[SCNAction fadeOutWithDuration:0.8], [SCNAction removeFromParentNode]]]];
}

#pragma mark - Loop

- (void)renderer:(id<SCNSceneRenderer>)renderer willRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time {
    if (!_booted) return;   // the cockpit may still be under construction on the load queue
    [_cockpitModel renderDisplaysWithQueue:renderer.commandQueue time:time];
}

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    float dt = _lastTime > 0 ? (float)(time - _lastTime) : 1.0f / 60.0f;
    _lastTime = time;
    dt = clampf(dt, 0.0005f, 1.0f / 20.0f);
    _time += dt;
    [Capital updateSharedMaterials:_time];

    InputAction actions = [_input consumeActions];
    ControlState controls = [_input poll:dt];
    if (_state == GameStateLoading) { [self updateLoading]; return; }
    if (_revealing) {
        [self updateReveal];
        if (_state == GameStateMenu) actions = 0;   // the menu isn't visible yet
    }
    if (actions & InputActionToggleCamera) _cockpit = !_cockpit;
    if (actions & InputActionToggleHelp) [_hud toggleHelp];

    if (_state != GameStateFlying) {
        [self updateMenu:actions dt:dt];
        return;
    }
    if (actions & InputActionRestart) { [self startMission:_missionIndex]; return; }
    if (actions & InputActionBack) { [self abortToMenu]; return; }
    if (actions & InputActionTarget) [self cycleTarget];
    if (actions & InputActionTorpedo) [self fireTorpedo];

    _missionTime += dt;
    if (_player.alive && _autopilot) {
        simd_float3 before = _player.position;
        [self thinkPilot:_autopilot dt:dt];
        [self collidePlayerFrom:before];
    } else if (_player.alive) {
        simd_float3 before = _player.position;
        [_player stepWithControls:controls dt:dt];
        [self collidePlayerFrom:before];
        if (controls.fire && _time - _player.lastShot > 0.11) {
            _player.lastShot = _time;
            [self fireFrom:_player.nextGunWorldPosition velocity:_player.velocity direction:_player.forward team:TeamFriend
                    damage:0.12f capDamage:0.12f player:YES];
            [_fx muzzleFlashOn:_player.node local:_player.lastGunLocal player:YES];
        }
    }
    _engineLight.light.intensity = _player.alive ? 60 + 900 * _player.exhaust.level : 0;

    for (Pilot *p in [_pilots copy]) [self thinkPilot:p dt:dt];
    for (Capital *c in [_capitals copy]) {
        [c update:dt];
        [self fireTurrets:c];
        if (c.isMine && c.alive) [self checkMine:c];
    }
    [self updateBolts:dt];
    [self updateTorpedoes:dt];
    [self updateExplosions];
    [self updateMission:dt];
    [self updateCamera:dt controls:controls];

    _sunLight.simdPosition = _player.position + _sky.sunDirection * 250.0f;
    [_sunLight simdLookAt:_player.position];
    [_sky updateDust:_dust cameraPosition:_cameraNode.simdPosition velocity:_player.velocity];

    _damageFlash = fmaxf(0, _damageFlash - dt * 2.5f);
    [self updateHUD:controls];
}

- (void)updateMenu:(InputAction)actions dt:(float)dt {
    [_briefing tick:_time];
    if ([_briefing handle:actions] == BriefingCommandLaunch) {
        [self startMission:_briefing.selectedIndex];
        return;
    }
    // Slow drift through the sky behind the menus.
    _player.node.hidden = YES;
    _cockpitModel.node.hidden = YES;
    _cameraNode.simdPosition = simd_make_float3(0, 0, 0);
    _cameraNode.simdOrientation = simd_quaternion((float)_time * 0.02f, simd_make_float3(0, 1, 0));
}

- (void)abortToMenu {
    _state = GameStateMenu;
    [self clearWorld];
    [_briefing showListSelecting:_missionIndex];
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.overlaySKScene = self->_briefing; });
}

#pragma mark - Mission logic

- (NSArray *)unitsFor:(NSString *)name {
    NSMutableArray *u = [NSMutableArray array];
    for (Capital *c in _capitals) if ([c.identifier isEqualToString:name] || [c.group isEqualToString:name]) [u addObject:c];
    for (Pilot *p in _pilots) if ([p.wave isEqualToString:name]) [u addObject:p.ship];
    return u;
}

- (NSArray *)unitsForAll:(NSArray<NSString *> *)names {
    NSMutableArray *u = [NSMutableArray array];
    for (NSString *n in names) [u addObjectsFromArray:[self unitsFor:n]];
    return u;
}

- (Objective *)objectiveNamed:(NSString *)name {
    for (Objective *o in _objectives) if ([o.identifier isEqualToString:name]) return o;
    return nil;
}

- (BOOL)triggered:(NSDictionary *)d {
    if (d[@"at"] && _missionTime < [d[@"at"] doubleValue]) return NO;
    if (d[@"after"] && [self objectiveNamed:d[@"after"]].state != ObjectiveComplete) return NO;
    if (d[@"nav"] && ![_navsVisited containsObject:d[@"nav"]]) return NO;
    if (d[@"spawn"] && ![_spawned containsObject:d[@"spawn"]]) return NO;
    return YES;
}

- (simd_float3)navPosition:(NSString *)nav {
    simd_float3 p = 0;
    [_navs[nav] getValue:&p size:sizeof p];
    return p;
}

- (void)updateMission:(float)dt {
    // Arrivals and radio traffic.
    for (NSDictionary *e in [_pendingEntities copy])
        if ([self triggered:e]) { [_pendingEntities removeObject:e]; [self spawnEntity:e jump:YES]; }
    for (NSDictionary *w in [_pendingWaves copy])
        if ([self triggered:w]) { [_pendingWaves removeObject:w]; [self spawnWave:w jump:YES]; }
    for (NSDictionary *m in [_pendingMessages copy])
        if ([self triggered:m]) { [_pendingMessages removeObject:m]; [_hud showMessage:m[@"text"] from:m[@"from"]]; }
    for (NSString *nav in _navs)
        if (_player.alive && simd_distance(_player.position, [self navPosition:nav]) < 400) [_navsVisited addObject:nav];

    _currentNav = nil;
    _status = nil;
    for (Objective *o in _objectives) [self evaluate:o dt:dt];

    if (_objectivesDirty) {
        _objectivesDirty = NO;
        NSMutableArray *lines = [NSMutableArray array], *states = [NSMutableArray array];
        _objectiveSummary = nil;
        for (Objective *o in _objectives) {
            if (o.state == ObjectiveHidden) continue;
            [lines addObject:o.progress.length ? [NSString stringWithFormat:@"%@  %@", o.text, o.progress] : o.text];
            int st = o.state == ObjectiveComplete ? 1 : (o.state == ObjectiveFailed ? 2 : (o.optional ? 3 : 0));
            [states addObject:@(st)];
            if (o.state == ObjectiveActive && !o.optional && !_objectiveSummary && ![o.type isEqualToString:@"protect"]) _objectiveSummary = o.text;
        }
        [_hud setObjectives:lines states:states];
    }

    // Win when every required objective (other than "protect") is done.
    if (_endAt == 0) {
        BOOL failed = !_player.alive, done = YES;
        for (Objective *o in _objectives) {
            if (o.optional) continue;
            if (o.state == ObjectiveFailed) failed = YES;
            if (![o.type isEqualToString:@"protect"] && o.state != ObjectiveComplete) done = NO;
        }
        if (failed) {
            _endAt = _missionTime + 3.5;
            _success = NO;
            [_hud showBanner:@"MISSION FAILED" color:[NSColor colorWithRed:1 green:0.4 blue:0.3 alpha:1]];
        } else if (done) {
            for (Objective *o in _objectives)
                if ([o.type isEqualToString:@"protect"] && o.state == ObjectiveActive) o.state = ObjectiveComplete;
            _objectivesDirty = YES;
            _endAt = _missionTime + 4.0;
            _success = YES;
            [_hud showBanner:@"MISSION COMPLETE" color:nil];
        }
    } else if (_missionTime >= _endAt) {
        [self endMission:_success];
    }
}

- (void)setObjective:(Objective *)o state:(ObjectiveState)state {
    if (o.state == state) return;
    o.state = state;
    NSLog(@"Mission %@ t=%.0f: objective '%@' -> %@", _mission[@"id"], _missionTime, o.identifier,
          @[@"hidden", @"active", @"complete", @"FAILED"][state]);
    _objectivesDirty = YES;
    if (state == ObjectiveComplete && ![o.type isEqualToString:@"protect"]) {
        [_hud showBanner:@"OBJECTIVE COMPLETE" color:nil];
        NSDictionary *set = o.def[@"onComplete"][@"setTeam"];
        for (NSString *who in set)
            for (id u in [self unitsFor:who]) {
                if ([u isKindOfClass:[Capital class]]) ((Capital *)u).team = TeamNamed(set[who]);
                else ((Ship *)u).team = TeamNamed(set[who]);
            }
    }
    if (state == ObjectiveFailed && !o.optional) [_hud showBanner:@"OBJECTIVE FAILED" color:[NSColor colorWithRed:1 green:0.4 blue:0.3 alpha:1]];
    if (state == ObjectiveActive && _missionTime > 1) [_hud showMessage:o.text from:@"New objective"];
}

- (void)evaluate:(Objective *)o dt:(float)dt {
    if (o.state == ObjectiveComplete || o.state == ObjectiveFailed) return;
    NSString *type = o.type;
    if (o.state == ObjectiveHidden) {
        for (NSString *a in o.after) if ([self objectiveNamed:a].state != ObjectiveComplete) return;
        for (NSString *t in o.targets) if (![_spawned containsObject:t]) return;
        o.activatedAt = _missionTime;
        [self setObjective:o state:ObjectiveActive];
    }
    NSArray *units = [self unitsForAll:o.targets];
    NSString *oldProgress = o.progress;
    float range = o.def[@"range"] ? [o.def[@"range"] floatValue] : 0;

    if ([type isEqualToString:@"reach"]) {
        while (o.navIndex < o.navs.count) {
            simd_float3 p = [self navPosition:o.navs[o.navIndex]];
            if (_player.alive && simd_distance(_player.position, p) < (range ?: 300)) o.navIndex++;
            else break;
        }
        if (o.navIndex >= o.navs.count) { [self setObjective:o state:ObjectiveComplete]; return; }
        if (!_currentNav && !o.optional) _currentNav = o.navs[o.navIndex];
        if (!_currentNav && o.optional) _currentNav = o.navs[o.navIndex];
        o.progress = o.navs.count > 1 ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)o.navIndex, (unsigned long)o.navs.count] : @"";
    } else if ([type isEqualToString:@"destroy"]) {
        NSUInteger dead = 0;
        for (id u in units) if (!BodyAlive(u)) dead++;
        if (units.count && dead == units.count) [self setObjective:o state:ObjectiveComplete];
        o.progress = units.count > 1 ? [NSString stringWithFormat:@"%lu/%lu", (unsigned long)dead, (unsigned long)units.count] : @"";
    } else if ([type isEqualToString:@"protect"]) {
        for (id u in units) {
            BOOL safe = [u isKindOfClass:[Capital class]] && (((Capital *)u).collected || ((Capital *)u).departed);
            if (!BodyAlive(u) && !safe) { [self setObjective:o state:ObjectiveFailed]; return; }
        }
        float worst = 1;
        for (id u in units) if ([u isKindOfClass:[Capital class]] && BodyAlive(u)) worst = fminf(worst, ((Capital *)u).hull / ((Capital *)u).maxHull);
        o.progress = units.count == 1 || worst < 1 ? [NSString stringWithFormat:@"%d%%", (int)lroundf(worst * 100)] : @"";
    } else if ([type isEqualToString:@"escort"]) {
        NSUInteger arrived = 0;
        simd_float3 nav = [self navPosition:o.navs.firstObject];
        for (Capital *c in units) {
            if (c.departed) { arrived++; continue; }
            if (!c.alive) { [self setObjective:o state:ObjectiveFailed]; return; }
            if (simd_distance(c.position, nav) < 400) {
                arrived++;
                // At a gate the escortee jumps out; elsewhere it just holds.
                for (Capital *g in _capitals)
                    if ([g.asset isEqualToString:@"JumpGate"] && simd_distance(g.position, nav) < 700) {
                        c.departed = YES;
                        [self jumpFlashAt:c.position scale:c.radius / 30.0f];
                        c.node.hidden = YES;
                    }
            }
        }
        if (units.count && arrived == units.count) [self setObjective:o state:ObjectiveComplete];
        if (!_currentNav) _currentNav = o.navs.firstObject;
        if (units.count) {
            Capital *c = units.firstObject;
            o.progress = [NSString stringWithFormat:@"%.1fkm", simd_distance(c.position, nav) / 1000.0f];
        }
    } else if ([type isEqualToString:@"survive"]) {
        double left = [o.def[@"seconds"] doubleValue] - (_missionTime - o.activatedAt);
        if (left <= 0) { [self setObjective:o state:ObjectiveComplete]; return; }
        o.progress = [NSString stringWithFormat:@"%d:%02d", (int)left / 60, (int)left % 60];
    } else if ([type isEqualToString:@"scan"]) {
        NSUInteger done = 0;
        for (Capital *c in units) {
            NSString *k = c.identifier;
            float t = o.scanTime[k].floatValue;
            if (t >= 2.0f) { done++; continue; }
            if (c.alive && _player.alive && simd_distance(_player.position, c.position) < (range ?: 150) + c.radius) {
                t += dt;
                o.scanTime[k] = @(t);
                _status = [NSString stringWithFormat:@"SCANNING %@  %d%%", [c.name uppercaseString], (int)(fminf(t / 2.0f, 1) * 100)];
                if (t >= 2.0f) [_hud showMessage:[NSString stringWithFormat:@"%@ scanned", c.name] from:@""];
            }
        }
        if (units.count && done == units.count) [self setObjective:o state:ObjectiveComplete];
        o.progress = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)done, (unsigned long)units.count];
    } else if ([type isEqualToString:@"collect"]) {
        NSUInteger got = 0;
        for (Capital *c in units) {
            if (c.collected) { got++; continue; }
            if (c.alive && _player.alive && simd_distance(_player.position, c.position) < (range ?: 30) + c.radius) {
                c.collected = YES;
                c.alive = NO;
                c.node.hidden = YES;
                [self jumpFlashAt:c.position scale:0.2f];
                [_hud showMessage:[NSString stringWithFormat:@"%@ aboard", c.name] from:@""];
                got++;
            }
        }
        if (units.count && got == units.count) [self setObjective:o state:ObjectiveComplete];
        o.progress = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)got, (unsigned long)units.count];
    } else if ([type isEqualToString:@"disable"]) {
        NSString *kindName = o.def[@"kind"];
        SubsystemKind kind = [kindName isEqualToString:@"Engine"] ? SubsystemEngine : ([kindName isEqualToString:@"Shield"] ? SubsystemShield :
                             ([kindName isEqualToString:@"Core"] ? SubsystemCore : SubsystemTurret));
        NSUInteger left = 0, total = 0;
        for (Capital *c in units) {
            total += [c totalCount:kind];
            if (c.alive) left += [c aliveCount:kind];
        }
        if (units.count && left == 0) [self setObjective:o state:ObjectiveComplete];
        o.progress = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)(total - left), (unsigned long)total];
    }
    if (![o.progress isEqualToString:oldProgress]) _objectivesDirty = YES;
}

#pragma mark - AI

- (id)pickTargetFor:(Pilot *)p {
    Ship *s = p.ship;
    id best = nil;
    float bestD = FLT_MAX;
    if ([p.order isEqualToString:@"strike"] && p.orderTarget) {
        for (id u in [self unitsFor:p.orderTarget]) {
            if (!BodyAlive(u) || BodyTeam(u) == s.team) continue;
            float d = simd_distance(BodyPosition(u), s.position);
            if (d < bestD) { bestD = d; best = u; }
        }
        if (best) return best;
    }
    simd_float3 anchor = s.position;
    float leash = FLT_MAX;
    if ([p.order isEqualToString:@"escort"] && p.orderTarget) {
        NSArray *units = [self unitsFor:p.orderTarget];
        for (id u in units) if (BodyAlive(u)) { anchor = BodyPosition(u); leash = 1600; break; }
    }
    NSMutableArray *fighters = [NSMutableArray arrayWithObject:_player];
    for (Pilot *q in _pilots) [fighters addObject:q.ship];
    for (Ship *f in fighters) {
        if (f == s || !f.alive || !TeamsHostile(s.team, f.team)) continue;
        if (simd_distance(f.position, anchor) > leash) continue;
        float d = simd_distance(f.position, s.position);
        if (f == _player) d *= 0.85f;   // the player draws a little extra attention
        if (d < bestD) { bestD = d; best = f; }
    }
    if (best || leash < FLT_MAX) return best;
    for (Capital *c in _capitals) {
        if (!c.alive || c.isProp || !TeamsHostile(s.team, c.team)) continue;
        float d = simd_distance(c.position, s.position);
        if (d < bestD) { bestD = d; best = c; }
    }
    return best;
}

- (void)thinkPilot:(Pilot *)p dt:(float)dt {
    Ship *s = p.ship;
    if (!s.alive) return;
    if (_time > p.retargetAt || !BodyAlive(p.target) || (p.target && !TeamsHostile(s.team, BodyTeam(p.target)) && BodyTeam(p.target) != TeamNeutral)) {
        p.target = [self pickTargetFor:p];
        p.retargetAt = _time + 1.5 + frand();
    }
    id target = p.target;
    simd_float3 aimPoint;
    float throttle = 0.85f;
    BOOL boost = NO;
    BOOL capital = [target isKindOfClass:[Capital class]];
    float dist = 0;

    if (!target) {
        // Nothing to fight: escorts form up on their charge, others drift to the player.
        simd_float3 anchor = _player.position;
        if (p.orderTarget) for (id u in [self unitsFor:p.orderTarget]) if (BodyAlive(u)) { anchor = BodyPosition(u); break; }
        aimPoint = anchor + simd_make_float3(sinf(_time * 0.3f + s.radius) * 250, 120, cosf(_time * 0.3f) * 250);
        throttle = simd_distance(aimPoint, s.position) > 400 ? 1.0f : 0.5f;
        p.mode = AIModeReposition;
    } else {
        simd_float3 tp = BodyPosition(target);
        simd_float3 toT = tp - s.position;
        dist = simd_length(toT);
        float breakoff = capital ? BodyRadius(target) + 140 : 70;
        if (p.mode == AIModeAttack && dist < breakoff) {
            p.mode = AIModeEvade;
            p.modeUntil = _time + 2.0 + frand() * 2.0;
            p.evadePoint = s.position + (randomUnit() + s.forward + simd_normalize(s.position - tp)) * (capital ? 900.0f : 600.0f);
        } else if (p.mode != AIModeAttack && _time > p.modeUntil) {
            p.mode = AIModeAttack;
        }
        if (p.mode == AIModeAttack) {
            float tLead = dist / kBoltSpeed;
            simd_float3 wobble = simd_make_float3(sinf(_time * 1.3f + s.radius), cosf(_time * 0.9f), sinf(_time * 0.7f)) * p.aimError * 6.0f;
            aimPoint = tp + BodyVelocity(target) * tLead + (capital ? 0 : wobble);
            float facing = simd_dot(s.forward, toT / fmaxf(dist, 1));
            if (facing < -0.2f && dist < 400) boost = s.boostEnergy > 0.5f;
            if (!capital && dist < 220 && facing > 0.7f) throttle = 0.55f;
            if (dist > 900) boost = s.boostEnergy > 0.3f;
        } else {
            aimPoint = p.evadePoint;
            throttle = 1.0f;
            boost = s.boostEnergy > 0.4f;
        }
    }

    // Keep clear of big hulls and rocks.
    for (Capital *c in _capitals) {
        if (!c.alive || c.radius < 15) continue;
        simd_float3 away = s.position - c.position;
        float d = simd_length(away) - c.radius;
        if (d < 110 && simd_dot(s.velocity, -away) > 0 && c != target) {
            aimPoint = s.position + simd_normalize(away) * 400 + s.up * 150;
            break;
        }
        if (c == target && d < 60) aimPoint = s.position + simd_normalize(away) * 400;
    }

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

    float range = capital ? 900 + BodyRadius(target) : 750;
    if (target && p.mode == AIModeAttack && dist < range) {
        simd_float3 leadDir = simd_normalize(aimPoint - s.position);
        float cone = capital ? 0.97f : 0.985f;
        double gap = s.shipClass == ShipClassInsurgent ? 0.35 : 0.22;
        if (simd_dot(s.forward, leadDir) > cone && _time - s.lastShot > gap + frand() * 0.25) {
            s.lastShot = _time;
            BOOL friend = s.team == TeamFriend;
            float capDamage = s.shipClass == ShipClassInsurgent ? 0.18f : (friend ? 0.1f : 0.05f);
            [self fireFrom:[s nextGunWorldPosition] velocity:s.velocity direction:simd_normalize(s.forward + randomUnit() * 0.008f)
                      team:s.team damage:friend ? 0.09f : 0.07f capDamage:capDamage player:NO];
            [_fx muzzleFlashOn:s.node local:s.lastGunLocal player:friend];
        }
    }
}

- (void)fireTurrets:(Capital *)c {
    if (!c.alive || c.isProp || c.team == TeamNeutral) return;
    for (Subsystem *t in c.subsystems) {
        if (t.kind != SubsystemTurret || !t.alive) continue;
        if (_time - t.lastShot < 1.1 + frand() * 0.6) continue;
        simd_float3 pos = [c worldPoint:t.local];
        simd_float3 out = [c worldDirection:t.muzzle];
        id best = nil;
        float bestD = FLT_MAX;
        NSMutableArray *fighters = [NSMutableArray arrayWithObject:_player];
        for (Pilot *q in _pilots) [fighters addObject:q.ship];
        for (Ship *f in fighters) {
            if (!f.alive || !TeamsHostile(c.team, f.team)) continue;
            float d = simd_distance(f.position, pos);
            if (d < 1100 && d < bestD && simd_dot(simd_normalize(f.position - pos), out) > -0.15f) { bestD = d; best = f; }
        }
        if (!best)
            for (Capital *o in _capitals) {
                if (!o.alive || o.isProp || !TeamsHostile(c.team, o.team)) continue;
                float d = simd_distance(o.position, pos) - o.radius;
                if (d < 1400 && d < bestD) { bestD = d; best = o; }
            }
        if (!best) continue;
        t.lastShot = _time;
        simd_float3 tp = BodyPosition(best), tv = BodyVelocity(best);
        float tHit = simd_distance(tp, pos) / kTurretBoltSpeed;
        simd_float3 aim = tp + (tv - c.velocity) * tHit;
        simd_float3 dir = simd_normalize(simd_normalize(aim - pos) + randomUnit() * 0.015f);
        BOOL vsCap = [best isKindOfClass:[Capital class]];
        Bolt *b = [self fireFrom:pos + out * 4 velocity:c.velocity direction:dir team:c.team damage:0.05f capDamage:vsCap ? 0.18f : 0.1f player:NO];
        if (b) b->velocity = c.velocity + dir * kTurretBoltSpeed;
    }
}

- (void)checkMine:(Capital *)m {
    NSMutableArray *fighters = [NSMutableArray arrayWithObject:_player];
    for (Pilot *q in _pilots) [fighters addObject:q.ship];
    for (Ship *f in fighters) {
        if (!f.alive || f.team == m.team) continue;
        if (simd_distance(f.position, m.position) < 60) {
            [self destroyCapital:m];
            for (Ship *g in fighters) {
                float d = simd_distance(g.position, m.position);
                if (g.alive && d < 90) [self damageShip:g amount:0.75f * (1 - d / 120) player:NO];
            }
            return;
        }
    }
}

#pragma mark - Weapons

- (Bolt *)fireFrom:(simd_float3)pos velocity:(simd_float3)v direction:(simd_float3)dir team:(Team)team
            damage:(float)damage capDamage:(float)capDamage player:(BOOL)player {
    for (int i = 0; i < MAX_BOLTS; i++) {
        if (_bolts[i].active) continue;
        Bolt *b = &_bolts[i];
        b->active = YES;
        b->team = team;
        b->fromPlayer = player;
        b->damage = damage;
        b->capDamage = capDamage;
        b->life = kBoltLife;
        b->position = pos;
        b->velocity = v + dir * kBoltSpeed;
        SCNNode *n = _boltNodes[i];
        [_fx styleBolt:n player:team == TeamFriend];
        n.simdPosition = b->position;
        n.simdOrientation = simd_quaternion(simd_make_float3(0, 1, 0), simd_normalize(b->velocity));
        n.hidden = NO;
        return b;
    }
    return NULL;
}

- (void)damageShip:(Ship *)s amount:(float)amount player:(BOOL)byPlayer {
    if (!s.alive) return;
    if (s == _player && getenv("SF_GOD")) amount = 0;   // debug: invulnerable player
    [s takeDamage:amount];
    if (s == _player) {
        _damageFlash = 1;
        _shake = fmaxf(_shake, 0.35f);
    }
    if (!s.alive) {
        if (s == _player) _deaths++;
        else if (byPlayer && s.team == TeamEnemy) _kills++;
        [self destroyShip:s];
    }
}

- (void)updateBolts:(float)dt {
    NSMutableArray *fighters = [NSMutableArray arrayWithObject:_player];
    for (Pilot *q in _pilots) [fighters addObject:q.ship];
    for (int i = 0; i < MAX_BOLTS; i++) {
        Bolt *b = &_bolts[i];
        if (!b->active) continue;
        simd_float3 p0 = b->position;
        simd_float3 p1 = p0 + b->velocity * dt;
        b->position = p1;
        b->life -= dt;
        BOOL hit = NO;
        for (Ship *s in fighters) {
            if (!s.alive || s.team == b->team) continue;
            if (SegmentHits(p0, p1, s.position, s.radius * (s == _player ? 0.8f : 0.85f))) {
                BOOL shielded = s.shield > 0.02f;
                [_fx impactAt:p1 player:b->team == TeamFriend shielded:shielded];
                [self damageShip:s amount:b->damage player:b->fromPlayer];
                // A hit makes AI pilots jink.
                for (Pilot *p in _pilots)
                    if (p.ship == s && p.mode == AIModeAttack && frand() < 0.35f) {
                        p.mode = AIModeEvade;
                        p.modeUntil = _time + 1.5 + frand() * 1.5;
                        p.evadePoint = s.position + (randomUnit() + s.right * (frand() < 0.5f ? -1.0f : 1.0f)) * 500.0f;
                    }
                hit = YES;
                break;
            }
        }
        if (!hit) {
            for (Capital *c in _capitals) {
                if (!c.alive || c.departed || c.team == b->team) continue;
                if (!SegmentHits(p0, p1, c.position, c.radius)) continue;
                simd_float3 point;
                Subsystem *sub = nil;
                if (![c hitSegmentFrom:p0 to:p1 point:&point subsystem:&sub]) continue;
                [self hitCapital:c subsystem:sub amount:b->capDamage at:point player:b->fromPlayer team:b->team];
                hit = YES;
                break;
            }
        }
        if (hit || b->life <= 0) {
            b->active = NO;
            _boltNodes[i].hidden = YES;
        } else {
            _boltNodes[i].simdPosition = p1;
        }
    }
}

- (void)hitCapital:(Capital *)c subsystem:(Subsystem *)sub amount:(float)amount at:(simd_float3)point player:(BOOL)byPlayer team:(Team)team {
    BOOL subAlive = sub.alive;
    BOOL absorbed = [c damage:amount subsystem:sub];
    [_fx impactAt:point player:team == TeamFriend shielded:absorbed && !c.invulnerable];
    if (sub && subAlive && !sub.alive) {
        float scale = sub.kind == SubsystemTurret ? 0.5f : (sub.kind == SubsystemCore ? 2.0f : 1.2f);
        [_fx explosionAt:[c worldPoint:sub.local] velocity:c.velocity hullMaterial:c.body.geometry.firstMaterial scale:scale];
        if (byPlayer) [_hud showMessage:[NSString stringWithFormat:@"%@ %@ destroyed", c.name, [[Subsystem nameForKind:sub.kind] lowercaseString]] from:@""];
    }
    if (!c.alive && !c.collected) {
        if (byPlayer && c.team == TeamEnemy && !c.isProp) _kills++;
        [self destroyCapital:c];
    }
}

- (void)destroyShip:(Ship *)s {
    s.alive = NO;
    s.deathTime = _time;
    s.node.hidden = YES;
    [s.exhaust setEnabled:NO];
    [_fx explosionAt:s.position velocity:s.velocity hullMaterial:s.model.geometry.firstMaterial];
    float d = simd_distance(s.position, _player.position);
    _shake = fmaxf(_shake, clampf(1.0f - d / 300.0f, 0, 1));
}

- (void)destroyCapital:(Capital *)c {
    c.alive = NO;
    c.deathTime = _time;
    if (c.isProp || c.radius < 20) {
        [_fx explosionAt:c.position velocity:c.velocity hullMaterial:c.body.geometry.firstMaterial scale:clampf(c.radius / 8.0f, 0.4f, 1.5f)];
        c.node.hidden = YES;
        return;
    }
    // Big ships break up: a chain of blasts over the hull, then the final one.
    int blasts = 5 + (int)(c.radius / 40);
    for (int i = 0; i < blasts; i++) [_explosionQueue addObject:@[@(_time + i * 0.35 + frand() * 0.2), c, @NO]];
    [_explosionQueue addObject:@[@(_time + blasts * 0.35 + 0.4), c, @YES]];
}

- (void)updateExplosions {
    for (NSArray *e in [_explosionQueue copy]) {
        if ([e[0] doubleValue] > _time) continue;
        [_explosionQueue removeObject:e];
        Capital *c = e[1];
        BOOL last = [e[2] boolValue];
        SCNMaterial *hull = c.body.geometry.firstMaterial;
        if (last) {
            [_fx explosionAt:c.position velocity:c.velocity hullMaterial:hull scale:c.radius / 18.0f];
            c.node.hidden = YES;
            float d = simd_distance(c.position, _player.position);
            _shake = fmaxf(_shake, clampf(1.0f - d / (c.radius * 6), 0, 1));
        } else {
            simd_float3 p = c.position + randomUnit() * c.radius * 0.5f;
            [_fx explosionAt:p velocity:c.velocity hullMaterial:hull scale:clampf(c.radius / 60.0f, 1.0f, 4.0f)];
        }
    }
}

- (void)collidePlayerFrom:(simd_float3)before {
    if (_time - _lastBump < 0.5) return;
    simd_float3 now = _player.position;
    for (Capital *c in _capitals) {
        if (!c.alive || c.departed || simd_distance(now, c.position) > c.radius + 10) continue;
        simd_float3 point;
        Subsystem *sub = nil;
        simd_float3 ahead = now + simd_normalize(_player.velocity + 1e-3f) * 4.0f;
        if (![c hitSegmentFrom:before to:ahead point:&point subsystem:&sub]) continue;
        _lastBump = _time;
        float speed = simd_length(_player.velocity);
        [self damageShip:_player amount:0.08f + speed * 0.0025f player:NO];
        _player.position = before - simd_normalize(_player.velocity + 1e-3f) * 2.0f;
        _player.velocity = -_player.velocity * 0.35f;
        _shake = fmaxf(_shake, 0.8f);
        [_fx impactAt:point player:NO shielded:YES];
        if (c.isMine) [self checkMine:c];
        return;
    }
}

#pragma mark - Targeting and torpedoes

- (NSArray *)targetables {
    NSMutableArray *list = [NSMutableArray array];
    for (Pilot *p in _pilots) if (p.ship.alive && p.ship.team == TeamEnemy) [list addObject:p.ship];
    NSMutableSet *objectiveIds = [NSMutableSet set];
    for (Objective *o in _objectives) if (o.state == ObjectiveActive) [objectiveIds addObjectsFromArray:o.targets];
    for (Capital *c in _capitals) {
        if (!c.alive || c.departed || [c.className isEqualToString:@"Asteroid"]) continue;
        if (![self visible:c]) continue;
        BOOL objective = [objectiveIds containsObject:c.identifier ?: @""] || [objectiveIds containsObject:c.group ?: @""];
        if (c.team == TeamEnemy || objective) [list addObject:c];
    }
    return list;
}

- (BOOL)visible:(Capital *)c {
    return c.stealthRange <= 0 || simd_distance(c.position, _player.position) < c.stealthRange;
}

- (void)cycleTarget {
    NSArray *list = [[self targetables] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        float da = simd_distance(BodyPosition(a), self->_player.position), db = simd_distance(BodyPosition(b), self->_player.position);
        return da < db ? NSOrderedAscending : (da > db ? NSOrderedDescending : NSOrderedSame);
    }];
    if (!list.count) { _selected = nil; return; }
    NSUInteger i = [list indexOfObject:_selected];
    _selected = list[i == NSNotFound ? 0 : (i + 1) % list.count];
}

- (void)autoTarget {
    if (BodyAlive(_selected) && (![_selected isKindOfClass:[Capital class]] || [self visible:_selected])) return;
    _selected = nil;
    float best = FLT_MAX;
    for (id u in [self targetables]) {
        simd_float3 rel = BodyPosition(u) - _player.position;
        float d = simd_length(rel);
        float off = acosf(clampf(simd_dot(_player.forward, rel / fmaxf(d, 1)), -1, 1));
        float score = off + d / 3000.0f;
        if (score < best) { best = score; _selected = u; }
    }
}

// On a capital, aim at the live subsystem closest to the nose (shield
// generators first while they are up).
- (void)updateAimSubsystem {
    _aimSubsystem = nil;
    if (![_selected isKindOfClass:[Capital class]]) return;
    Capital *c = _selected;
    BOOL shielded = c.shielded;
    float best = FLT_MAX;
    for (Subsystem *s in c.subsystems) {
        if (!s.alive || (shielded && s.kind != SubsystemShield)) continue;
        simd_float3 rel = [c worldPoint:s.local] - _player.position;
        float off = acosf(clampf(simd_dot(_player.forward, simd_normalize(rel)), -1, 1));
        if (off < best) { best = off; _aimSubsystem = s; }
    }
}

- (void)fireTorpedo {
    if (_torpedoCount <= 0 || !_player.alive || !_selected) return;
    if (simd_distance(BodyPosition(_selected), _player.position) > 2500) {
        [_hud showMessage:@"Target out of torpedo range" from:@""];
        return;
    }
    _torpedoCount--;
    Torpedo *t = [Torpedo new];
    t.position = _player.position + _player.forward * 6 - _player.up * 1.0f;
    t.velocity = _player.velocity + _player.forward * 120;
    t.life = 9;
    t.team = TeamFriend;
    t.target = _selected;
    t.aim = _aimSubsystem;
    SCNNode *n = [SCNNode node];
    SCNPlane *glow = [SCNPlane planeWithWidth:7 height:7];
    glow.firstMaterial = [Effects additiveTextureMaterial:@"flare_01" tint:simd_make_float3(3.0f, 1.6f, 0.6f)];
    SCNNode *g = [SCNNode nodeWithGeometry:glow];
    g.constraints = @[[SCNBillboardConstraint billboardConstraint]];
    g.castsShadow = NO;
    [n addChildNode:g];
    n.simdPosition = t.position;
    [_scene.rootNode addChildNode:n];
    t.node = n;
    [_torpedoes addObject:t];
}

- (void)updateTorpedoes:(float)dt {
    for (Torpedo *t in [_torpedoes copy]) {
        t.life -= dt;
        id target = t.target;
        if (BodyAlive(target)) {
            simd_float3 goal = BodyPosition(target);
            if (t.aim.alive && [target isKindOfClass:[Capital class]]) goal = [(Capital *)target worldPoint:t.aim.local];
            float speed = simd_length(t.velocity);
            simd_float3 want = simd_normalize(goal + BodyVelocity(target) * (simd_distance(goal, t.position) / fmaxf(speed, 1)) - t.position);
            simd_float3 dir = simd_normalize(t.velocity);
            dir = simd_normalize(dir + (want - dir) * fminf(1, 3.0f * dt));
            speed = fminf(speed + 260 * dt, 420);
            t.velocity = dir * speed;
        }
        simd_float3 p0 = t.position, p1 = p0 + t.velocity * dt;
        t.position = p1;
        t.node.simdPosition = p1;
        BOOL boom = t.life <= 0;
        if ([target isKindOfClass:[Ship class]] && BodyAlive(target) && simd_distance(p1, BodyPosition(target)) < 10) {
            [self damageShip:target amount:1.2f player:YES];
            boom = YES;
        }
        if (!boom)
            for (Capital *c in _capitals) {
                if (!c.alive || c.team == t.team || !SegmentHits(p0, p1, c.position, c.radius)) continue;
                simd_float3 point;
                Subsystem *sub = nil;
                if (![c hitSegmentFrom:p0 to:p1 point:&point subsystem:&sub]) continue;
                // Torpedoes are proximity-fused against the subsystem they were aimed at.
                if (!sub && t.aim.alive && simd_distance(point, [c worldPoint:t.aim.local]) < 25) sub = t.aim;
                [self hitCapital:c subsystem:sub amount:4.0f at:point player:YES team:t.team];
                boom = YES;
                break;
            }
        if (boom) {
            [_fx explosionAt:p1 velocity:0 hullMaterial:nil scale:0.7f];
            [t.node removeFromParentNode];
            [_torpedoes removeObject:t];
        }
    }
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
- (void)updateCamera:(float)dt controls:(ControlState)c {
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

    simd_quatf shipQ = _player.orientation;
    _camOrientation = simd_slerp(_camOrientation, shipQ, 1.0f - expf(-(_cockpit ? 30.0f : 7.0f) * dt));
    simd_quatf q = simd_mul(_cockpit ? shipQ : _camOrientation, look);

    float speed = simd_length(_player.velocity);
    // Ease boost effects in and out so toggling boost never pops the camera.
    _boostFx += ((_player.boosting ? 1.0f : 0.0f) - _boostFx) * (1.0f - expf(-4.0f * dt));
    float boostFx = _boostFx;
    simd_float3 offset = _cockpit ? kCockpitEye
                                  : simd_make_float3(0, 3.4f, 17.0f + speed * 0.012f + boostFx * 3.0f);
    simd_float3 pos = _player.position + simd_act(_cockpit ? shipQ : _camOrientation, simd_act(look, offset));
    if (_cockpit) pos = _player.position + simd_act(shipQ, offset);

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
    _player.model.hidden = _cockpit;
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

- (void)fillTarget:(HUDTarget *)t at:(simd_float3)pos velocity:(simd_float3)vel radius:(float)radius size:(CGSize)size {
    simd_float3 camPos = _cameraNode.simdPosition;
    CGPoint mid = CGPointMake(size.width / 2, size.height / 2);
    t->distance = simd_distance(pos, _player.position);
    CGPoint p;
    BOOL front = [self project:pos into:&p];
    BOOL inside = front && p.x > 20 && p.y > 20 && p.x < size.width - 20 && p.y < size.height - 20;
    if (inside) {
        t->onScreen = YES;
        t->point = p;
        float d = simd_distance(pos, camPos);
        t->size = clampf(radius * 2.6f / fmaxf(d, 1.0f) * (float)size.height * 0.75f, 22, 260);
        simd_float3 relV = vel - _player.velocity;
        float tHit = t->distance / kBoltSpeed;
        for (int k = 0; k < 2; k++) tHit = simd_distance(pos + relV * tHit, _player.position) / kBoltSpeed;
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

- (void)updateHUD:(ControlState)c {
    [self autoTarget];
    [self updateAimSubsystem];

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
    f.cockpit = _cockpit;
    f.torpedoes = _torpedoCount;
    f.status = _status;
    if (_aimSubsystem) f.aimVisible = [self project:[(Capital *)_selected worldPoint:_aimSubsystem.local] into:&f.aim];

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
    for (Pilot *p in _pilots) {
        Ship *s = p.ship;
        if (!s.alive || n >= MAX_HUD) continue;
        HUDTarget t = {0};
        t.kind = s.team == TeamEnemy ? HUDKindEnemy : HUDKindFriend;
        t.selected = s == _selected;
        t.health = s.hull;
        t.label = p.callsign;
        [self fillTarget:&t at:s.position velocity:s.velocity radius:s.radius size:size];
        targets[n++] = t;
    }
    for (Capital *cap in _capitals) {
        if (!cap.alive || cap.departed || n >= MAX_HUD || [cap.className isEqualToString:@"Asteroid"] || ![self visible:cap]) continue;
        float d = simd_distance(cap.position, _player.position);
        if (cap.isProp && d > (cap.isMine ? 1500 : 3000) && cap != _selected) continue;
        if ([cap.asset isEqualToString:@"NavBuoy"]) continue;
        HUDTarget t = {0};
        t.kind = cap.team == TeamEnemy ? HUDKindEnemy : (cap.team == TeamFriend ? HUDKindFriend : HUDKindNeutral);
        t.capital = !cap.isProp;
        t.selected = cap == _selected;
        t.label = cap.isProp ? (t.selected ? cap.name : nil) : cap.name;
        [self fillTarget:&t at:cap.position velocity:cap.velocity radius:cap.radius * 0.6f size:size];
        targets[n++] = t;
    }
    if (_currentNav && n < MAX_HUD) {
        HUDTarget t = {0};
        t.kind = HUDKindNav;
        t.label = _navNames[_currentNav];
        [self fillTarget:&t at:[self navPosition:_currentNav] velocity:_player.velocity radius:5 size:size];
        t.hasLead = NO;
        targets[n++] = t;
    }
    [_hud updateFrame:f targets:targets count:n];
    if (_cockpit) [self updateCockpit:c];

    NSString *inputText = [NSString stringWithFormat:@"%@%@  |  %@  |  T target  G torpedo  H help  ESC menu",
                           _input.joystickName ? [NSString stringWithFormat:@"Joystick: %@ (%@)", _input.joystickName, _input.axisDescription] : @"No joystick",
                           _input.throttleFromJoystick ? @" [throttle: stick]" : @" [throttle: keys]",
                           _input.mouseCaptured ? @"mouse captured (ESC releases)" : @"click to capture mouse"];
    if (![inputText isEqualToString:_lastInputText]) {
        _lastInputText = inputText;
        [_hud setInputText:inputText];
    }
}

#pragma mark - Cockpit

- (void)updateCockpit:(ControlState)c {
    CockpitFrame f = {0};
    f.throttle = _player.throttle;
    f.speed = simd_length(_player.velocity);
    f.maxSpeed = _player.maxSpeed;
    f.boostEnergy = _player.boostEnergy;
    f.hull = _player.hull;
    f.shield = _player.shield;
    f.damageFlash = _damageFlash;
    f.boosting = _player.boosting;
    f.alive = _player.alive;
    f.firing = c.fire && _player.alive;
    f.pitch = c.pitch;
    f.yaw = c.yaw;
    f.roll = c.roll;
    f.kills = _kills;
    f.deaths = _deaths;
    f.time = _missionTime;
    f.target = -1;
    f.nearest = FLT_MAX;
    f.torpedoes = _torpedoCount;
    f.objective = _objectiveSummary;

    simd_quatf inv = simd_inverse(_player.orientation);
    CockpitContact contacts[COCKPIT_MAX_CONTACTS];
    NSUInteger n = 0;
    NSMutableArray *bodies = [NSMutableArray array];
    for (Pilot *p in _pilots) if (p.ship.alive) [bodies addObject:p];
    for (Capital *cap in _capitals)
        if (cap.alive && !cap.departed && ![cap.className isEqualToString:@"Asteroid"] && ![cap.asset isEqualToString:@"NavBuoy"] && [self visible:cap])
            [bodies addObject:cap];
    // Nearest first, so the scanner keeps what matters when it overflows.
    [bodies sortUsingComparator:^NSComparisonResult(id a, id b) {
        id ba = [a isKindOfClass:[Pilot class]] ? ((Pilot *)a).ship : a, bb = [b isKindOfClass:[Pilot class]] ? ((Pilot *)b).ship : b;
        if (ba == self->_selected) return NSOrderedAscending;
        if (bb == self->_selected) return NSOrderedDescending;
        float da = simd_distance(BodyPosition(ba), self->_player.position), db = simd_distance(BodyPosition(bb), self->_player.position);
        return da < db ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (id item in bodies) {
        if (n >= COCKPIT_MAX_CONTACTS) break;
        BOOL isPilot = [item isKindOfClass:[Pilot class]];
        id body = isPilot ? ((Pilot *)item).ship : item;
        simd_float3 rel = BodyPosition(body) - _player.position;
        float dist = simd_length(rel);
        CockpitContact k = {0};
        k.local = simd_act(inv, rel);
        k.team = BodyTeam(body);
        if (isPilot) {
            Pilot *p = item;
            k.orientation = simd_mul(inv, p.ship.orientation);
            k.hull = p.ship.hull;
            k.shield = p.ship.shield;
            k.geometry = [Ship geometryForClass:p.ship.shipClass];
            k.holoScale = 0.0075f;
            k.name = p.callsign ?: DisplayClass(p.ship.shipClass);
            k.className = p.ship.team == TeamEnemy ? @"Skarn fighter" : @"Concord fighter";
            k.attacking = p.ship.team == TeamEnemy && p.mode == AIModeAttack && p.target == _player &&
                          simd_dot(p.ship.forward, -rel / fmaxf(dist, 1)) > 0.8f;
            if (k.attacking && dist < 700 && k.local.z > 0) f.six = YES;
            if (p.ship.team == TeamEnemy) f.nearest = fminf(f.nearest, dist);
        } else {
            Capital *cap = item;
            k.orientation = simd_mul(inv, cap.orientation);
            k.hull = cap.hull / cap.maxHull;
            k.shield = cap.shielded ? (float)[cap aliveCount:SubsystemShield] / fmaxf([cap totalCount:SubsystemShield], 1) : 0;
            k.capital = !cap.isProp;
            k.geometry = cap.body.geometry;
            k.holoScale = 0.04f / fmaxf(cap.radius, 1);
            k.name = cap.name;
            k.className = cap.className;
            k.shielded = cap.shielded;
            if (cap.team == TeamEnemy && (cap.isMine || !cap.isProp)) f.nearest = fminf(f.nearest, dist - cap.radius);
        }
        if (body == _selected) {
            f.target = (int)n;
            simd_float3 relV = BodyVelocity(body) - _player.velocity;
            f.closingSpeed = -simd_dot(relV, rel / fmaxf(dist, 1));
            float tHit = dist / kBoltSpeed;
            for (int kk = 0; kk < 2; kk++) tHit = simd_distance(BodyPosition(body) + relV * tHit, _player.position) / kBoltSpeed;
            simd_float3 lead = simd_normalize(BodyPosition(body) + relV * tHit - _player.position);
            float cone = isPilot ? 2.5f : 2.5f + atanf(BodyRadius(body) / fmaxf(dist, 1)) * 57.3f;
            f.lock = dist < 1200 + (isPilot ? 0 : BodyRadius(body)) && simd_dot(lead, _player.forward) > cosf(cone * (float)M_PI / 180.0f);
        }
        contacts[n++] = k;
    }
    [_cockpitModel updateFrame:f contacts:contacts count:n];
}

@end
