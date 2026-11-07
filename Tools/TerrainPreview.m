// Renders DawnPatrol terrain to PNGs without starting the game, from the same cameras:
// the shipped landscape model through SceneKit (current), the raymarched reference of
// Resources/Shaders/TerrainCommon.metal (procedural) and the game's geometry clipmap
// built by Sources/Render/Terrain.m (engine).
//
//   make build/tools/TerrainPreview
//   build/tools/TerrainPreview [current|procedural|engine|all] [outdir] [width] [height]

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#import "Render.h"

typedef struct {
    const char *name;
    simd_float3 eye, target;
    float fovDegrees;
} View;

static const View kViews[] = {
    { "start",   { 0, 400, 600 },      { 0, 250, -1500 },    70 },
    { "high",    { -3000, 1200, 4000 }, { 0, 0, -2000 },      70 },
    { "river",   { 1500, 120, 3200 },  { 600, 0, 0 },        65 },
    { "sunward", { 2000, 600, 2000 },  { -2000, 200, -3000 }, 70 },
    { "treetops", { 0, 140, 300 },     { 200, 0, -600 },      60 },
};
static const simd_float3 kSun = { -0.4f, 0.7f, -0.5f };

typedef struct {
    simd_float4 camPos, camTarget, sunDir;
    simd_uint4 size;
} Params;

static BOOL WritePNG(CGImageRef image, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

// Fog as Games/DawnPatrol/Levels/01-morning-patrol.json declares it.
static LevelEnvironment PatrolEnvironment(void) {
    return (LevelEnvironment){ .terrain = true, .fogColor = { 0.67f, 0.76f, 0.81f }, .fogStart = 3500, .fogEnd = 12000 };
}

static SCNNode *MakeCamera(void) {
    SCNCamera *cam = [SCNCamera camera];
    cam.zNear = 0.3;
    cam.zFar = 40000;
    cam.wantsHDR = NO;
    SCNNode *eye = [SCNNode node];
    eye.camera = cam;
    return eye;
}

static void SnapshotViews(SCNRenderer *renderer, SCNNode *eye, NSString *outDir, NSString *prefix, CGSize size,
                          void (^beforeView)(View view)) {
    for (size_t i = 0; i < sizeof kViews / sizeof *kViews; i++) {
        View v = kViews[i];
        CFTimeInterval t0 = CACurrentMediaTime();
        eye.camera.fieldOfView = v.fovDegrees;
        eye.simdPosition = v.eye;
        [eye simdLookAt:v.target];
        if (beforeView) beforeView(v);
        NSImage *image = [renderer snapshotAtTime:0 withSize:size antialiasingMode:SCNAntialiasingModeMultisampling4X];
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        NSString *path = [outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%s.png", prefix, v.name]];
        printf("%s %s (%.1fs)\n", WritePNG(cg, path) ? "wrote" : "FAILED", path.UTF8String, CACurrentMediaTime() - t0);
    }
}

// MARK: - Shipped landscape

static void RenderCurrent(id<MTLDevice> device, NSString *outDir, CGSize size) {
    NSURL *model = [NSURL fileURLWithPath:@"build/ModelCache/DawnPatrol/Models/PatrolLandscape.scn"];
    SCNScene *scene = [SCNScene sceneWithURL:model options:nil error:nil];
    if (!scene) { fprintf(stderr, "missing %s; run ./build.sh first\n", model.path.UTF8String); return; }
    [scene.rootNode enumerateHierarchyUsingBlock:^(SCNNode *child, BOOL *stop) {
        for (SCNMaterial *material in child.geometry.materials) {
            material.lightingModelName = SCNLightingModelPhysicallyBased;
            material.roughness.contents = @1;
            material.metalness.contents = @0;
        }
    }];
    // Same environment as Games/DawnPatrol/Levels/01-morning-patrol.json and SceneKitRefresh.
    scene.fogStartDistance = 3500;
    scene.fogEndDistance = 12000;
    scene.fogColor = [NSColor colorWithRed:0.67 green:0.76 blue:0.81 alpha:1];
    NSImage *sky = [[NSImage alloc] initWithContentsOfFile:@"Games/DawnPatrol/Textures/PatrolSky.jpg"];
    scene.background.contents = sky;
    scene.lightingEnvironment.contents = sky;
    scene.lightingEnvironment.intensity = 0.8;

    SCNNode *sun = [SCNNode node];
    sun.light = [SCNLight light];
    sun.light.type = SCNLightTypeDirectional;
    sun.light.color = [NSColor colorWithRed:1.0 green:0.94 blue:0.86 alpha:1];
    sun.light.intensity = 2600;
    sun.simdPosition = simd_normalize(kSun) * 250.0f;
    [sun simdLookAt:simd_make_float3(0, 0, 0)];
    [scene.rootNode addChildNode:sun];

    SCNNode *eye = MakeCamera();
    [scene.rootNode addChildNode:eye];

    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    renderer.scene = scene;
    renderer.pointOfView = eye;
    SnapshotViews(renderer, eye, outDir, @"current", size, nil);
}

// MARK: - Game clipmap

static void RenderEngine(id<MTLDevice> device, NSString *outDir, CGSize size) {
    id<MTLLibrary> library = [ProceduralTerrain libraryWithDevice:device shaderDirectory:[NSURL fileURLWithPath:@"Resources/Shaders"]];
    if (!library) return;
    ProceduralTerrain *terrain = [[ProceduralTerrain alloc] initWithLibrary:library cells:128 hdr:NO];
    terrain.environment = PatrolEnvironment();
    terrain.sunDirection = kSun;
    SCNScene *scene = [SCNScene scene];
    [scene.rootNode addChildNode:terrain.node];
    [scene.rootNode addChildNode:terrain.skyNode];
    SCNNode *eye = MakeCamera();
    [scene.rootNode addChildNode:eye];
    SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
    renderer.scene = scene;
    renderer.pointOfView = eye;
    SnapshotViews(renderer, eye, outDir, @"engine", size, ^(View v) { [terrain updateForCamera:v.eye time:0]; });
    printf("%s\n", terrain.stats.UTF8String);
}

// MARK: - Procedural prototype

static void RenderProcedural(id<MTLDevice> device, NSString *outDir, CGSize size) {
    NSError *error = nil;
    NSString *common = [NSString stringWithContentsOfFile:@"Resources/Shaders/TerrainCommon.metal" encoding:NSUTF8StringEncoding error:&error];
    NSString *preview = common ? [NSString stringWithContentsOfFile:@"Tools/TerrainPreview.metal" encoding:NSUTF8StringEncoding error:&error] : nil;
    if (!preview) { fprintf(stderr, "%s\n", error.description.UTF8String); return; }
    NSString *source = [NSString stringWithFormat:@"%@\n%@", common, preview];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) { fprintf(stderr, "%s\n", error.description.UTF8String); return; }
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"renderTerrain"] error:&error];
    if (!pipeline) { fprintf(stderr, "%s\n", error.description.UTF8String); return; }
    id<MTLCommandQueue> queue = [device newCommandQueue];

    NSUInteger width = (NSUInteger)size.width, height = (NSUInteger)size.height;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageShaderWrite;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];

    for (size_t i = 0; i < sizeof kViews / sizeof *kViews; i++) {
        View v = kViews[i];
        CFTimeInterval t0 = CACurrentMediaTime();
        // Bands keep each command buffer well under the GPU watchdog.
        const NSUInteger band = 16;
        for (NSUInteger row = 0; row < height; row += band) {
            Params p = {
                .camPos = simd_make_float4(v.eye, v.fovDegrees * (float)M_PI / 180.0f),
                .camTarget = simd_make_float4(v.target, 0),
                .sunDir = simd_make_float4(simd_normalize(kSun), 0),
                .size = simd_make_uint4((uint32_t)width, (uint32_t)height, (uint32_t)row, 2),
            };
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pipeline];
            [enc setTexture:target atIndex:0];
            [enc setBytes:&p length:sizeof p atIndex:0];
            [enc dispatchThreads:MTLSizeMake(width, MIN(band, height - row), 1)
           threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            if (cb.error) { fprintf(stderr, "%s\n", cb.error.description.UTF8String); return; }
        }
        NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
        [target getBytes:pixels.mutableBytes bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, space,
                                         (CGBitmapInfo)kCGImageAlphaNoneSkipLast, provider, NULL, NO, kCGRenderingIntentDefault);
        NSString *path = [outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"procedural-%s.png", v.name]];
        BOOL ok = WritePNG(image, path);
        printf("%s %s (%.1fs)\n", ok ? "wrote" : "FAILED", path.UTF8String, CACurrentMediaTime() - t0);
        CGImageRelease(image);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(space);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"all";
        NSString *outDir = argc > 2 ? @(argv[2]) : @"build/TerrainPreview";
        CGSize size = CGSizeMake(argc > 3 ? atoi(argv[3]) : 1600, argc > 4 ? atoi(argv[4]) : 900);
        [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        BOOL all = [mode isEqualToString:@"all"] || [mode isEqualToString:@"both"];
        if (all || [mode isEqualToString:@"current"]) RenderCurrent(device, outDir, size);
        if (all || [mode isEqualToString:@"procedural"]) RenderProcedural(device, outDir, size);
        if (all || [mode isEqualToString:@"engine"]) RenderEngine(device, outDir, size);
    }
    return 0;
}
