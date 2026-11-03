#import "FXRecorder.h"
#import <SceneKit/SceneKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import "Effects.h"
#import "Ship.h"

static const int kFPS = 60;
static const CGSize kSize = { 1280, 720 };

@implementation FXRecorder

static SCNNode *MakeCamera(void) {
    // Same look as the game camera (see -[Game buildScene]).
    SCNCamera *cam = [SCNCamera camera];
    cam.fieldOfView = 60;
    cam.zNear = 0.3;
    cam.zFar = 5000;
    cam.wantsHDR = YES;
    cam.wantsExposureAdaptation = NO;
    cam.bloomIntensity = 1.35;
    cam.bloomThreshold = 0.9;
    cam.bloomBlurRadius = 18;
    SCNNode *n = [SCNNode node];
    n.camera = cam;
    return n;
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
        for (NSString *e in @[@"explosion", @"impact", @"shield", @"bolt", @"exhaust"])
            rc |= [self recordEffect:e toFile:[NSString stringWithFormat:@"%@_%@.mp4", base, e] seconds:seconds];
        return rc;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    SCNScene *scene = [SCNScene scene];
    scene.background.contents = [NSColor blackColor];
    renderer.scene = scene;

    SCNNode *camera = MakeCamera();
    camera.simdPosition = simd_make_float3(0, 6, 45);
    [camera simdLookAt:simd_make_float3(0, 0, 0)];
    [scene.rootNode addChildNode:camera];
    renderer.pointOfView = camera;

    // Neutral key + fill so hulls and debris read on black.
    SCNNode *key = [SCNNode node];
    key.light = [SCNLight light];
    key.light.type = SCNLightTypeDirectional;
    key.light.intensity = 1500;
    key.eulerAngles = SCNVector3Make(-0.8, 0.6, 0);
    [scene.rootNode addChildNode:key];
    SCNNode *fill = [SCNNode node];
    fill.light = [SCNLight light];
    fill.light.type = SCNLightTypeAmbient;
    fill.light.intensity = 250;
    [scene.rootNode addChildNode:fill];

    Effects *fx = [[Effects alloc] initWithScene:scene];
    [renderer prepareObjects:[fx warmupNodes] withCompletionHandler:nil];

    // Per-effect setup and per-frame driver.
    Ship *ship = nil;
    SCNNode *bolt = nil;
    void (^tick)(double t, int frame) = nil;
    if ([effect isEqualToString:@"explosion"]) {
        ship = [Ship shipWithClass:ShipClassSpitfire smoke:NO];
        [scene.rootNode addChildNode:ship.node];
        ship.node.simdOrientation = simd_quaternion((float)M_PI * 0.6f, simd_make_float3(0, 1, 0));
        __block BOOL done = NO;
        tick = ^(double t, int frame) {
            [ship.exhaust updateThrottle:0.6f boost:NO dt:1.0f / kFPS];
            if (!done && t >= 0.4) {
                done = YES;
                ship.node.hidden = YES;
                [ship.exhaust setEnabled:NO];
                [fx explosionAt:ship.position velocity:simd_make_float3(20, 0, 0) hullMaterial:ship.model.geometry.firstMaterial];
            }
        };
    } else if ([effect isEqualToString:@"impact"]) {
        tick = ^(double t, int frame) {
            if (frame % 30 == 10) {
                simd_float3 p = simd_make_float3((frame / 30 % 3 - 1) * 10.0f, 0, 0);
                [fx impactAt:p player:YES shielded:(frame / 30) % 2];
            }
        };
    } else if ([effect isEqualToString:@"shield"]) {
        ship = [Ship shipWithClass:ShipClassExecutioner smoke:NO];
        [scene.rootNode addChildNode:ship.node];
        ship.node.simdOrientation = simd_quaternion((float)M_PI * 0.75f, simd_make_float3(0, 1, 0));
        camera.simdPosition = simd_make_float3(0, 5, 22);
        [camera simdLookAt:simd_make_float3(0, 0, 0)];
        tick = ^(double t, int frame) {
            ControlState c = {0};
            c.throttle = 0.4f;
            ship.velocity = 0;
            [ship stepWithControls:c dt:1.0f / kFPS];
            ship.node.simdPosition = 0;
            if (frame % 40 == 10) {
                [ship takeDamage:0.15f];
                [fx impactAt:ship.position + simd_make_float3(0, 1.5f, 3.0f) player:NO shielded:YES];
            }
        };
    } else if ([effect isEqualToString:@"bolt"]) {
        bolt = [fx makeBoltNode];
        [scene.rootNode addChildNode:bolt];
        SCNNode *bolt2 = [fx makeBoltNode];
        [scene.rootNode addChildNode:bolt2];
        [fx styleBolt:bolt player:YES];
        [fx styleBolt:bolt2 player:NO];
        simd_quatf q = simd_quaternion(simd_make_float3(0, 1, 0), simd_normalize(simd_make_float3(1, 0, -0.3f)));
        bolt.simdOrientation = bolt2.simdOrientation = q;
        tick = ^(double t, int frame) {
            float x = fmodf((float)t * 60.0f, 120.0f) - 60.0f;  // slowed down to be visible
            bolt.simdPosition = simd_make_float3(x, 3, -x * 0.3f);
            bolt2.simdPosition = simd_make_float3(-x, -3, x * 0.3f);
        };
    } else if ([effect isEqualToString:@"exhaust"]) {
        ship = [Ship shipWithClass:ShipClassExecutioner smoke:YES];
        [scene.rootNode addChildNode:ship.node];
        // Side-on, nose pointing left, so the flames trail to the right.
        ship.node.simdOrientation = simd_quaternion((float)M_PI * 0.5f, simd_make_float3(0, 1, 0));
        camera.simdPosition = simd_make_float3(4, 5, 20);
        [camera simdLookAt:simd_make_float3(5, 0, 0)];
        tick = ^(double t, int frame) {
            // Idle -> full throttle -> boost -> idle, to show the range.
            double u = t / seconds;
            float thr = u < 0.15 ? 0.0f : u < 0.55 ? (float)((u - 0.15) / 0.4) : u < 0.85 ? 1.0f : 0.1f;
            BOOL boost = u >= 0.7 && u < 0.85;
            [ship.exhaust updateThrottle:thr boost:boost dt:1.0f / kFPS];
        };
    } else {
        fprintf(stderr, "unknown effect '%s' (explosion, impact, shield, bolt, exhaust, all)\n", effect.UTF8String);
        return 2;
    }

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
            tick(t, i);
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
