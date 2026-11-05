#import "Host.h"
#import "GameView.h"
#import "Server.h"
#import "Client.h"
#import "ClientView.h"
#import "SceneKitRefresh.h"
#import "FrontEnd.h"
#import "PauseMenu.h"
#import "Loading.h"
#import "Localization.h"
#import "NetTransport.h"
#import "UDPTransport.h"
#import "LANBrowser.h"
#import "NetProtocol.h"
#import "UIMotion.h"
#import "ScreenHost.h"
#import "GameAudio.h"
#import "Cvar.h"
#import "Cmd.h"
#include "SharedMath.h"
#import <stdatomic.h>
#if TARGET_OS_OSX
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#endif
#if TARGET_OS_IOS
#include <ifaddrs.h>
#include <netdb.h>
#endif

static NSString *PilotName(void) {
#if TARGET_OS_IOS
    return L10n(@"net.default_pilot");
#else
    return NSFullUserName() ?: L10n(@"net.default_pilot");
#endif
}

// The engine's states. Which menu screen shows is the front end's business.
typedef NS_ENUM(NSInteger, HostState) {
    HostStateLoading,   // the loading card: boot, or a level being built and precached
    HostStateMenus,     // the front end has the screen
    HostStateFlying,
    HostStatePaused,    // a level held (or, online, still running) under the pause menu
};

// What the loading screen says while the background queue is on each step.
typedef NS_ENUM(int, LoadStage) {
    LoadStageStart, LoadStageSky, LoadStageCockpit, LoadStageFleet,
    LoadStageWings, LoadStageUpload, LoadStageShaders, LoadStageReady,
};
static NSString *LoadStatus(LoadStage s) {
    switch (s) {
        case LoadStageStart: return L10n(@"loading.loading_mission");
        case LoadStageSky: return L10n(@"loading.charting_starfield");
        case LoadStageCockpit: return L10n(@"loading.preparing_ship");
        case LoadStageFleet: return L10n(@"loading.plotting_capital_ships");
        case LoadStageWings: return L10n(@"loading.scrambling_fighter_wings");
        case LoadStageUpload: return L10n(@"loading.uploading_assets");
        case LoadStageShaders: return L10n(@"loading.compiling_shaders");
        case LoadStageReady: return L10n(@"loading.mission_ready");
    }
    return L10n(@"loading.loading_mission");
}

static const double kMinMissionLoadSeconds = 1.2;   // long enough to read the title card

@interface Host () <UIServices>
@end

@implementation Host {
    __weak SCNView *_view;
    Input *_input;
    Server *_server;
    Client *_client;
    SceneKitRefresh *_refresh;
    ClientView *_clientView;
    FrontEnd *_frontEnd;
    PauseMenu *_pauseMenu;
    BOOL _resumeMouse;
    Loading *_loading;

    HostState _state;
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

    // Overlay changes wait for the outgoing screen's exit animation.
    ScreenHost *_screens;

    Cvar *_testInput, *_cockpit, *_autoStart;

#if TARGET_OS_OSX
    NSMutableArray<NSString *> *_screenshotPaths;   // render thread: waiting for a readable frame
    dispatch_group_t _screenshotsInFlight;          // requested and not yet written; quit waits
#endif
}

- (instancetype)initWithView:(SCNView *)view input:(Input *)input {
    if ((self = [super init])) {
        _view = view;
        [GameAudio shared];
        _input = input;
        [self registerConsole];
        _loadQueue = dispatch_queue_create("SpaceFight.loading", DISPATCH_QUEUE_SERIAL);
        _frontEnd = [[FrontEnd alloc] initWithSize:view.bounds.size services:self];
        _pauseMenu = [[PauseMenu alloc] initWithSize:view.bounds.size];
        _loading = [[Loading alloc] initWithSize:view.bounds.size];
        [_loading showTitle:L10n(@"game.title") kicker:L10n(@"game.kicker") detail:L10n(@"game.unit")];
        _refresh = [[SceneKitRefresh alloc] initWithRenderer:view size:view.bounds.size];
        _clientView = [[ClientView alloc] initWithRefresh:_refresh input:input];
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
        _server = [[Server alloc] initWithName:L10nFormat(@"net.server_name", PilotName())];
        [_server addTransport:[LoopbackTransport side:1]];
        int port = [Cvar get:@"net_port" defaultValue:[NSString stringWithFormat:@"%d", PORT_SERVER] flags:CVAR_NOSET
                        help:@"UDP port the local server listens on; 0 turns hosting off"].integer;
        if (port > 0) {
            _serverUDP = [[UDPTransport alloc] initWithPort:port attempts:4];
            if (_serverUDP) [_server addTransport:_serverUDP];
        }
        [_frontEnd setHostLine:_serverUDP ? L10nFormat(@"browser.hosting_on", _serverUDP.port) : L10n(@"browser.hosting_off")];
        [self connectLocal];

        // Show the loading card over an empty scene right away; the real scene
        // is built off the main thread and swapped in when it is ready.
        _state = HostStateLoading;
        SCNScene *placeholder = [SCNScene scene];
        placeholder.background.contents = [SKColor blackColor];
        view.scene = placeholder;
        view.overlaySKScene = _loading;
        __weak SCNView *weakSCNView = view;
        __weak Host *weakHost = self;
        _screens = [[ScreenHost alloc] initWithScreen:_loading install:^(SKScene *screen, SKNode *cover) {
            Host *host = weakHost;
            if (host && screen != host->_clientView.hud) [[GameAudio shared] play:@"ui-panel"];
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSCNView.overlaySKScene = screen;
                [cover removeFromParent];
            });
        }];
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
        Host *host = weak;
        NSUInteger count = host->_frontEnd.levelCount;
        int n = a.count > 1 ? a[1].intValue : 0;
        if (n < 1 || (NSUInteger)n > count) { NSLog(@"usage: map <1..%lu>", (unsigned long)count); return; }
        [weak startLevel:(NSUInteger)n - 1];
    }];
    [Cmd add:@"briefing" help:@"briefing <mission number> [page]: opens that briefing" handler:^(NSArray<NSString *> *a) {
        Host *host = weak;
        NSUInteger count = host->_frontEnd.levelCount;
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
#if TARGET_OS_OSX
        // Screenshots finish over the next frames; let them land first.
        Host *host = weak;
        dispatch_group_t screenshots = host ? host->_screenshotsInFlight : nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (screenshots && dispatch_group_wait(screenshots, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)))
                NSLog(@"quit: gave up waiting for screenshots");
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        });
#else
        dispatch_async(dispatch_get_main_queue(), ^{
            exit(0);
        });
#endif
    }];
}

- (BOOL)inLevel { return _state == HostStateFlying || _state == HostStatePaused; }

- (void)showBriefing:(NSUInteger)index page:(NSUInteger)page {
    if (!_booted || _state == HostStateLoading) { NSLog(@"briefing: not in the menus"); return; }
    if ([self inLevel]) [self abortToMenu];
    _state = HostStateMenus;
    [_frontEnd showBriefing:index page:page];
}

- (void)connectToAddress:(NetAddress *)address {
    if (!_booted) { NSLog(@"connect: not booted yet"); return; }
    if ([self inLevel]) [self abortToMenu];
    _state = HostStateMenus;
    [_frontEnd showBrowser];
    [self joinServer:address];
}

- (void)disconnectCommand {
    if ([self inLevel]) { [self abortToMenu]; return; }
    if (self.remote) { [_client disconnect]; [self connectLocal]; }
    if (_booted && _state != HostStateLoading) [_frontEnd showMainMenu];
}

#if TARGET_OS_OSX
// -[SCNView snapshot] draws the scene and the overlay SKScene a second time,
// through a temporary SCNRenderer. That second SpriteKit draw of the live
// overlay can leave the view's own overlay renderer waiting forever for a
// buffer (jet_buffer_pool::next_buffer) with the scene lock held, which
// stalls the main thread and the load queue behind it: the app hangs. So
// nothing is drawn twice here. The layer remembers the drawable SceneKit
// takes for each frame, and the next frame copies it (overlay included) on
// the view's own command queue, after the frame that filled it. SceneKit
// calls updateAtTime: before it takes the frame's drawable, so at that
// point the remembered one is the previous, finished frame.

static const void *kLastDrawableKey = &kLastDrawableKey;   // on the layer: the drawable, while armed
static const void *kArmedKey = &kArmedKey;                 // on the layer: a screenshot is waiting

static id<CAMetalDrawable> TrackedNextDrawable(CAMetalLayer *self, SEL _cmd) {
    Class base = class_getSuperclass(object_getClass(self));
    id<CAMetalDrawable> (*next)(id, SEL) = (void *)class_getMethodImplementation(base, _cmd);
    id<CAMetalDrawable> drawable = next(self, _cmd);
    if (objc_getAssociatedObject(self, kArmedKey)) objc_setAssociatedObject(self, kLastDrawableKey, drawable, OBJC_ASSOCIATION_RETAIN);
    return drawable;
}

// The layer's own class (SceneKit's) gains a subclass that also records the
// drawable each nextDrawable hands out, the way KVO subclasses an object.
static BOOL TrackDrawables(CAMetalLayer *layer) {
    Class base = object_getClass(layer);
    if (class_getInstanceMethod(base, @selector(nextDrawable)) && objc_getAssociatedObject(base, kLastDrawableKey)) return YES;
    NSString *name = [@"SFScreenshot_" stringByAppendingString:NSStringFromClass(base)];
    Class tracking = NSClassFromString(name);
    if (!tracking) {
        tracking = objc_allocateClassPair(base, name.UTF8String, 0);
        if (!tracking) return NO;
        Method m = class_getInstanceMethod(base, @selector(nextDrawable));
        class_addMethod(tracking, @selector(nextDrawable), (IMP)TrackedNextDrawable, method_getTypeEncoding(m));
        objc_setAssociatedObject(tracking, kLastDrawableKey, @YES, OBJC_ASSOCIATION_RETAIN);
        objc_registerClassPair(tracking);
    }
    object_setClass(layer, tracking);
    return YES;
}

// On the frame thread (the render thread). The file is written a frame or
// two later; quit waits for it.
- (void)saveScreenshot:(NSString *)path {
    if (!_screenshotPaths) _screenshotPaths = [NSMutableArray array];
    if (!_screenshotsInFlight) _screenshotsInFlight = dispatch_group_create();
    [_screenshotPaths addObject:path];
    dispatch_group_enter(_screenshotsInFlight);
    CAMetalLayer *layer = [_view.layer isKindOfClass:CAMetalLayer.class] ? (CAMetalLayer *)_view.layer : nil;
    if (!layer || !TrackDrawables(layer)) {
        NSLog(@"screenshot: no Metal layer to read");
        [self finishScreenshots:_screenshotPaths png:nil];
        [_screenshotPaths removeAllObjects];
        return;
    }
    objc_setAssociatedObject(layer, kArmedKey, @YES, OBJC_ASSOCIATION_RETAIN);
    // Drawables are framebuffer-only by default; a copy needs to read one.
    dispatch_async(dispatch_get_main_queue(), ^{ layer.framebufferOnly = NO; });
}

- (void)finishScreenshots:(NSArray<NSString *> *)paths png:(NSData *)png {
    for (NSString *path in paths) {
        if (!png || ![png writeToFile:path.stringByExpandingTildeInPath atomically:YES]) NSLog(@"screenshot: cannot write %@", path);
        else NSLog(@"screenshot: wrote %@", path);
        dispatch_group_leave(_screenshotsInFlight);
    }
}

static NSData *PNGFromTexture(id<MTLTexture> t, CGColorSpaceRef space) {
    size_t w = t.width, h = t.height, bytes, bits;
    CGBitmapInfo info;
    switch (t.pixelFormat) {
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB:
            bytes = 4, bits = 8, info = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst; break;
        case MTLPixelFormatRGBA8Unorm:
        case MTLPixelFormatRGBA8Unorm_sRGB:
            bytes = 4, bits = 8, info = kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaNoneSkipLast; break;
        case MTLPixelFormatRGBA16Float:
            bytes = 8, bits = 16, info = kCGBitmapByteOrder16Little | kCGBitmapFloatComponents | (CGBitmapInfo)kCGImageAlphaNoneSkipLast; break;
        default:
            NSLog(@"screenshot: unsupported pixel format %lu", (unsigned long)t.pixelFormat);
            return nil;
    }
    NSMutableData *pixels = [NSMutableData dataWithLength:w * h * bytes];
    [t getBytes:pixels.mutableBytes bytesPerRow:w * bytes fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef image = CGImageCreate(w, h, bits, bytes * 8, w * bytes, space, info, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!image) return nil;
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(image);
    return ok ? png : nil;
}

// Start of a frame, on the render thread: copy the drawable the last frame
// presented, once one that can be read has come round.
- (void)captureScreenshots:(id<SCNSceneRenderer>)renderer {
    if (!_screenshotPaths.count) return;
    CAMetalLayer *layer = (CAMetalLayer *)_view.layer;
    id<CAMetalDrawable> drawable = objc_getAssociatedObject(layer, kLastDrawableKey);
    id<MTLTexture> source = drawable.texture;
    if (!source || source.framebufferOnly) return;
    NSArray<NSString *> *paths = [_screenshotPaths copy];
    [_screenshotPaths removeAllObjects];
    objc_setAssociatedObject(layer, kArmedKey, nil, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(layer, kLastDrawableKey, nil, OBJC_ASSOCIATION_RETAIN);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
                                                                                width:source.width height:source.height mipmapped:NO];
    d.storageMode = source.device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
    id<MTLTexture> copy = [source.device newTextureWithDescriptor:d];
    id<MTLCommandBuffer> commands = [renderer.commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit copyFromTexture:source toTexture:copy];
    if (d.storageMode == MTLStorageModeManaged) [blit synchronizeResource:copy];
    [blit endEncoding];
    CGColorSpaceRef space = layer.colorspace ? CGColorSpaceRetain(layer.colorspace) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    __weak Host *weak = self;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> done) {
        NSData *png = done.status == MTLCommandBufferStatusCompleted ? PNGFromTexture(copy, space) : nil;
        CGColorSpaceRelease(space);
        [weak finishScreenshots:paths png:png];
    }];
    [commands commit];
}
#else
- (void)saveScreenshot:(NSString *)path {
    SCNView *view = _view;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData *png = UIImagePNGRepresentation([view snapshot]);
        if (!png || ![png writeToFile:path.stringByExpandingTildeInPath atomically:YES]) NSLog(@"screenshot: cannot write %@", path);
        else NSLog(@"screenshot: wrote %@", path);
    });
}
#endif

- (void)connectLocal {
    [_client connectTo:[NetAddress loopback:1] transport:[LoopbackTransport side:0] name:PilotName()];
}

- (BOOL)remote { return _client.serverAddress && !_client.serverAddress.isLoopback; }

#pragma mark - UIServices

// Leave our own server idle and connect to someone else's. The gamestate it
// sends (now, or when it starts a mission) takes us through loading.
- (void)joinServer:(NetAddress *)address {
    if (!address) return;
    [_server stop];
    [_clientView clearMission];
    if (!_clientUDP) _clientUDP = [[UDPTransport alloc] initWithPort:0 attempts:1];
    NSLog(@"Host: joining %@", address);
    [_client connectTo:address transport:_clientUDP name:PilotName()];
    [_frontEnd setBrowserStatus:L10nFormat(@"browser.connecting", address)];
}

- (void)cancelJoin {
    if (self.remote && _client.state != ClientActive) { [_client disconnect]; [self connectLocal]; }
}

- (double)time { return _time; }
- (NSString *)connectedServer { return self.remote ? _client.serverAddress.string : nil; }
- (void)drawMenuBackdrop { [_clientView menuFrame:_time]; }

- (BOOL)isOwnServer:(LANServer *)s {
    return _serverUDP && s.address.port == _serverUDP.port && [self isOwnAddress:s.address];
}

// Every screen change goes through here. While the loading card fades out,
// the reveal shows whatever the front end has current; straight after boot,
// the card is still up and a menu request starts that fade.
- (void)present:(SKScene *)screen {
    if (_revealing) return;
    if (_screens.shown == _loading && _booted && _state == HostStateMenus) { [self reveal:0.5]; return; }
    [self presentOverlay:screen];
}

- (void)quitAfter:(NSTimeInterval)seconds {
#if TARGET_OS_OSX
    [_screens after:seconds then:^{
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    } time:_time];
#endif
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

// Upload what the renderer built to the GPU (buffers, textures, shader
// variants) object by object, so the bar moves and the first rendered frame
// doesn't stall.
- (NSUInteger)uploadFrom:(float)p0 to:(float)p1 {
    return [_refresh upload:^(float f) { atomic_store(&self->_loadProgress, p0 + (p1 - p0) * f); }];
}

// Load queue: the whole scene, which nobody is rendering yet.
- (void)bootInBackground {
    CFTimeInterval t0 = CACurrentMediaTime();
    [self reportStage:LoadStageSky progress:0.05f];
    [_refresh buildWorld];
    [self reportStage:LoadStageShaders progress:0.7f];
    [self uploadFrom:0.7f to:1.0f];
    [self reportStage:LoadStageReady progress:1];
    NSLog(@"Boot loaded in %.2f s", CACurrentMediaTime() - t0);
    atomic_store(&_loadDone, true);
}

// Render thread, once the boot load is done and the bar is full.
- (void)finishBoot {
    _booted = YES;
    SCNView *view = _view;
    SCNScene *scene = _refresh.scene;
    SCNNode *camera = _refresh.cameraNode;
    dispatch_async(dispatch_get_main_queue(), ^{
        view.scene = scene;
        view.pointOfView = camera;
    });
    _state = HostStateMenus;
    [_frontEnd prepareAfterBoot];
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
    SKScene *next = _state == HostStateFlying ? _clientView.hud : _frontEnd.currentScreen;
    if (_state == HostStateFlying) [_clientView.hud showBanner:[_frontEnd bannerForLevel:_missionIndex] color:nil];
    [self presentOverlay:next];
}

#pragma mark - Missions

// Render thread: put up the loading card and build the mission off-thread.
- (void)startLevel:(NSUInteger)index {
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
    [_frontEnd fillLoadingCard:_loading level:index];
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
    [_clientView loadMissionAssets:^(float f) { atomic_store(&self->_loadProgress, 0.2f + 0.4f * f); }];
    [self reportStage:LoadStageUpload progress:0.6f];
    NSUInteger uploaded = [self uploadFrom:0.6f to:1.0f];
    [self reportStage:LoadStageReady progress:1];
    NSLog(@"Client: mission %lu precached in %.2f s (%lu objects uploaded)", (unsigned long)_missionIndex + 1,
          CACurrentMediaTime() - t0, (unsigned long)uploaded);
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
    [_frontEnd levelStarted:_missionIndex remote:self.remote];
    _state = HostStateFlying;
    [self reveal:0.6];
}

- (void)disconnected:(NSString *)reason {
    _client.inputSuspended = NO;
    _loading.readyToStart = NO;
    _precaching = NO;
    [_frontEnd setBrowserStatus:reason];
    if ([self inLevel] || (_state == HostStateLoading && _booted)) {
        _state = HostStateMenus;
        _revealing = NO;
        [_clientView clearMission];
        [_frontEnd levelLeft:_missionIndex];
    }
    [self connectLocal];   // back to our own server
}

- (void)missionEnded:(BOOL)success results:(NSArray<NSString *> *)results {
    if (_state != HostStateFlying && _state != HostStatePaused) return;
    _client.inputSuspended = NO;
    [[GameAudio shared] play:success ? @"ui-success" : @"ui-alert"];
    _state = HostStateMenus;
    if (!self.remote) [_server stop];   // a remote host decides what comes next
    [_client leaveGame];
    [_frontEnd levelEnded:_missionIndex success:success results:results remote:self.remote];
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
            [self startLevel:_missionIndex];
            break;
        case PauseCommandMissions: [self abortToMenu]; break;
        default: break;
    }
}

- (void)abortToMenu {
    _client.inputSuspended = NO;
    [[GameAudio shared] play:@"ui-back"];
    _state = HostStateMenus;
    [_server stop];
    [_client leaveGame];
    if (self.remote) { [_client disconnect]; [self connectLocal]; }
    [_clientView clearMission];
    [_frontEnd levelLeft:_missionIndex];
}

#pragma mark - Overlays

// Render thread. Show next once the current screen has played its exit; if
// another change arrives meanwhile, the newest one wins.
// Render thread. The loading card keeps the outgoing screen opaque with its
// own art while that screen animates away.
- (void)presentOverlay:(SKScene *)next {
    SKNode *cover = next == _loading ? [_loading backdropWithSize:_screens.shown.size] : nil;
    [_screens present:next cover:cover time:_time];
}

#pragma mark - Loop

#if TARGET_OS_IOS
// SpriteKit overlays participate in UIKit focus on iPad. Run their updates
// on the main thread instead of SceneKit's render queue.
- (void)displayLinkTick:(CADisplayLink *)link {
    [self updateFrameAtTime:link.timestamp];
    if (_booted) [_refresh renderDisplaysWithQueue:_view.commandQueue time:link.timestamp];
}
#else
- (void)renderer:(id<SCNSceneRenderer>)renderer willRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time {
    if (!_booted) return;   // the cockpit may still be under construction on the load queue
    [_refresh renderDisplaysWithQueue:renderer.commandQueue time:time];
}

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    [self captureScreenshots:renderer];
    [self updateFrameAtTime:time];
}
#endif

- (void)updateFrameAtTime:(NSTimeInterval)time {
    float dt = _lastTime > 0 ? (float)(time - _lastTime) : 1.0f / 60.0f;
    _lastTime = time;
    dt = clampf(dt, 0.0005f, 1.0f / 20.0f);
    _time += dt;
    [[GameAudio shared] frame:dt flying:_state == HostStateFlying];
    [_screens pump:_time];
    [Cmd executeBuffer];

    InputAction actions = [_input consumeActions];
    NSData *pointer = [_input.pointer drain];
    if (_screens.changing && _state != HostStateFlying) actions = 0, pointer = nil;   // a screen is on its way out
    // Pointer events go to the screen on show, before it handles this frame's actions.
    const PointerEvent *events = pointer.bytes;
    for (NSUInteger i = 0; i < pointer.length / sizeof(PointerEvent); i++) ScreenInputDeliver(_screens.shown, events[i]);
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

    if (_state == HostStateMenus) {
        if (actions & InputActionMultiplayer) [_frontEnd showBrowser];
        else [_frontEnd frame:actions];
        return;
    }
    if ((actions & InputActionRestart) && !self.remote) { [self startLevel:_missionIndex]; return; }
    if (actions & InputActionBack) { [self pauseFlight]; return; }

    [_client sendInput:controls actions:actions dt:dt];
    [_server frame:dt];
    [_client readPackets];                   // this frame's snapshot, over loopback
    if (_state != HostStateFlying) return;   // the mission ended during that frame
    [_client drawWithControls:controls time:_time dt:dt];
}

@end
