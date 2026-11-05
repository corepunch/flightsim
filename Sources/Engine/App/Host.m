#import "Host.h"
#import "GameView.h"
#import "Server.h"
#import "Client.h"
#import "ClientView.h"
#import "Briefing.h"
#import "MainMenu.h"
#import "PauseMenu.h"
#import "Loading.h"
#import "LoadingLocalization.h"
#import "Progress.h"
#import "NetTransport.h"
#import "UDPTransport.h"
#import "LANBrowser.h"
#import "NetProtocol.h"
#import "ServerBrowser.h"
#import "UIMotion.h"
#import "Assets.h"
#import "GameAudio.h"
#import "Cvar.h"
#import "Cmd.h"
#include "SharedMath.h"
#import <stdatomic.h>
#if TARGET_OS_IOS
#include <ifaddrs.h>
#include <netdb.h>
#endif

static NSString *PilotName(void) {
#if TARGET_OS_IOS
    return @"Pilot";
#else
    return NSFullUserName() ?: @"Pilot";
#endif
}

typedef NS_ENUM(NSInteger, HostState) { HostStateLoading, HostStateMainMenu, HostStateMissions, HostStateFlying, HostStatePaused, HostStateOver, HostStateBrowser };

// What the loading screen says while the background queue is on each step.
typedef NS_ENUM(int, LoadStage) {
    LoadStageStart, LoadStageSky, LoadStageCockpit, LoadStageFleet,
    LoadStageWings, LoadStageUpload, LoadStageShaders, LoadStageReady,
};
static NSString *LoadStatus(LoadStage s) {
    switch (s) {
        case LoadStageStart: return LoadingText(@"loading_mission", @"Loading mission…");
        case LoadStageSky: return LoadingText(@"charting_starfield", @"Charting starfield…");
        case LoadStageCockpit: return LoadingText(@"preparing_ship", @"Preparing spacecraft…");
        case LoadStageFleet: return LoadingText(@"plotting_capital_ships", @"Plotting capital ships…");
        case LoadStageWings: return LoadingText(@"scrambling_fighter_wings", @"Scrambling fighter wings…");
        case LoadStageUpload: return LoadingText(@"uploading_assets", @"Uploading geometry and textures…");
        case LoadStageShaders: return LoadingText(@"compiling_shaders", @"Compiling shaders…");
        case LoadStageReady: return LoadingText(@"mission_ready", @"Mission ready");
    }
    return LoadingText(@"loading_mission", @"Loading mission…");
}

static const double kMinMissionLoadSeconds = 1.2;   // long enough to read the title card

@implementation Host {
    __weak SCNView *_view;
    Input *_input;
    Server *_server;
    Client *_client;
    ClientView *_clientView;
    Briefing *_briefing;
    MainMenu *_mainMenu;
    PauseMenu *_pauseMenu;
    BOOL _resumeMouse;
    Loading *_loading;

    HostState _state, _browserReturnState;
    NSUInteger _missionIndex;
    double _lastTime, _time;

    dispatch_queue_t _loadQueue;
    _Atomic float _loadProgress;
    _Atomic int _loadStage;
    _Atomic bool _loadDone;
    double _loadStartedAt;
    BOOL _booted, _revealing, _precaching;

    // Multiplayer: our server also listens on UDP, so others on the LAN can
    // join whatever we fly; or we join theirs.
    UDPTransport *_serverUDP, *_clientUDP;
    LANBrowser *_lan;
    ServerBrowser *_browser;

    // Overlay changes wait for the outgoing screen's exit animation.
    SKScene *_shownOverlay;
    SKNode *_loadingBackdrop;
    double _exitDeadline;
    void (^_afterExit)(void);

    Cvar *_testInput, *_cockpit, *_autoStart;
}

- (instancetype)initWithView:(SCNView *)view input:(Input *)input {
    if ((self = [super init])) {
        _view = view;
        [GameAudio shared];
        _input = input;
        [self registerConsole];
        _loadQueue = dispatch_queue_create("SpaceFight.loading", DISPATCH_QUEUE_SERIAL);
        _briefing = [[Briefing alloc] initWithSize:view.bounds.size];
        _mainMenu = [[MainMenu alloc] initWithSize:view.bounds.size];
        _pauseMenu = [[PauseMenu alloc] initWithSize:view.bounds.size];
        _loading = [[Loading alloc] initWithSize:view.bounds.size];
        [_loading showTitle:@"Kestrel Frontier" kicker:@"SPACE FIGHT"
                     detail:@"CNS BASTION  /  LANCER FLIGHT"];
        _clientView = [[ClientView alloc] initWithView:view input:input];
        _clientView.cockpit = _cockpit.boolValue;
        __weak ClientView *weakView = _clientView;
        _cockpit.onChange = ^(Cvar *c) { weakView.cockpit = c.boolValue; };
        _client = [[Client alloc] initWithView:_clientView];
        __weak Host *weakSelf = self;
        _client.missionEndHandler = ^(BOOL success, NSArray<NSString *> *results) { [weakSelf missionEnded:success results:results]; };
        _client.gamestateHandler = ^{ [weakSelf gamestateArrived]; };
        _client.disconnectHandler = ^(NSString *reason) { [weakSelf disconnected:reason]; };
        // The local server: this player reaches it over loopback, with the
        // same packets a remote player would send.
        _server = [[Server alloc] initWithName:[NSString stringWithFormat:@"%@'s game", PilotName()]];
        [_server addTransport:[LoopbackTransport side:1]];
        int port = [Cvar get:@"net_port" defaultValue:[NSString stringWithFormat:@"%d", PORT_SERVER] flags:CVAR_NOSET
                        help:@"UDP port the local server listens on; 0 turns hosting off"].integer;
        if (port > 0) {
            _serverUDP = [[UDPTransport alloc] initWithPort:port attempts:4];
            if (_serverUDP) [_server addTransport:_serverUDP];
        }
        _browser = [[ServerBrowser alloc] initWithSize:view.bounds.size];
        _browser.hostLine = _serverUDP ? [NSString stringWithFormat:@"Your missions are open to this network on UDP port %d", _serverUDP.port]
                                       : @"Hosting is off (no UDP port)";
        [self connectLocal];

        // Show the loading card over an empty scene right away; the real scene
        // is built off the main thread and swapped in when it is ready.
        _state = HostStateLoading;
        SCNScene *placeholder = [SCNScene scene];
        placeholder.background.contents = [SKColor blackColor];
        view.scene = placeholder;
        view.overlaySKScene = _loading;
        _shownOverlay = _loading;
#if !TARGET_OS_IOS
        view.delegate = self;
#endif
        view.playing = YES;
        view.loops = YES;
        view.rendersContinuously = YES;
#if TARGET_OS_IOS
        view.preferredFramesPerSecond = 60;
        view.antialiasingMode = SCNAntialiasingModeMultisampling2X;
#else
        view.preferredFramesPerSecond = 120;
        view.antialiasingMode = SCNAntialiasingModeMultisampling4X;
#endif
        view.backgroundColor = [SKColor blackColor];
        _loadStartedAt = 0;
        dispatch_async(_loadQueue, ^{ [self bootInBackground]; });
    }
    return self;
}

#pragma mark - Console

// Cvars and commands the front end answers to. Commands run on the frame
// thread (from the command buffer or the command line after boot).
- (void)registerConsole {
    _testInput = [Cvar get:@"cl_testInput" defaultValue:@"0" flags:CVAR_CHEAT
                      help:@"A pilot who weaves and fires, for testing prediction"];
    _cockpit = [Cvar get:@"cl_cockpit" defaultValue:@"0" flags:CVAR_ARCHIVE help:@"Fly from the cockpit instead of the chase camera"];
    _autoStart = [Cvar get:@"cl_autoStart" defaultValue:@"0" flags:0 help:@"Skip the loading card's start prompt (scripted runs)"];
    __weak Host *weak = self;
    [Cmd add:@"map" help:@"map <mission number>: flies that mission" handler:^(NSArray<NSString *> *a) {
        NSUInteger count = CampaignMissions().count;
        int n = a.count > 1 ? a[1].intValue : 0;
        if (n < 1 || (NSUInteger)n > count) { NSLog(@"usage: map <1..%lu>", (unsigned long)count); return; }
        [weak startMission:(NSUInteger)n - 1];
    }];
    [Cmd add:@"briefing" help:@"briefing <mission number> [page]: opens that briefing" handler:^(NSArray<NSString *> *a) {
        NSUInteger count = CampaignMissions().count;
        int n = a.count > 1 ? a[1].intValue : 0, page = a.count > 2 ? a[2].intValue : 1;
        if (n < 1 || (NSUInteger)n > count) { NSLog(@"usage: briefing <1..%lu> [page]", (unsigned long)count); return; }
        [weak showBriefing:(NSUInteger)n - 1 page:(NSUInteger)MAX(page - 1, 0)];
    }];
    [Cmd add:@"connect" help:@"connect <host[:port]>: joins that server" handler:^(NSArray<NSString *> *a) {
        if (a.count < 2) { NSLog(@"usage: connect <host[:port]>"); return; }
        NetAddress *address = [NetAddress addressWithString:a[1] port:PORT_SERVER];
        if (!address) { NSLog(@"connect: cannot resolve %@", a[1]); return; }
        [weak connectToAddress:address];
    }];
    [Cmd add:@"disconnect" help:@"Leaves the current server or mission" handler:^(NSArray<NSString *> *a) {
        [weak disconnectCommand];
    }];
    [Cmd add:@"screenshot" help:@"screenshot <file.png>: saves the next frame" handler:^(NSArray<NSString *> *a) {
        if (a.count < 2) { NSLog(@"usage: screenshot <file.png>"); return; }
        [weak saveScreenshot:a[1]];
    }];
    [Cmd add:@"quit" help:@"Exits the game" handler:^(NSArray<NSString *> *a) {
        dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_OSX
            [NSApp terminate:nil];
#else
            exit(0);
#endif
        });
    }];
}

- (void)showBriefing:(NSUInteger)index page:(NSUInteger)page {
    if (!_booted || _state == HostStateLoading) { NSLog(@"briefing: not in the menus"); return; }
    if (_state == HostStateFlying || _state == HostStatePaused || _state == HostStateOver) [self abortToMenu];
    _state = HostStateMissions;
    [_briefing showBriefing:index page:page];
    // Straight after boot the loading card is still up: it fades, then the
    // reveal presents whatever _state asks for.
    if (_shownOverlay == _loading && !_revealing) [self reveal:0.5];
    else if (!_revealing) [self presentOverlay:_briefing];
}

- (void)connectToAddress:(NetAddress *)address {
    if (!_booted) { NSLog(@"connect: not booted yet"); return; }
    if (_state == HostStateFlying || _state == HostStatePaused || _state == HostStateOver) [self abortToMenu];
    if (_shownOverlay == _loading && !_revealing) [self reveal:0.5];
    [self showBrowser];
    [self joinServer:address];
}

- (void)disconnectCommand {
    if (_state == HostStateFlying || _state == HostStatePaused || _state == HostStateOver) { [self abortToMenu]; return; }
    if (self.remote) { [_client disconnect]; [self connectLocal]; }
    if (_booted && _state != HostStateLoading) [self showMainMenu];
}

- (void)saveScreenshot:(NSString *)path {
    SCNView *view = _view;
    dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_OSX
        NSImage *image = [view snapshot];
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        NSBitmapImageRep *rep = cg ? [[NSBitmapImageRep alloc] initWithCGImage:cg] : nil;
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
#else
        NSData *png = UIImagePNGRepresentation([view snapshot]);
#endif
        if (!png || ![png writeToFile:path.stringByExpandingTildeInPath atomically:YES]) NSLog(@"screenshot: cannot write %@", path);
        else NSLog(@"screenshot: wrote %@", path);
    });
}

- (void)connectLocal {
    [_client connectTo:[NetAddress loopback:1] transport:[LoopbackTransport side:0] name:PilotName()];
}

- (BOOL)remote { return _client.serverAddress && !_client.serverAddress.isLoopback; }

// Leave our own server idle and connect to someone else's. The gamestate it
// sends (now, or when it starts a mission) takes us through loading.
- (void)joinServer:(NetAddress *)address {
    if (!address) return;
    [_server stop];
    [_clientView clearMission];
    if (!_clientUDP) _clientUDP = [[UDPTransport alloc] initWithPort:0 attempts:1];
    NSLog(@"Host: joining %@", address);
    [_client connectTo:address transport:_clientUDP name:PilotName()];
    [_browser setStatus:[NSString stringWithFormat:@"Connecting to %@... waiting for the host to launch a mission", address]];
}

- (void)showBrowser {
    _browserReturnState = _state;
    _state = HostStateBrowser;
    if (!_lan) _lan = [LANBrowser new];
    [_browser setStatus:self.remote ? [NSString stringWithFormat:@"Connected to %@", _client.serverAddress] : @""];
    if (!_revealing) [self presentOverlay:_browser];
}

- (void)updateBrowser:(InputAction)actions {
    [_lan poll];
    NSMutableArray *list = [NSMutableArray array];
    for (LANServer *s in _lan.servers)
        if (!(_serverUDP && s.address.port == _serverUDP.port && [self isOwnAddress:s.address])) [list addObject:s];
    [_browser showServers:list];
    switch ([_browser handle:actions]) {
        case BrowserCommandJoin: [self joinServer:_browser.selected.address]; break;
        case BrowserCommandBack: {
            if (self.remote && _client.state != ClientActive) { [_client disconnect]; [self connectLocal]; }
            if (_browserReturnState == HostStateMainMenu) [self showMainMenu];
            else {
                _state = _browserReturnState;
                [self presentOverlay:_briefing];
            }
            break;
        }
        default: break;
    }
    [_clientView menuFrame:_time];
}

// Our own listen server answers our broadcast too; leave it off the list.
- (BOOL)isOwnAddress:(NetAddress *)a {
    static NSSet *own;
    if (!own) {
        NSMutableSet *s = [NSMutableSet set];
#if TARGET_OS_IOS
        struct ifaddrs *interfaces = NULL;
        if (getifaddrs(&interfaces) == 0) {
            for (struct ifaddrs *i = interfaces; i; i = i->ifa_next) {
                if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
                char ip[NI_MAXHOST];
                if (getnameinfo(i->ifa_addr, i->ifa_addr->sa_len, ip, sizeof ip, NULL, 0, NI_NUMERICHOST) == 0)
                    [s addObject:@(ip)];
            }
            freeifaddrs(interfaces);
        }
#else
        for (NSString *ip in NSHost.currentHost.addresses) [s addObject:ip];
#endif
        [s addObject:@"127.0.0.1"];
        own = s;
    }
    NSString *ip = [a.string componentsSeparatedByString:@":"].firstObject;
    return [own containsObject:ip];
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
    _state = HostStateMainMenu;
    [self prepareMainMenu];
    [_briefing showListSelecting:ProgressUnlockedCount() - 1];
    // The command line's +map, +connect, +briefing, +exec run now that there
    // is something to act on.
    [Cmd executeLateCommands];
    if (_state != HostStateLoading && !_revealing) [self reveal:0.5];
}

// Fade the loading card out, then hand the overlay to the HUD or the menus.
- (void)reveal:(double)seconds {
    _revealing = YES;
    [_loading fadeOut:seconds];
}

- (void)updateLoading:(InputAction)actions {
    [_loading setProgress:atomic_load(&_loadProgress) status:LoadStatus((LoadStage)atomic_load(&_loadStage))];
    [_loading tick:_time];
    double minimum = _booted ? kMinMissionLoadSeconds : 0;
    if (atomic_load(&_loadDone) && _loading.barFull && _time - _loadStartedAt >= minimum) {
        if (_booted && !_autoStart.boolValue) {
            if (!_loading.readyToStart) {
                _loading.readyToStart = YES;
                return; // Discard actions from before the ready prompt appeared.
            }
            BOOL tapped = [_loading consumeStartRequest];
            if (!tapped && !(actions & InputActionConfirm)) return;
            [[GameAudio shared] play:@"ui-confirm"];
            _loading.readyToStart = NO;
        }
        atomic_store(&_loadDone, false);
        if (_booted) [self finishMission];
        else [self finishBoot];
    }
}

- (void)updateReveal {
    [_loading tick:_time];
    if (!_loading.faded) return;
    _revealing = NO;
    SKScene *next = _briefing;
    if (_state == HostStateMainMenu) next = _mainMenu;
    else if (_state == HostStateFlying) next = _clientView.hud;
    else if (_state == HostStateBrowser) next = _browser;
    if (_state == HostStateFlying) [_clientView.hud showBanner:[CampaignMission(_missionIndex)[@"title"] uppercaseString] color:nil];
    [self presentOverlay:next];
}

#pragma mark - Missions

// Render thread: put up the loading card and build the mission off-thread.
- (void)startMission:(NSUInteger)index {
    if (_state == HostStateLoading) return;
    _client.inputSuspended = NO;
    if (self.remote) { [_client disconnect]; [self connectLocal]; }   // flying our own mission now
    [_server stop];
    [_client leaveGame];
    [_clientView clearMission];
    [self showLoadingCard:index];
    _server.loading = YES;
    dispatch_async(_loadQueue, ^{
        CFTimeInterval t0 = CACurrentMediaTime();
        [self->_server spawnMission:(int)index];
        self->_server.loading = NO;   // the gamestate goes out on the next frame
        NSLog(@"Server: mission %d spawned in %.2f s", (int)index + 1, CACurrentMediaTime() - t0);
    });
}

// Render thread: the loading card for a mission, until the client is in.
- (void)showLoadingCard:(NSUInteger)index {
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
    [self reportStage:LoadStageFleet progress:0.05f];
    [self presentOverlay:_loading];
}

// Render thread: the server has sent a mission (ours or a remote host's).
// Precache its assets off-thread, then begin.
- (void)gamestateArrived {
    if (_precaching) return;
    NSUInteger index = (NSUInteger)_client.missionIndex;
    if (_state != HostStateLoading || index != _missionIndex) {
        [_clientView clearMission];
        [self showLoadingCard:index];
    }
    _precaching = YES;
    [self reportStage:LoadStageSky progress:0.2f];
    dispatch_async(_loadQueue, ^{ [self precacheInBackground]; });
}

// Load queue. The render thread only animates the loading card and pumps
// packets while this runs; the client view isn't drawn.
- (void)precacheInBackground {
    CFTimeInterval t0 = CACurrentMediaTime();
    float p = 0;
    NSArray *objects = [_clientView loadMissionAssets:&p];
    [self reportStage:LoadStageUpload progress:0.6f];
    [self prepare:objects from:0.6f to:1.0f];
    [self reportStage:LoadStageReady progress:1];
    NSLog(@"Client: mission %lu precached in %.2f s (%lu prototypes)", (unsigned long)_missionIndex + 1,
          CACurrentMediaTime() - t0, (unsigned long)objects.count);
    atomic_store(&_loadDone, true);
}

// Render thread: attach what the load queue built and start flying.
- (void)finishMission {
    _precaching = NO;
    [_clientView attachMission];
#if TARGET_OS_IOS
    if ([_view isKindOfClass:GameView.class]) [(GameView *)_view setSecondaryLabel:_client.configStrings[CS_SECONDARY_SHORT]];
#endif
    [_client begin];
    if (!self.remote) ProgressMarkStarted();
    _state = HostStateFlying;
    [self reveal:0.6];
}

- (void)disconnected:(NSString *)reason {
    _client.inputSuspended = NO;
    _loading.readyToStart = NO;
    _precaching = NO;
    [_browser setStatus:reason];
    if (_state == HostStateFlying || _state == HostStatePaused || _state == HostStateOver || (_state == HostStateLoading && _booted)) {
        _state = HostStateMissions;
        _revealing = NO;
        [_clientView clearMission];
        [_briefing showListSelecting:_missionIndex];
        [self presentOverlay:_briefing];
    }
    [self connectLocal];   // back to our own server
}

- (void)missionEnded:(BOOL)success results:(NSArray<NSString *> *)results {
    if (_state != HostStateFlying && _state != HostStatePaused) return;
    _client.inputSuspended = NO;
    [[GameAudio shared] play:success ? @"ui-success" : @"ui-alert"];
    _state = HostStateOver;
    if (success) { ProgressRecordResult(_missionIndex, results); ProgressMarkCompleted(_missionIndex); }
    if (!self.remote) [_server stop];   // a remote host decides what comes next
    [_client leaveGame];
    [_briefing showDebrief:_missionIndex success:success results:results];
    [self presentOverlay:_briefing];
}

- (void)pauseFlight {
    _state = HostStatePaused;
    _client.inputSuspended = YES;
#if !TARGET_OS_IOS
    _resumeMouse = _input.mouseCaptured;
    _input.mouseCaptured = NO;
    [_input releaseAllKeys];
#endif
    [_pauseMenu showRemote:self.remote cockpit:_cockpit.boolValue];
    [self presentOverlay:_pauseMenu];
}

- (void)updatePause:(InputAction)actions {
    switch ([_pauseMenu handle:actions]) {
        case PauseCommandResume:
            _state = HostStateFlying;
            _client.inputSuspended = NO;
            [self presentOverlay:_clientView.hud];
#if !TARGET_OS_IOS
            _input.mouseCaptured = _resumeMouse;
#endif
            break;
        case PauseCommandCamera: [_cockpit setInteger:!_cockpit.boolValue]; break;
        case PauseCommandRestart:
            _client.inputSuspended = NO;
            [self startMission:_missionIndex];
            break;
        case PauseCommandMissions: [self abortToMenu]; break;
        default: break;
    }
}

- (void)abortToMenu {
    _client.inputSuspended = NO;
    [[GameAudio shared] play:@"ui-back"];
    _state = HostStateMissions;
    [_server stop];
    [_client leaveGame];
    if (self.remote) { [_client disconnect]; [self connectLocal]; }
    [_clientView clearMission];
    [_briefing showListSelecting:_missionIndex];
    [self presentOverlay:_briefing];
}

#pragma mark - Overlays

// Render thread. Show next once the current screen has played its exit; if
// another change arrives meanwhile, the newest one wins.
- (void)presentOverlay:(SKScene *)next {
    if (next == _shownOverlay && _exitDeadline == 0) return;
    if (next == _loading && _shownOverlay && _shownOverlay != next && !_loadingBackdrop) {
        // The outgoing screen fades/scales its own content. Keep the hangar
        // opaque underneath it until the actual loading scene is installed.
        _loadingBackdrop = [_loading backdropWithSize:_shownOverlay.size];
        _loadingBackdrop.zPosition = -1;
        [_shownOverlay addChild:_loadingBackdrop];
    }
    __weak Host *weak = self;
    void (^show)(void) = ^{ [weak showOverlayNow:next]; };
    if (_exitDeadline > 0) { _afterExit = show; return; }
    NSTimeInterval exit = [_shownOverlay conformsToProtocol:@protocol(UIMotionScene)]
        ? [(id<UIMotionScene>)_shownOverlay motionExit] : 0;
    [self afterExit:exit then:show];
}

- (void)afterExit:(NSTimeInterval)seconds then:(void (^)(void))then {
    if (seconds <= 0) { _exitDeadline = 0; _afterExit = nil; then(); return; }
    _afterExit = then;
    _exitDeadline = _time + seconds * UIMotionTimeScale() + 0.02;
}

- (void)showOverlayNow:(SKScene *)next {
    if (next != _clientView.hud) [[GameAudio shared] play:@"ui-panel"];
    _shownOverlay = next;
    SKNode *backdrop = _loadingBackdrop;
    _loadingBackdrop = nil;
    if ([next conformsToProtocol:@protocol(UIMotionScene)]) [(id<UIMotionScene>)next motionEnter];
    SCNView *view = _view;
    dispatch_async(dispatch_get_main_queue(), ^{
        view.overlaySKScene = next;
        [backdrop removeFromParent];
    });
}

- (void)pumpOverlay {
    if (_exitDeadline <= 0 || _time < _exitDeadline) return;
    void (^then)(void) = _afterExit;
    _exitDeadline = 0;
    _afterExit = nil;
    if (then) then();
}

#pragma mark - Loop

#if TARGET_OS_IOS
// SpriteKit overlays participate in UIKit focus on iPad. Run their updates
// on the main thread instead of SceneKit's render queue.
- (void)displayLinkTick:(CADisplayLink *)link {
    [self updateFrameAtTime:link.timestamp];
    if (_booted) [_clientView renderDisplaysWithQueue:_view.commandQueue time:link.timestamp];
}
#else
- (void)renderer:(id<SCNSceneRenderer>)renderer willRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time {
    if (!_booted) return;   // the cockpit may still be under construction on the load queue
    [_clientView renderDisplaysWithQueue:renderer.commandQueue time:time];
}

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    [self updateFrameAtTime:time];
}
#endif

- (void)updateFrameAtTime:(NSTimeInterval)time {
    float dt = _lastTime > 0 ? (float)(time - _lastTime) : 1.0f / 60.0f;
    _lastTime = time;
    dt = clampf(dt, 0.0005f, 1.0f / 20.0f);
    _time += dt;
    [[GameAudio shared] frame:dt flying:_state == HostStateFlying];
    [self pumpOverlay];
    [Cmd executeBuffer];

    InputAction actions = [_input consumeActions];
    if (_exitDeadline > 0 && _state != HostStateFlying) actions = 0;   // a screen is on its way out
    ControlState controls = [_input poll:dt];
    if (_testInput.boolValue) {   // a pilot who weaves and fires, for testing prediction
        float t = (float)_time;
        controls.pitch = sinf(t * 0.7f) * 0.8f;
        controls.yaw = sinf(t * 0.4f + 1) * 0.5f;
        controls.roll = sinf(t * 1.1f) * 0.6f;
        controls.throttle = 0.6f + 0.4f * sinf(t * 0.3f);
        controls.boost = fmodf(t, 9) > 7;
        controls.fire = fmodf(t, 3) > 1.5f;
    }
    [_client readPackets];
    if (_state != HostStateFlying) {
        // Keep both ends of the connection alive while nothing is flown.
        [_client sendInput:(ControlState){ .hat = -1 } actions:0 dt:dt];
        [_server frame:dt paused:_booted && (_state == HostStateLoading || _state == HostStatePaused) && !self.remote];
    }
    if (_state == HostStatePaused) { [self updatePause:actions]; return; }
    if (_state == HostStateLoading) { [self updateLoading:actions]; return; }
    if (_revealing) {
        [self updateReveal];
        if (_state != HostStateFlying) return;
    }
    if (actions & InputActionToggleCamera) { [_cockpit setInteger:!_cockpit.boolValue]; [[GameAudio shared] play:@"ui-confirm"]; }
    if (actions & InputActionToggleHelp) { [_clientView.hud toggleHelp]; [[GameAudio shared] play:@"ui-panel"]; }

    if (_state == HostStateBrowser) {
        [self updateBrowser:actions];
        return;
    }
    if (_state != HostStateFlying) {
        if (actions & InputActionMultiplayer) { [self showBrowser]; return; }
        if (_state == HostStateMainMenu) [self updateMainMenu:actions];
        else [self updateBriefing:actions];
        return;
    }
    if ((actions & InputActionRestart) && !self.remote) { [self startMission:_missionIndex]; return; }
    if (actions & InputActionBack) { [self pauseFlight]; return; }

    [_client sendInput:controls actions:actions dt:dt];
    [_server frame:dt];
    [_client readPackets];                   // this frame's snapshot, over loopback
    if (_state != HostStateFlying) return;   // the mission ended during that frame
    [_client drawWithControls:controls time:_time dt:dt];
}

#pragma mark - Front end

- (NSUInteger)campaignEntry {
    return ProgressCampaignCompleted() ? 0 : ProgressUnlockedCount() - 1;
}

- (void)prepareMainMenu {
    NSUInteger index = [self campaignEntry];
    [_mainMenu showMission:index title:CampaignMission(index)[@"title"]
                   started:ProgressHasStarted() || index > 0 completed:ProgressCampaignCompleted()];
}

- (void)showMainMenu {
    _state = HostStateMainMenu;
    [self prepareMainMenu];
    [self presentOverlay:_mainMenu];
}

- (void)updateMainMenu:(InputAction)actions {
    switch ([_mainMenu handle:actions]) {
        case MainMenuCommandCampaign:
            [_briefing showBriefing:[self campaignEntry]];
            break;
        case MainMenuCommandMissions:
            [_briefing showListSelecting:ProgressUnlockedCount() - 1];
            break;
        case MainMenuCommandMultiplayer:
            [self showBrowser];
            return;
        case MainMenuCommandQuit:
#if TARGET_OS_OSX
            [self afterExit:[_mainMenu motionPowerDown] then:^{
                dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
            }];
#endif
            return;
        case MainMenuCommandNone:
            return;
    }
    _state = HostStateMissions;
    [self presentOverlay:_briefing];
}

- (void)updateBriefing:(InputAction)actions {
    [_briefing tick:_time];
    switch ([_briefing handle:actions]) {
        case BriefingCommandLaunch: [self startMission:_briefing.selectedIndex]; return;
        case BriefingCommandMainMenu: [self showMainMenu]; return;
        case BriefingCommandNone: break;
    }
    [_clientView menuFrame:_time];   // slow drift through the sky behind the menus
}

@end
