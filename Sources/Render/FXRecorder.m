#import "Render.h"
#import <SceneKit/SceneKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import "Shared.h"

static const int kFPS = 60;
static const CGSize kSize = { 1280, 720 };

@implementation FXRecorder

// A camera at `eye` looking at `target`, +Y up.
static RefCamera LookAt(simd_float3 eye, simd_float3 target) {
    simd_float3 back = simd_normalize(eye - target);
    simd_float3 right = simd_normalize(simd_cross(simd_make_float3(0, 1, 0), back));
    simd_float3 up = simd_cross(back, right);
    simd_float3x3 m = simd_matrix(right, up, back);
    return (RefCamera){ .origin = eye, .orientation = simd_quaternion(m), .focus = target };
}

static BOOL AppendImage(AVAssetWriterInputPixelBufferAdaptor *adaptor, CGImageRef image, int frame) {
    while (!adaptor.assetWriterInput.readyForMoreMediaData) [NSThread sleepForTimeInterval:0.002];
    CVPixelBufferRef pb = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pb);
    if (!pb) return NO;
    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), kSize.width, kSize.height, 8,
                                             CVPixelBufferGetBytesPerRow(pb), cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGContextSetFillColorWithColor(ctx, CGColorGetConstantColor(kCGColorBlack));
    CGContextFillRect(ctx, CGRectMake(0, 0, kSize.width, kSize.height));
    CGContextDrawImage(ctx, CGRectMake(0, 0, kSize.width, kSize.height), image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    BOOL ok = [adaptor appendPixelBuffer:pb withPresentationTime:CMTimeMake(frame, kFPS)];
    CVPixelBufferRelease(pb);
    return ok;
}

static void WriteContactSheet(NSArray *images, NSString *path) {
    const int cols = 4, rows = 3;
    const CGFloat w = 400, h = 225;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w * cols, h * rows, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetFillColorWithColor(ctx, CGColorGetConstantColor(kCGColorBlack));
    CGContextFillRect(ctx, CGRectMake(0, 0, w * cols, h * rows));
    for (NSUInteger i = 0; i < images.count && i < cols * rows; i++) {
        CGFloat x = (i % cols) * w, y = (rows - 1 - i / cols) * h;
        CGContextDrawImage(ctx, CGRectMake(x, y, w, h), (__bridge CGImageRef)images[i]);
    }
    CGImageRef sheet = CGBitmapContextCreateImage(ctx);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:sheet];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    CGImageRelease(sheet);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

+ (int)recordEffect:(NSString *)effect toFile:(NSString *)path seconds:(double)seconds {
    if ([effect isEqualToString:@"all"]) {
        NSString *base = [path stringByDeletingPathExtension];
        int rc = 0;
        for (NSString *e in @[@"explosion", @"death", @"damage", @"impact", @"shield", @"bolt", @"exhaust"])
            rc |= [self recordEffect:e toFile:[NSString stringWithFormat:@"%@_%@.mp4", base, e] seconds:seconds];
        return rc;
    }

    // The effects go through the same renderer interface the client uses,
    // in a studio scene: black, a key and a fill light, no sky.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    SceneKitRefresh *refresh = [[SceneKitRefresh alloc] initWithRenderer:renderer size:kSize];
    [refresh buildStudio];
    renderer.scene = refresh.scene;
    renderer.pointOfView = refresh.cameraNode;
    __block RefCamera camera = LookAt(simd_make_float3(0, 6, 45), simd_make_float3(0, 0, 0));

    // Any ship will do for a preview: the first definition in the bundle.
    RefModel ship = [refresh registerModel:[@"ship:" stringByAppendingString:ShipDefNames().firstObject ?: @""]];
    [refresh upload:nil];
    [refresh endRegistration];

    // Per-effect driver: fires effects and fills the frame's entities.
    void (^tick)(double t, int frame) = nil;
    const uint16_t kShip = 1;
    if ([effect isEqualToString:@"explosion"]) {
        simd_quatf q = simd_quaternion((float)M_PI * 0.6f, simd_make_float3(0, 1, 0));
        tick = ^(double t, int frame) {
            if (t < 0.4) {
                RefEntity e = { .key = kShip, .kind = EntityFighter, .model = ship, .orientation = q, .throttle = 0.6f, .hull = 1 };
                [refresh addEntity:&e];
            } else if (frame == (int)(0.4 * kFPS)) {
                [refresh explosionAt:simd_make_float3(0, 0, 0) velocity:simd_make_float3(20, 0, 0) model:ship scale:1];
            }
        };
    } else if ([effect isEqualToString:@"death"]) {
        // The player's own ship from the chase camera's spot, 14 m behind and
        // 3 m up, backing away after the blast the way ClientView's camera does.
        tick = ^(double t, int frame) {
            float pull = 1.0f - expf(-2.5f * (float)fmax(0, t - 0.4));
            if (t < 0.4) {
                RefEntity e = { .key = kShip, .kind = EntityFighter, .model = ship, .orientation = simd_quaternion(0, simd_make_float3(0, 1, 0)),
                                .throttle = 0.6f, .hull = 0.2f };
                [refresh addEntity:&e];
            } else if (frame == (int)(0.4 * kFPS)) {
                [refresh explosionAt:simd_make_float3(0, 0, 0) velocity:simd_make_float3(0, 0, -20) model:ship scale:1];
            }
            simd_float3 eye = simd_make_float3(0, 3.2f, 14.0f) + simd_make_float3(0, 8.0f, 32.0f) * pull;
            [refresh setCamera:LookAt(eye, simd_make_float3(0, 0, -60))];
        };
    } else if ([effect isEqualToString:@"damage"]) {
        // From near the chase camera: a hit takes the hull to 35% at 0.5 s, the
        // fire burns out, the smoke thins away after it.
        simd_quatf q = simd_quaternion((float)M_PI * 0.2f, simd_make_float3(0, 1, 0));
        camera = LookAt(simd_make_float3(3, 3.2f, 12), simd_make_float3(0, 0, -4));
        tick = ^(double t, int frame) {
            RefEntity e = { .key = kShip, .kind = EntityFighter, .model = ship, .orientation = q,
                            .throttle = 0.5f, .hull = t < 0.5 ? 1.0f : 0.35f };
            [refresh addEntity:&e];
        };
    } else if ([effect isEqualToString:@"impact"]) {
        tick = ^(double t, int frame) {
            if (frame % 30 == 10) {
                simd_float3 p = simd_make_float3((frame / 30 % 3 - 1) * 10.0f, 0, 0);
                [refresh impactAt:p friendly:YES shielded:(frame / 30) % 2];
            }
        };
    } else if ([effect isEqualToString:@"shield"]) {
        simd_quatf q = simd_quaternion((float)M_PI * 0.75f, simd_make_float3(0, 1, 0));
        camera = LookAt(simd_make_float3(0, 5, 22), simd_make_float3(0, 0, 0));
        tick = ^(double t, int frame) {
            RefEntity e = { .key = kShip, .kind = EntityFighter, .model = ship, .orientation = q, .throttle = 0.4f, .hull = 1 };
            [refresh addEntity:&e];
            if (frame % 40 == 10) {
                [refresh flashShieldOn:kShip];
                [refresh impactAt:simd_make_float3(0, 1.5f, 3.0f) friendly:NO shielded:YES];
            }
        };
    } else if ([effect isEqualToString:@"bolt"]) {
        simd_float3 dir = simd_normalize(simd_make_float3(1, 0, -0.3f));
        tick = ^(double t, int frame) {
            float x = fmodf((float)t * 60.0f, 120.0f) - 60.0f;  // slowed down to be visible
            simd_float3 a = simd_make_float3(x, 3, -x * 0.3f), b = simd_make_float3(-x, -3, x * 0.3f);
            if (frame == 0) {
                [refresh showBolt:0 at:a velocity:dir friendly:YES ion:NO];
                [refresh showBolt:1 at:b velocity:dir friendly:NO ion:NO];
                [refresh showBolt:2 at:a + simd_make_float3(0, 6, 0) velocity:dir friendly:YES ion:YES];
                [refresh showBolt:3 at:b - simd_make_float3(0, 6, 0) velocity:dir friendly:NO ion:YES];
            }
            [refresh moveBolt:0 to:a];
            [refresh moveBolt:1 to:b];
            [refresh moveBolt:2 to:a + simd_make_float3(0, 6, 0)];
            [refresh moveBolt:3 to:b - simd_make_float3(0, 6, 0)];
        };
    } else if ([effect isEqualToString:@"exhaust"]) {
        // Side-on, nose pointing left, so the flames trail to the right.
        simd_quatf q = simd_quaternion((float)M_PI * 0.5f, simd_make_float3(0, 1, 0));
        camera = LookAt(simd_make_float3(4, 5, 20), simd_make_float3(5, 0, 0));
        tick = ^(double t, int frame) {
            // Idle -> full throttle -> boost -> idle, to show the range.
            double u = t / seconds;
            float thr = u < 0.15 ? 0.0f : u < 0.55 ? (float)((u - 0.15) / 0.4) : u < 0.85 ? 1.0f : 0.1f;
            BOOL boost = u >= 0.7 && u < 0.85;
            RefEntity e = { .key = kShip, .kind = EntityFighter, .model = ship, .orientation = q, .throttle = thr, .boost = boost, .hull = 1 };
            [refresh addEntity:&e];
        };
    } else {
        fprintf(stderr, "unknown effect '%s' (explosion, death, damage, impact, shield, bolt, exhaust, all)\n", effect.UTF8String);
        return 2;
    }
    [refresh setCamera:camera];

    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeMPEG4 error:&error];
    if (!writer) { fprintf(stderr, "writer: %s\n", error.description.UTF8String); return 1; }
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey : AVVideoCodecTypeH264, AVVideoWidthKey : @(kSize.width), AVVideoHeightKey : @(kSize.height),
        AVVideoCompressionPropertiesKey : @{ AVVideoAverageBitRateKey : @(12000000) } }];
    input.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferWidthKey : @(kSize.width), (id)kCVPixelBufferHeightKey : @(kSize.height) }];
    [writer addInput:input];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    int frames = (int)(seconds * kFPS);
    NSMutableArray *sheet = [NSMutableArray array];
    CFTimeInterval t0 = CACurrentMediaTime();
    for (int i = 0; i < frames; i++) {
        @autoreleasepool {
            double t = (double)i / kFPS;
            [refresh beginFrame:t];
            tick(t, i);
            [refresh endFrame];
            NSImage *img = [renderer snapshotAtTime:t withSize:kSize antialiasingMode:SCNAntialiasingModeMultisampling4X];
            CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
            if (!cg || !AppendImage(adaptor, cg, i)) { fprintf(stderr, "frame %d failed\n", i); break; }
            if (i % MAX(frames / 12, 1) == 0 && sheet.count < 12) [sheet addObject:(__bridge id)cg];
        }
    }
    [input markAsFinished];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        fprintf(stderr, "encode failed: %s\n", writer.error.description.UTF8String);
        return 1;
    }
    WriteContactSheet(sheet, [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"png"]);
    printf("%s: %d frames in %.1fs -> %s\n", effect.UTF8String, frames, CACurrentMediaTime() - t0, path.UTF8String);
    return 0;
}

@end
