#import <TargetConditionals.h>
#if !TARGET_OS_IOS
#import "Render.h"
#import "Common.h"
#include <unistd.h>

static const int CaptureTickRate = 60;
static const int CaptureVideoRate = 30;

@interface CaptureObject : NSObject
@property (nonatomic, copy) NSString *model, *label;
@property (nonatomic) RefEntity entity;
@property (nonatomic) simd_float3 velocity;
@property (nonatomic) simd_float3 angularVelocity;
@property (nonatomic) double until;
@end
@implementation CaptureObject
@end

@interface CaptureMissile : NSObject
@property (nonatomic) simd_float3 launch, bend, approach, target;
@property (nonatomic) double start, duration;
@property (nonatomic) BOOL fromPlayer;
@end
@implementation CaptureMissile
@end

// A laser bolt in world space: it leaves `from` at `start` and flies for `life` seconds.
@interface CaptureBolt : NSObject
@property (nonatomic) simd_float3 origin, velocity;
@property (nonatomic) double start, life;
@property (nonatomic) BOOL friendly;
@end
@implementation CaptureBolt
@end

@interface CaptureExplosion : NSObject
@property (nonatomic, copy) NSString *model;
@property (nonatomic) simd_float3 origin, velocity;
@property (nonatomic) double time;
@property (nonatomic) float scale;
@property (nonatomic) RefModel handle;
@end
@implementation CaptureExplosion
@end

@interface CaptureDefinition : NSObject
@property (nonatomic) uint32_t seed;
@property (nonatomic) double time;
@property (nonatomic) BOOL followPlayer, cockpit, showHUD;
@property (nonatomic) RefCamera camera;
@property (nonatomic) simd_float3 cameraVelocity, aimVelocity;
@property (nonatomic) float roll, rollRate;
@property (nonatomic, copy) NSArray<CaptureObject *> *objects;
@property (nonatomic, copy) NSArray<CaptureMissile *> *missiles;
@property (nonatomic, copy) NSArray<CaptureExplosion *> *explosions;
@property (nonatomic, copy) NSArray<CaptureBolt *> *bolts;
@property (nonatomic, copy) NSString *objective;
@end

static simd_quatf CaptureFacing(simd_float3 forward, float bank) {
    if (simd_length_squared(forward) < 0.001f) forward = simd_make_float3(0, 0, -1);
    simd_float3 back = -simd_normalize(forward);
    simd_float3 up = fabsf(back.y) > 0.99f ? simd_make_float3(0, 0, 1) : simd_make_float3(0, 1, 0);
    simd_float3 right = simd_normalize(simd_cross(up, back));
    return simd_mul(simd_quaternion(simd_matrix(right, simd_cross(back, right), back)),
                    simd_quaternion(bank, simd_make_float3(0, 0, -1)));
}

static RefEntity CapturePose(CaptureObject *object, double elapsed) {
    RefEntity entity = object.entity;
    entity.origin += object.velocity * (float)elapsed;
    float spin = simd_length(object.angularVelocity);
    if (spin > 0) entity.orientation = simd_mul(entity.orientation,
        simd_quaternion(spin * (float)elapsed, object.angularVelocity / spin));
    return entity;
}

@implementation CaptureDefinition
+ (instancetype)read:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    CaptureDefinition *d = [self new];
    d.seed = (uint32_t)JSONInt(json, @"skySeed", 4);
    d.time = fmaxf(0.1f, fminf(JSONFloat(json, @"time", 1.5f), 10));
    d.followPlayer = JSONBool(json, @"followPlayer", YES);
    d.cockpit = JSONBool(json, @"cockpit", NO);
    d.showHUD = JSONBool(json, @"hud", YES);
    simd_float3 eye = JSONVec3(json, @"eye", simd_make_float3(0, 4, 19));
    simd_float3 aim = JSONVec3(json, @"lookAt", simd_make_float3(8, 3, -60));
    d.camera = (RefCamera){ .origin = eye, .focus = aim, .fov = JSONFloat(json, @"fov", 64), .zNear = 0.1f };
    d.cameraVelocity = JSONVec3(json, @"cameraVelocity", simd_make_float3(0, 0, 0));
    d.aimVelocity = JSONVec3(json, @"aimVelocity", simd_make_float3(0, 0, 0));
    d.roll = JSONFloat(json, @"roll", 0);
    d.rollRate = JSONFloat(json, @"rollRate", 0);
    d.objective = JSONString(json, @"objective") ?: @"";
    NSMutableArray *objects = [NSMutableArray array], *missiles = [NSMutableArray array];
    NSArray *entries = [json[@"objects"] isKindOfClass:NSArray.class] ? json[@"objects"] : @[];
    for (id item in entries) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *model = JSONString(item, @"model");
        if (!model.length) continue;
        CaptureObject *object = [CaptureObject new];
        object.model = model;
        object.label = JSONString(item, @"label") ?: @"";
        object.velocity = JSONVec3(item, @"velocity", simd_make_float3(0, 0, 0));
        object.angularVelocity = JSONVec3(item, @"angularVelocity", simd_make_float3(0, 0, 0));
        object.until = JSONFloat(item, @"until", 10);
        object.entity = (RefEntity){ .key = (uint16_t)(objects.count + 1),
            .kind = [model hasPrefix:@"ship:"] ? EntityFighter : EntityCapital,
            .origin = JSONVec3(item, @"position", simd_make_float3(0, 0, 0)),
            .orientation = CaptureFacing(JSONVec3(item, @"facing", simd_make_float3(0, 0, -1)), JSONFloat(item, @"bank", 0)),
            .scale = JSONFloat(item, @"scale", 1), .hull = JSONFloat(item, @"hull", 1),
            .throttle = JSONFloat(item, @"throttle", 0.7f), .boost = JSONBool(item, @"boost", NO) };
        [objects addObject:object];
    }
    entries = [json[@"missiles"] isKindOfClass:NSArray.class] ? json[@"missiles"] : @[];
    for (id item in entries) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        CaptureMissile *missile = [CaptureMissile new];
        missile.launch = JSONVec3(item, @"launch", simd_make_float3(2, -1, -6));
        missile.bend = JSONVec3(item, @"bend", missile.launch);
        missile.target = JSONVec3(item, @"target", simd_make_float3(50, 20, -100));
        missile.approach = JSONVec3(item, @"approach", missile.target);
        missile.start = JSONFloat(item, @"start", 0.5f);
        missile.duration = fmaxf(0.1f, JSONFloat(item, @"duration", 1.8f));
        missile.fromPlayer = JSONBool(item, @"fromPlayer", NO);
        if (missile.fromPlayer && objects.count) {
            CaptureObject *player = objects.firstObject;
            RefEntity ship = CapturePose(player, missile.start - d.time);
            simd_float3 forward = simd_act(ship.orientation, simd_make_float3(0, 0, -1));
            const ShipDef *definition = [player.model hasPrefix:@"ship:"] ? ShipDefNamed([player.model substringFromIndex:5]) : NULL;
            float speed = definition ? definition->secondary.launchSpeed : 120;
            missile.launch = ship.origin + simd_act(ship.orientation, missile.launch);
            // A cubic's first derivative is 3(P1-P0)/duration: the staged
            // round starts with the same inherited velocity as live launches.
            missile.bend = missile.launch + (player.velocity + forward * speed) * (float)(missile.duration / 3);
        }
        [missiles addObject:missile];
    }
    d.objects = objects;
    d.missiles = missiles;
    NSMutableArray *explosions = [NSMutableArray array];
    entries = [json[@"explosions"] isKindOfClass:NSArray.class] ? json[@"explosions"] : @[];
    for (id item in entries) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        CaptureExplosion *explosion = [CaptureExplosion new];
        explosion.model = JSONString(item, @"model") ?: @"ship:wasp";
        explosion.origin = JSONVec3(item, @"position", simd_make_float3(0, 0, -30));
        explosion.velocity = JSONVec3(item, @"velocity", simd_make_float3(0, 0, 0));
        explosion.time = JSONFloat(item, @"time", 1);
        explosion.scale = fmaxf(0.1f, JSONFloat(item, @"scale", 1));
        [explosions addObject:explosion];
    }
    d.explosions = explosions;
    NSMutableArray *bolts = [NSMutableArray array];
    entries = [json[@"bolts"] isKindOfClass:NSArray.class] ? json[@"bolts"] : @[];
    for (id item in entries) {
        if (![item isKindOfClass:NSDictionary.class] || bolts.count == REF_MAX_BOLTS) continue;
        CaptureBolt *bolt = [CaptureBolt new];
        bolt.origin = JSONVec3(item, @"from", simd_make_float3(0, 0, -30));
        bolt.velocity = JSONVec3(item, @"velocity", simd_make_float3(0, 0, -900));
        bolt.start = JSONFloat(item, @"start", 1);
        bolt.life = fmaxf(0.05f, JSONFloat(item, @"life", 1));
        bolt.friendly = JSONBool(item, @"friendly", NO);
        [bolts addObject:bolt];
    }
    d.bolts = bolts;
    return d;
}
@end

static simd_float3 CaptureMissilePoint(CaptureMissile *m, double time) {
    float t = fminf(fmaxf((time - m.start) / m.duration, 0), 1), u = 1 - t;
    return m.launch * (u * u * u) + m.bend * (3 * u * u * t) + m.approach * (3 * u * t * t) + m.target * (t * t * t);
}

static BOOL CaptureSizeValid(CGSize size) {
    return size.width >= 320 && size.height >= 240 && size.width <= 4096 && size.height <= 4096;
}

// Warm the scene at its normal tick rate. Supply a sink to stream every other
// tick at export size, or omit it to take a single still at the authored time.
static NSImage *CaptureRender(CaptureDefinition *d, CGSize size, int firstFrame, int count,
                              BOOL (^sink)(NSImage *image)) {
    [NSApplication sharedApplication];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return nil;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    CaptureObject *pilot = d.objects.firstObject;
    const ShipDef *pilotDef = [pilot.model hasPrefix:@"ship:"] ? ShipDefNamed([pilot.model substringFromIndex:5]) : NULL;
    simd_float3 eye = pilotDef ? pilotDef->cockpitEye : RefCockpitEye;
    BOOL flightView = sink != nil;
    FlightCameraState rig = { .fov = 70 };
    PlayerState flight = { .alive = YES };
    if (pilotDef) flight.params = pilotDef->params;
    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    CGFloat logicalWidth = size.width / size.height > 1.8 ? 874 : 1376;
    CGSize points = CGSizeMake(logicalWidth, logicalWidth * size.height / size.width);
    SceneKitRefresh *refresh = [[SceneKitRefresh alloc] initWithRenderer:renderer size:points];
    [refresh buildWorld];
    [refresh beginRegistration:d.seed];
    for (CaptureObject *object in d.objects) {
        RefEntity entity = object.entity;
        entity.model = [refresh registerModel:object.model];
        object.entity = entity;
    }
    RefModel projectile = [refresh registerModel:ProjectileModelName(@"torpedo")];
    for (CaptureExplosion *explosion in d.explosions) explosion.handle = [refresh registerModel:explosion.model];
    [refresh upload:nil];
    [refresh endRegistration];
    renderer.scene = refresh.scene;
    renderer.pointOfView = refresh.cameraNode;
    renderer.autoenablesDefaultLighting = NO;
    HUD *hud = [[HUD alloc] initWithSize:points];
    hud.scaleMode = SKSceneScaleModeAspectFit;
    hud.touchLayout = YES;
    [hud setHelpVisible:NO];
    if (d.objective.length)
        [hud setObjectives:@[[[ObjectiveReadout alloc] initWithText:L10nExpand(d.objective) status:ObjectiveOpen]]];
    if (flightView || d.showHUD) renderer.overlaySKScene = hud;
    NSImage *last = nil;
    const int stride = CaptureTickRate / CaptureVideoRate;
    const int firstTick = firstFrame * stride;
    int frames = sink ? firstTick + (count - 1) * stride : (int)ceil(d.time * CaptureTickRate);
    for (int frame = 0; frame <= frames; frame++) {
        @autoreleasepool {
            double time = (double)frame / CaptureTickRate;
            if (!sink) time = fmin(time, d.time);
            float elapsed = (float)(time - d.time);
            [refresh beginFrame:time + 1];
            RefEntity player = CapturePose(pilot, elapsed);
            RefCamera camera = d.camera;
            if (flightView) {
                flight.move.origin = player.origin;
                flight.move.orientation = player.orientation;
                flight.move.velocity = pilot.velocity;
                flight.move.angularVelocity = pilot.angularVelocity;
                flight.move.boosting = player.boost;
                camera = FlightCameraUpdate(&rig, &flight, eye, d.cockpit, YES, -1,
                                            1.0f / CaptureTickRate, time + 1);
                player.orientation = FlightViewOrientation(&flight);
            } else if (d.cockpit) {
                camera.origin = player.origin + simd_act(player.orientation, eye);
                camera.orientation = player.orientation;
                camera.focus = player.origin + simd_act(player.orientation, simd_make_float3(0, 0, -60));
                camera.velocity = pilot.velocity;
            } else {
                simd_float3 tracking = d.followPlayer ? pilot.velocity : simd_make_float3(0, 0, 0);
                camera.velocity = tracking + d.cameraVelocity;
                camera.origin += camera.velocity * elapsed;
                camera.focus += (tracking + d.aimVelocity) * elapsed;
                camera.orientation = CaptureFacing(camera.focus - camera.origin, d.roll + d.rollRate * elapsed);
            }
            [refresh setCamera:camera];
            if (flightView || d.cockpit) [refresh setPlayer:&player alive:YES interior:d.cockpit];
            for (CaptureObject *object in d.objects) {
                if (time > object.until || ((flightView || d.cockpit) && object == pilot)) continue;
                RefEntity entity = CapturePose(object, elapsed);
                [refresh addEntity:&entity];
            }
            for (CaptureExplosion *explosion in d.explosions)
                if (time >= explosion.time && (frame == 0 || (double)(frame - 1) / CaptureTickRate < explosion.time))
                    [refresh explosionAt:explosion.origin velocity:explosion.velocity model:explosion.handle scale:explosion.scale];
            int slot = 0;
            for (CaptureBolt *bolt in d.bolts) {
                double age = time - bolt.start;
                if (age >= 0 && age <= bolt.life) {
                    simd_float3 p = bolt.origin + bolt.velocity * (float)age;
                    if (age < 1.5 / CaptureTickRate) [refresh showBolt:slot at:p velocity:bolt.velocity friendly:bolt.friendly ion:NO];
                    else [refresh moveBolt:slot to:p];
                } else [refresh hideBolt:slot];
                slot++;
            }
            NSUInteger index = 0;
            for (CaptureMissile *missile in d.missiles) {
                if (time >= missile.start && time <= missile.start + missile.duration) {
                    simd_float3 p = CaptureMissilePoint(missile, time);
                    RefEntity entity = { .key = (uint16_t)(100 + index), .kind = EntityProjectile, .model = projectile,
                        .origin = p, .scale = 1 };
                    [refresh addEntity:&entity];
                }
                index++;
            }
            [refresh endFrame];
            if (sink && frame % stride != 0) continue;
            CGPoint centre = RectCenter((CGRect){ .size = points });
            HUDFrame hf = { .boresight = centre, .boresightVisible = YES, .throttle = 0.75, .boostEnergy = 1,
                .secondary = 3, .secondaryCapacity = 4, .secondaryName = @"TORPEDO",
                .cockpit = d.cockpit };
            if (flightView) {
                FlightCameraSight(&hf, refresh, &flight, rig.seat, d.cockpit);
                hf.throttle = player.throttle;
                hf.boosting = player.boost;
                hf.speed = simd_length(pilot.velocity);
                hf.boostEnergy = player.boost ? fmaxf(0, 1 - (float)time * flight.params.boostDrain) : 1;
                hf.secondaryCapacity = pilotDef && pilotDef->secondary.rounds > 0 ? pilotDef->secondary.rounds : 4;
                hf.secondary = hf.secondaryCapacity;
                for (CaptureMissile *missile in d.missiles)
                    if (missile.fromPlayer && time >= missile.start && hf.secondary > 0) hf.secondary--;
            }
            HUDTarget target = {0};
            NSUInteger targets = 0;
            for (CaptureObject *object in d.objects) if (object.label.length && time <= object.until) {
                RefEntity entity = CapturePose(object, elapsed);
                CGPoint point = centre;
                BOOL onScreen = [refresh projectPoint:entity.origin to:&point];
                target = (HUDTarget){ .onScreen = onScreen,
                    .point = point, .distance = simd_distance(entity.origin, player.origin),
                    .size = 24, .health = 1, .kind = HUDKindEnemy, .capital = entity.kind == EntityCapital,
                    .selected = flightView,
                    .label = L10nExpand(object.label) };
                targets = 1;
                break;
            }
            [hud updateFrame:hf targets:&target count:targets];
            CockpitFrame cf = { .alive = YES, .hull = 1, .shield = 1, .boostEnergy = 1, .weaponEnergy = 0.95,
                .weaponShotEnergy = 0.035f, .weaponRecharge = 0.22f, .shieldRecharge = 0.06f,
                .throttle = 0.75, .speed = 120, .maxSpeed = 160, .target = -1, .secondary = 3,
                .secondaryName = @"TORP", .time = time,
                .sun = simd_act(simd_inverse(player.orientation), refresh.sunDirection) };
            if (flightView) {
                cf.throttle = hf.throttle;
                cf.speed = hf.speed;
                cf.boostEnergy = hf.boostEnergy;
                cf.boosting = hf.boosting;
                cf.secondary = hf.secondary;
                if (pilotDef) cf.maxSpeed = pilotDef->params.maxSpeed;
            }
            CockpitContact contacts[COCKPIT_MAX_CONTACTS];
            NSUInteger contactCount = 0;
            for (CaptureObject *object in d.objects) {
                if (object == pilot || time > object.until || contactCount == COCKPIT_MAX_CONTACTS) continue;
                if (![object.model hasPrefix:@"ship:"] && !object.label.length) continue;
                RefEntity entity = CapturePose(object, elapsed);
                contacts[contactCount++] = (CockpitContact){
                    .local = simd_act(simd_inverse(player.orientation), entity.origin - player.origin),
                    .orientation = simd_mul(simd_inverse(player.orientation), entity.orientation),
                    .relation = [object.model isEqualToString:d.objects.firstObject.model] ? RelationFriendly : RelationHostile,
                    .capital = entity.kind == EntityCapital, .hull = 1, .shield = 1, .systems = 1,
                    .name = L10nExpand(object.label),
                };
                if (object.label.length && cf.target < 0) cf.target = (int)contactCount - 1;
            }
            if (d.cockpit) {
                [refresh updateCockpit:cf contacts:contacts count:contactCount];
                [refresh renderDisplaysWithQueue:queue time:time + 1];
            }
            [hud updateInstruments:cf contacts:contacts count:contactCount cockpit:d.cockpit];
            BOOL exportFrame = sink && frame >= firstTick;
            CGSize renderSize = exportFrame || frame == frames ? size : points;
            last = [renderer snapshotAtTime:time + 1 withSize:renderSize
                           antialiasingMode:sink ? SCNAntialiasingModeMultisampling2X : SCNAntialiasingModeMultisampling4X];
            if (!last || (exportFrame && !sink(last))) return nil;
        }
    }
    return last;
}

@implementation SceneCapture
+ (int)renderFile:(NSString *)definition toFile:(NSString *)path size:(CGSize)size {
    CaptureDefinition *d = [CaptureDefinition read:definition];
    if (!d.objects.count || !CaptureSizeValid(size)) {
        fprintf(stderr, "Invalid scene definition or image size\n");
        return 2;
    }
    NSImage *last = CaptureRender(d, size, 0, 0, nil);
    CGImageRef image = [last CGImageForProposedRect:NULL context:nil hints:nil];
    NSBitmapImageRep *bitmap = image ? [[NSBitmapImageRep alloc] initWithCGImage:image] : nil;
    BOOL jpeg = [@[@"jpg", @"jpeg"] containsObject:path.pathExtension.lowercaseString];
    NSData *encoded = [bitmap representationUsingType:jpeg ? NSBitmapImageFileTypeJPEG : NSBitmapImageFileTypePNG
                                            properties:jpeg ? @{NSImageCompressionFactor: @0.98} : @{}];
    if (![encoded writeToFile:path atomically:YES]) { fprintf(stderr, "Cannot write scene image\n"); return 1; }
    printf("Rendered %s at %.0f x %.0f\n", path.UTF8String, size.width, size.height);
    return 0;
}

+ (int)streamFile:(NSString *)definition size:(CGSize)size firstFrame:(int)firstFrame count:(int)count {
    CaptureDefinition *d = [CaptureDefinition read:definition];
    if (!d.objects.count || !CaptureSizeValid(size) || firstFrame < 0 || firstFrame > 300 ||
        count <= 0 || count > 300) {
        fprintf(stderr, "Invalid scene, size or frame range\n");
        return 2;
    }
    // Keep diagnostics away from the raw frame stream, including engine logs.
    int output = dup(STDOUT_FILENO);
    if (output < 0) return 1;
    FILE *stream = fdopen(output, "wb");
    if (!stream) { close(output); return 1; }
    if (dup2(STDERR_FILENO, STDOUT_FILENO) < 0) { fclose(stream); return 1; }

    size_t width = (size_t)size.width, height = (size_t)size.height;
    size_t rowBytes = width * 4;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, rowBytes, space,
                                                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    NSImage *last = nil;
    if (context) {
        CGRect rect = (CGRect){ .size = size };
        void *pixels = CGBitmapContextGetData(context);
        size_t bytes = height * rowBytes;
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        last = CaptureRender(d, size, firstFrame, count, ^BOOL(NSImage *image) {
            CGImageRef frame = [image CGImageForProposedRect:NULL context:nil hints:nil];
            if (!frame) return NO;
            CGContextDrawImage(context, rect, frame);
            return fwrite(pixels, 1, bytes, stream) == bytes;
        });
        CGContextRelease(context);
    }
    int closed = fclose(stream);
    if (last && closed == 0) return 0;
    fprintf(stderr, "Cannot stream scene frames\n");
    return 1;
}
@end
#endif
