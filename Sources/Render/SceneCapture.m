#import <TargetConditionals.h>
#if !TARGET_OS_IOS
#import "Render.h"
#import "Common.h"

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
@property (nonatomic) BOOL followPlayer, cockpit;
@property (nonatomic) RefCamera camera;
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
    simd_float3 eye = JSONVec3(json, @"eye", simd_make_float3(0, 4, 19));
    simd_float3 aim = JSONVec3(json, @"lookAt", simd_make_float3(8, 3, -60));
    d.camera = (RefCamera){ .origin = eye, .focus = aim, .orientation = CaptureFacing(aim - eye, JSONFloat(json, @"roll", 0)),
                           .fov = JSONFloat(json, @"fov", 64), .zNear = 0.1f };
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
        if (JSONBool(item, @"fromPlayer", NO) && objects.count) {
            CaptureObject *player = objects.firstObject;
            RefEntity ship = player.entity;
            float elapsed = (float)(missile.start - d.time);
            float spin = simd_length(player.angularVelocity);
            simd_quatf orientation = spin > 0 ? simd_mul(ship.orientation,
                simd_quaternion(spin * elapsed, player.angularVelocity / spin)) : ship.orientation;
            simd_float3 forward = simd_act(orientation, simd_make_float3(0, 0, -1));
            const ShipDef *definition = [player.model hasPrefix:@"ship:"] ? ShipDefNamed([player.model substringFromIndex:5]) : NULL;
            float speed = definition ? definition->secondary.launchSpeed : 120;
            missile.launch = ship.origin + player.velocity * elapsed + simd_act(orientation, missile.launch);
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

@implementation SceneCapture
+ (int)renderFile:(NSString *)definition toFile:(NSString *)path size:(CGSize)size {
    CaptureDefinition *d = [CaptureDefinition read:definition];
    if (!d || !d.objects.count || size.width < 320 || size.height < 240 || size.width > 4096 || size.height > 4096) {
        fprintf(stderr, "Invalid scene definition or image size\n");
        return 2;
    }
    [NSApplication sharedApplication];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    CaptureObject *pilot = d.objects.firstObject;
    const ShipDef *pilotDef = [pilot.model hasPrefix:@"ship:"] ? ShipDefNamed([pilot.model substringFromIndex:5]) : NULL;
    simd_float3 eye = pilotDef ? pilotDef->cockpitEye : RefCockpitEye;
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
    if (d.objective.length) [hud setObjectives:@[L10nExpand(d.objective)] states:@[@0]];
    renderer.overlaySKScene = hud;
    NSImage *last = nil;
    int frames = (int)ceil(d.time * 60);
    for (int frame = 0; frame <= frames; frame++) {
        @autoreleasepool {
            double time = fmin(frame / 60.0, d.time);
            [refresh beginFrame:time + 1];
            RefEntity player = pilot.entity;
            player.origin += pilot.velocity * (float)(time - d.time);
            float pilotSpin = simd_length(pilot.angularVelocity);
            if (pilotSpin > 0) player.orientation = simd_mul(player.orientation,
                simd_quaternion(pilotSpin * (float)(time - d.time), pilot.angularVelocity / pilotSpin));
            RefCamera camera = d.camera;
            if (d.cockpit) {
                // The pilot's eye, looking along the nose; `roll` and `fov` still apply.
                camera.origin = player.origin + simd_act(player.orientation, eye);
                camera.orientation = player.orientation;
                camera.focus = player.origin + simd_act(player.orientation, simd_make_float3(0, 0, -60));
                camera.velocity = pilot.velocity;
            } else if (d.followPlayer) {
                simd_float3 offset = d.objects.firstObject.velocity * (float)(time - d.time);
                camera.origin += offset;
                camera.focus += offset;
                camera.velocity = d.objects.firstObject.velocity;
            }
            [refresh setCamera:camera];
            if (d.cockpit) [refresh setPlayer:&player alive:YES interior:YES];
            for (CaptureObject *object in d.objects) {
                if (time > object.until || (d.cockpit && object == pilot)) continue;
                RefEntity entity = object.entity;
                entity.origin += object.velocity * (float)(time - d.time);
                float spin = simd_length(object.angularVelocity);
                if (spin > 0) entity.orientation = simd_mul(entity.orientation,
                    simd_quaternion(spin * (float)(time - d.time), object.angularVelocity / spin));
                [refresh addEntity:&entity];
            }
            for (CaptureExplosion *explosion in d.explosions)
                if (time >= explosion.time && (frame == 0 || (frame - 1) / 60.0 < explosion.time))
                    [refresh explosionAt:explosion.origin velocity:explosion.velocity model:explosion.handle scale:explosion.scale];
            int slot = 0;
            for (CaptureBolt *bolt in d.bolts) {
                double age = time - bolt.start;
                if (age >= 0 && age <= bolt.life) {
                    simd_float3 p = bolt.origin + bolt.velocity * (float)age;
                    if (age < 1.5 / 60) [refresh showBolt:slot at:p velocity:bolt.velocity friendly:bolt.friendly ion:NO];
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
            CGPoint centre = RectCenter((CGRect){ .size = points });
            HUDFrame hf = { .boresight = centre, .boresightVisible = YES, .throttle = 0.75, .boostEnergy = 1,
                .secondary = 3, .secondaryCapacity = 4, .secondaryName = @"TORPEDO", .deltaTime = 1.0f / 60,
                .cockpit = d.cockpit };
            // The sun's lens flare, as the live view finds it.
            simd_float3 sunDirection = refresh.sunDirection;
            CGPoint sun;
            if ([refresh projectPoint:camera.origin + sunDirection * 20000.0f to:&sun]) {
                hf.sun = sun;
                hf.sunVisibility = CGRectContainsPoint((CGRect){ .size = points }, sun) &&
                    ![refresh traceOpaqueFrom:camera.origin to:camera.origin + sunDirection * 5000.0f] ? 1 : 0;
            }
            HUDTarget target = {0};
            NSUInteger targets = 0;
            for (CaptureObject *object in d.objects) if (object.label.length) {
                CGPoint point;
                BOOL onScreen = [refresh projectPoint:object.entity.origin to:&point];
                target = (HUDTarget){ .onScreen = onScreen,
                    .point = point, .distance = simd_distance(object.entity.origin, d.objects.firstObject.entity.origin),
                    .size = 24, .health = 1, .kind = HUDKindEnemy, .capital = YES,
                    .label = L10nExpand(object.label) };
                targets = 1;
                break;
            }
            [hud updateFrame:hf targets:&target count:targets];
            CockpitFrame cf = { .alive = YES, .hull = 1, .shield = 1, .boostEnergy = 1, .weaponEnergy = 0.95,
                .weaponShotEnergy = 0.035f, .weaponRecharge = 0.22f, .shieldRecharge = 0.06f,
                .throttle = 0.75, .speed = 120, .maxSpeed = 160, .target = -1, .secondary = 3,
                .secondaryName = @"TORP", .time = time,
                .sun = simd_act(simd_inverse(player.orientation), sunDirection) };
            CockpitContact contacts[COCKPIT_MAX_CONTACTS];
            NSUInteger contactCount = 0;
            for (CaptureObject *object in d.objects) {
                if (object == pilot || contactCount == COCKPIT_MAX_CONTACTS) continue;
                if (![object.model hasPrefix:@"ship:"] && !object.label.length) continue;
                RefEntity entity = object.entity;
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
            CGSize renderSize = frame == frames ? size : points;
            last = [renderer snapshotAtTime:time + 1 withSize:renderSize antialiasingMode:SCNAntialiasingModeMultisampling4X];
        }
    }
    CGImageRef image = [last CGImageForProposedRect:NULL context:nil hints:nil];
    NSBitmapImageRep *bitmap = image ? [[NSBitmapImageRep alloc] initWithCGImage:image] : nil;
    BOOL jpeg = [@[@"jpg", @"jpeg"] containsObject:path.pathExtension.lowercaseString];
    NSData *encoded = [bitmap representationUsingType:jpeg ? NSBitmapImageFileTypeJPEG : NSBitmapImageFileTypePNG
                                            properties:jpeg ? @{NSImageCompressionFactor: @0.98} : @{}];
    if (![encoded writeToFile:path atomically:YES]) { fprintf(stderr, "Cannot write scene image\n"); return 1; }
    printf("Rendered %s at %.0f x %.0f\n", path.UTF8String, size.width, size.height);
    return 0;
}
@end
#endif
