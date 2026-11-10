#import <TargetConditionals.h>
#if !TARGET_OS_IOS
#import "Render.h"
#import "Shared.h"
#import "Common.h"
#import <Cocoa/Cocoa.h>
#import <SceneKit/SceneKit.h>

// A window with one ship in the studio scene, for checking a definition's
// attachment points against its mesh: the exhaust runs through idle, full
// throttle and boost, the guns fire in turn and the camera circles.
//
//   KestrelFrontier --preview-ship <ship> [game]
//   M shows the points (green guns, orange nozzles, white cockpit eye),
//   Space holds the camera, Q quits.

#define PREVIEW_BOLTS 32
static const double kThrottleCycle = 12;      // seconds through idle, climb, full, boost, idle
static const float kBoltSlowdown = 0.12f;     // a fraction of the gun's speed, so a shot can be followed

typedef struct {
    double born, life;
    simd_float3 origin, velocity;
    BOOL live;
} PreviewBolt;

static RefCamera LookAt(simd_float3 eye, simd_float3 target) {
    simd_float3 back = simd_normalize(eye - target);
    simd_float3 right = simd_normalize(simd_cross(simd_make_float3(0, 1, 0), back));
    simd_float3 up = simd_cross(back, right);
    return (RefCamera){ .origin = eye, .orientation = simd_quaternion(simd_matrix(right, up, back)), .focus = target };
}

static SCNNode *PointMarker(simd_float3 at, NSColor *color, CGFloat radius) {
    SCNSphere *sphere = [SCNSphere sphereWithRadius:radius];
    sphere.firstMaterial.lightingModelName = SCNLightingModelConstant;
    sphere.firstMaterial.diffuse.contents = color;
    sphere.firstMaterial.readsFromDepthBuffer = NO;
    SCNNode *n = [SCNNode nodeWithGeometry:sphere];
    n.simdPosition = at;
    n.renderingOrder = 200;
    return n;
}

@interface PreviewView : SCNView
@property (nonatomic, copy) void (^onKey)(unichar key);
@end

@implementation PreviewView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (_onKey && event.characters.length) _onKey([event.characters characterAtIndex:0]);
}
@end

@interface ShipPreview () <NSApplicationDelegate, SCNSceneRendererDelegate>
@end

@implementation ShipPreview {
    NSString *_ship;
    const ShipDef *_def;
    NSWindow *_window;
    PreviewView *_view;
    SceneKitRefresh *_refresh;
    RefModel _model;
    SCNNode *_markers;
    double _start, _last, _lastShot, _angle;
    int _gun;
    PreviewBolt _bolts[PREVIEW_BOLTS];
    BOOL _holding;
}

+ (int)runWithShip:(NSString *)ship game:(NSString *)game {
    if (game.length) FSSetGame(game);
    const ShipDef *def = ShipDefNamed(ship);
    if (!def) {
        fprintf(stderr, "No ship '%s' in %s; ships: %s\n", ship.UTF8String, FSGame().UTF8String,
                [ShipDefNames() componentsJoinedByString:@", "].UTF8String);
        return 2;
    }
    ShipPreview *preview = [ShipPreview new];
    preview->_ship = [ship copy];
    preview->_def = def;
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    app.delegate = preview;
    [app run];
    return 0;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSRect frame = NSMakeRect(0, 0, 1280, 720);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered defer:NO];
    _window.title = [NSString stringWithFormat:@"%@ (%s, %@)  M points, Space hold, Q quit",
                     L10nExpand(@(_def->displayName)), _def->mesh, FSGame()];
    [_window center];
    _view = [[PreviewView alloc] initWithFrame:frame options:@{ SCNPreferredRenderingAPIKey : @(SCNRenderingAPIMetal) }];
    _view.antialiasingMode = SCNAntialiasingModeNone;
    _view.backgroundColor = NSColor.blackColor;
    _window.contentView = _view;

    _refresh = [[SceneKitRefresh alloc] initWithRenderer:_view size:frame.size];
    [_refresh buildStudio];
    _view.scene = _refresh.scene;
    _view.pointOfView = _refresh.cameraNode;
    _model = [_refresh registerModel:[@"ship:" stringByAppendingString:_ship]];
    [_refresh upload:nil];
    [_refresh endRegistration];
    [self buildMarkers];

    __weak ShipPreview *weak = self;
    _view.onKey = ^(unichar key) {
        ShipPreview *self = weak;
        if (!self) return;
        if (key == 'm' || key == 'M') self->_markers.hidden = !self->_markers.hidden;
        else if (key == ' ') self->_holding = !self->_holding;
        else if (key == 'q' || key == 'Q' || key == 27) [NSApp terminate:nil];
    };
    _view.delegate = self;
    _view.playing = YES;
    _view.loops = YES;
    _view.rendersContinuously = YES;
    _angle = 0.6;
    [_window makeFirstResponder:_view];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// The definition's points in ship space, over the hull.
- (void)buildMarkers {
    _markers = [SCNNode node];
    _markers.hidden = YES;
    for (int i = 0; i < _def->gunCount; i++)
        [_markers addChildNode:PointMarker(_def->guns[i], NSColor.greenColor, 0.14)];
    for (int i = 0; i < _def->nozzleCount; i++)
        [_markers addChildNode:PointMarker(simd_make_float3(_def->nozzles[i]), NSColor.orangeColor, 0.14)];
    [_markers addChildNode:PointMarker(_def->cockpitEye, NSColor.whiteColor, 0.12)];
    [_refresh.scene.rootNode addChildNode:_markers];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (void)renderer:(id<SCNSceneRenderer>)renderer updateAtTime:(NSTimeInterval)time {
    if (!_start) _start = _last = time;
    double t = time - _start;
    float dt = (float)MIN(0.1, time - _last);
    _last = time;
    [_refresh beginFrame:time];

    // Idle, a climb to full throttle, a burst of boost, back to idle.
    double u = fmod(t, kThrottleCycle) / kThrottleCycle;
    float throttle = u < 0.15 ? 0 : u < 0.55 ? (float)((u - 0.15) / 0.4) : u < 0.85 ? 1 : 0.1f;
    RefEntity ship = { .key = 1, .kind = EntityFighter, .model = _model, .orientation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0)),
                       .throttle = throttle, .boost = u >= 0.7 && u < 0.85, .hull = 1 };
    [_refresh addEntity:&ship];

    // Each gun in turn, at the definition's cadence, the shot slowed so the eye can follow it.
    if (_def->gunCount && t - _lastShot >= MAX(0.1f, _def->gun.interval)) {
        _lastShot = t;
        simd_float3 gun = _def->guns[_gun++ % _def->gunCount];
        for (int i = 0; i < PREVIEW_BOLTS; i++) {
            if (_bolts[i].live) continue;
            _bolts[i] = (PreviewBolt){ .born = t, .life = _def->gun.life, .origin = gun,
                                       .velocity = simd_make_float3(0, 0, -_def->gun.speed * kBoltSlowdown), .live = YES };
            [_refresh showBolt:i at:gun velocity:_bolts[i].velocity friendly:YES ion:NO];
            [_refresh muzzleFlashOn:1 local:gun friendly:YES];
            break;
        }
    }
    for (int i = 0; i < PREVIEW_BOLTS; i++) {
        if (!_bolts[i].live) continue;
        double age = t - _bolts[i].born;
        if (age > _bolts[i].life) { _bolts[i].live = NO; [_refresh hideBolt:i]; continue; }
        [_refresh moveBolt:i to:_bolts[i].origin + _bolts[i].velocity * (float)age];
    }

    if (!_holding) _angle += dt * 0.25;
    float radius = MAX(10, _def->radius * 4.5f);
    simd_float3 eye = simd_make_float3(sinf((float)_angle) * radius, radius * 0.3f, cosf((float)_angle) * radius);
    [_refresh setCamera:LookAt(eye, simd_make_float3(0, 0, -_def->radius * 0.3f))];
    [_refresh endFrame];
}

@end
#endif
