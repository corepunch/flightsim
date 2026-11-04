#import "Host.h"
#import "Server.h"
#import "Client.h"
#import "ClientView.h"
#import "Briefing.h"
#import "Loading.h"
#import "Progress.h"
#import "Assets.h"
#include "SharedMath.h"
#import <stdatomic.h>

typedef NS_ENUM(NSInteger, HostState) { HostStateLoading, HostStateMenu, HostStateFlying, HostStateOver };

// What the loading screen says while the background queue is on each step.
typedef NS_ENUM(int, LoadStage) {
    LoadStageStart, LoadStageSky, LoadStageCockpit, LoadStageFleet,
    LoadStageWings, LoadStageUpload, LoadStageShaders, LoadStageReady,
};
static NSString *LoadStatus(LoadStage s) {
    switch (s) {
        case LoadStageStart: return @"LOADING";
        case LoadStageSky: return @"CHARTING STARFIELD";
        case LoadStageCockpit: return @"POWERING UP COCKPIT";
        case LoadStageFleet: return @"PLOTTING CAPITAL SHIPS";
        case LoadStageWings: return @"SCRAMBLING FIGHTER WINGS";
        case LoadStageUpload: return @"UPLOADING GEOMETRY AND TEXTURES";
        case LoadStageShaders: return @"COMPILING SHADERS";
        case LoadStageReady: return @"READY";
    }
    return @"LOADING";
}

static const double kMinMissionLoadSeconds = 1.2;   // long enough to read the title card

@implementation Host {
    __weak SCNView *_view;
    Input *_input;
    Server *_server;
    Client *_client;
    ClientView *_clientView;
    Briefing *_briefing;
    Loading *_loading;

    HostState _state;
    NSUInteger _missionIndex;
    double _lastTime, _time;

    dispatch_queue_t _loadQueue;
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
        _briefing = [[Briefing alloc] initWithSize:view.bounds.size];
        _loading = [[Loading alloc] initWithSize:view.bounds.size];
        [_loading showTitle:@"Kestrel Frontier" kicker:@"SPACE FIGHT"
                     detail:@"CNS BASTION  /  LANCER FLIGHT"];
        _clientView = [[ClientView alloc] initWithView:view input:input];
        _client = [[Client alloc] initWithView:_clientView];
        __weak Host *weakSelf = self;
        _client.missionEndHandler = ^(BOOL success, NSArray<NSString *> *results) { [weakSelf missionEnded:success results:results]; };
        _server = [Server new];
        [_client connectLocal:_server name:NSFullUserName() ?: @"Pilot"];

        // Show the loading card over an empty scene right away; the real scene
        // is built off the main thread and swapped in when it is ready.
        _state = HostStateLoading;
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
- (void)prepare:(NSArray *)objects from:(float)p0 to:(float)p1 {
    SCNView *view = _view;
    NSUInteger n = objects.count;
    for (NSUInteger i = 0; i < n; i++) {
        [view prepareObject:objects[i] shouldAbortBlock:nil];
        atomic_store(&_loadProgress, p0 + (p1 - p0) * (float)(i + 1) / (float)n);
    }
}

// Load queue: the whole scene, which nobody is rendering yet.
- (void)bootInBackground {
    CFTimeInterval t0 = CACurrentMediaTime();
    [self reportStage:LoadStageSky progress:0.05f];
    [SCNTransaction begin];
    [SCNTransaction setDisableActions:YES];
    [_clientView buildScene];
    [SCNTransaction commit];
    [SCNTransaction flush];
    [self reportStage:LoadStageShaders progress:0.7f];
    [self prepare:[_clientView warmupObjects] from:0.7f to:1.0f];
    [self reportStage:LoadStageReady progress:1];
    NSLog(@"Boot loaded in %.2f s", CACurrentMediaTime() - t0);
    atomic_store(&_loadDone, true);
}

// Render thread, once the boot load is done and the bar is full.
- (void)finishBoot {
    _booted = YES;
    SCNView *view = _view;
    SCNScene *scene = _clientView.scene;
    SCNNode *camera = _clientView.cameraNode;
    dispatch_async(dispatch_get_main_queue(), ^{
        view.scene = scene;
        view.pointOfView = camera;
    });
    _state = HostStateMenu;
    const char *m = getenv("SF_MISSION");   // debug: fly mission N straight away
    if (m && atoi(m) >= 1) {
        [self startMission:(NSUInteger)atoi(m) - 1];
        return;
    }
    [_briefing showListSelecting:ProgressUnlockedCount() - 1];
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
    SKScene *next = _state == HostStateFlying ? _clientView.hud : _briefing;
    if (_state == HostStateFlying) [_clientView.hud showBanner:[CampaignMission(_missionIndex)[@"title"] uppercaseString] color:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.overlaySKScene = next; });
}

#pragma mark - Missions

// Render thread: put up the loading card and build the mission off-thread.
- (void)startMission:(NSUInteger)index {
    if (_state == HostStateLoading) return;
    [_server stop];
    [_clientView clearMission];
    _state = HostStateLoading;
    _revealing = NO;
    _missionIndex = index;
    NSDictionary *mission = CampaignMission(index);

    NSDictionary *b = mission[@"briefing"];
    NSString *detail = b[@"stardate"] ? [NSString stringWithFormat:@"%@   /   SD %@", b[@"location"] ?: @"", b[@"stardate"]] : b[@"location"];
    [_loading showTitle:mission[@"title"]
                 kicker:[NSString stringWithFormat:@"KESTREL FRONTIER  /  MISSION %02lu", (unsigned long)index + 1]
                 detail:detail];
    [self reportStage:LoadStageStart progress:0];
    atomic_store(&_loadDone, false);
    _loadStartedAt = _time;
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.overlaySKScene = self->_loading; });
    dispatch_async(_loadQueue, ^{ [self loadMissionInBackground:(int)index]; });
}

// Load queue. The render thread only animates the loading card while this
// runs, so neither the server nor the client view is touched concurrently.
- (void)loadMissionInBackground:(int)index {
    CFTimeInterval t0 = CACurrentMediaTime();
    [self reportStage:LoadStageFleet progress:0.05f];
    [_server spawnMission:index];
    [_server flush];                    // delivers the gamestate to the client
    [self reportStage:LoadStageSky progress:0.2f];

    float p = 0;
    NSArray *objects = [_clientView loadMissionAssets:&p];
    [self reportStage:LoadStageUpload progress:0.6f];
    [self prepare:objects from:0.6f to:1.0f];
    [self reportStage:LoadStageReady progress:1];
    NSLog(@"Mission %d loaded in %.2f s (%lu prototypes)", index + 1, CACurrentMediaTime() - t0, (unsigned long)objects.count);
    atomic_store(&_loadDone, true);
}

// Render thread: attach what the load queue built and start flying.
- (void)finishMission {
    [_clientView attachMission];
    [_client begin];
    [_server flush];
    _state = HostStateFlying;
    [self reveal:0.6];
}

- (void)missionEnded:(BOOL)success results:(NSArray<NSString *> *)results {
    if (_state != HostStateFlying) return;
    _state = HostStateOver;
    if (success) ProgressMarkCompleted(_missionIndex);
    [_server stop];
    [_briefing showDebrief:_missionIndex success:success results:results];
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.overlaySKScene = self->_briefing; });
}

- (void)abortToMenu {
    _state = HostStateMenu;
    [_server stop];
    [_clientView clearMission];
    [_briefing showListSelecting:_missionIndex];
    dispatch_async(dispatch_get_main_queue(), ^{ self->_view.overlaySKScene = self->_briefing; });
}

#pragma mark - Loop

- (void)renderer:(id<SCNSceneRenderer>)renderer willRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time {
    if (!_booted) return;   // the cockpit may still be under construction on the load queue
    [_clientView renderDisplaysWithQueue:renderer.commandQueue time:time];
}

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    float dt = _lastTime > 0 ? (float)(time - _lastTime) : 1.0f / 60.0f;
    _lastTime = time;
    dt = clampf(dt, 0.0005f, 1.0f / 20.0f);
    _time += dt;

    InputAction actions = [_input consumeActions];
    ControlState controls = [_input poll:dt];
    if (_state == HostStateLoading) { [self updateLoading]; return; }
    if (_revealing) {
        [self updateReveal];
        if (_state == HostStateMenu) actions = 0;   // the menu isn't visible yet
    }
    if (actions & InputActionToggleCamera) _clientView.cockpit = !_clientView.cockpit;
    if (actions & InputActionToggleHelp) [_clientView.hud toggleHelp];

    if (_state != HostStateFlying) {
        [self updateMenu:actions];
        return;
    }
    if (actions & InputActionRestart) { [self startMission:_missionIndex]; return; }
    if (actions & InputActionBack) { [self abortToMenu]; return; }

    [_client sendInput:controls actions:actions dt:dt];
    [_server frame:dt];
    if (_state != HostStateFlying) return;   // the mission ended during that frame
    [_client drawWithControls:controls time:_time dt:dt];
}

- (void)updateMenu:(InputAction)actions {
    [_briefing tick:_time];
    if ([_briefing handle:actions] == BriefingCommandLaunch) {
        [self startMission:_briefing.selectedIndex];
        return;
    }
    [_clientView menuFrame:_time];   // slow drift through the sky behind the menus
}

@end
