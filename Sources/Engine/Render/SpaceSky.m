#import "SpaceSky.h"

typedef struct {
    simd_float4 sunDir;
    simd_float4 galaxyNormal;
    simd_float4 galaxyCenter;
    simd_float4 planetDir;
    simd_float4 planetAxis;
    uint32_t faceSize;
    uint32_t seed;
    uint32_t face;
    uint32_t pad;
} SkyParams;

static const float kDustBox = 360.0f;
static const NSUInteger kDustCount = 1400;

@implementation SpaceSky {
    id<MTLDevice> _device;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device faceSize:(NSUInteger)faceSize seed:(uint32_t)seed {
    if ((self = [super init])) {
        _device = device;
        _sunDirection = simd_normalize(simd_make_float3(0.55f, 0.32f, -0.77f));
        _planetDirection = simd_normalize(simd_make_float3(-0.62f, -0.18f, -0.76f));
        CFTimeInterval t0 = CACurrentMediaTime();
        [self bakeWithFaceSize:faceSize seed:seed];
        _bakeSeconds = CACurrentMediaTime() - t0;
    }
    return self;
}

- (id<MTLComputePipelineState>)pipeline:(NSString *)name library:(id<MTLLibrary>)library {
    NSError *error = nil;
    id<MTLFunction> fn = [library newFunctionWithName:name];
    id<MTLComputePipelineState> pso = [_device newComputePipelineStateWithFunction:fn error:&error];
    if (!pso) NSLog(@"SpaceSky: pipeline %@ failed: %@", name, error);
    return pso;
}

- (void)dispatch:(id<MTLComputePipelineState>)pso queue:(id<MTLCommandQueue>)queue
          output:(id<MTLTexture>)output input:(id<MTLTexture>)input params:(SkyParams)params {
    // One command buffer per face keeps each GPU submission short.
    for (uint32_t face = 0; face < 6; face++) {
        params.face = face;
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setTexture:output atIndex:0];
        if (input) [enc setTexture:input atIndex:1];
        [enc setBytes:&params length:sizeof(params) atIndex:0];
        MTLSize tg = MTLSizeMake(16, 16, 1);
        [enc dispatchThreads:MTLSizeMake(params.faceSize, params.faceSize, 1) threadsPerThreadgroup:tg];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) NSLog(@"SpaceSky: face %u failed: %@", face, cb.error);
    }
}

- (void)bakeWithFaceSize:(NSUInteger)faceSize seed:(uint32_t)seed {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"SkyBake" ofType:@"metal" inDirectory:@"Shaders"];
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    if (@available(macOS 15.0, iOS 18.0, *)) options.mathMode = MTLMathModeFast;
    id<MTLLibrary> library = [_device newLibraryWithSource:source ?: @"" options:options error:&error];
    if (!library) {
        NSLog(@"SpaceSky: shader compile failed: %@", error);
        return;
    }

    SkyParams params = {0};
    simd_float3 galaxyNormal = simd_normalize(simd_make_float3(0.25f, 0.9f, 0.35f));
    simd_float3 galaxyCenter = simd_normalize(simd_cross(galaxyNormal, simd_make_float3(1, 0, 0)));
    simd_float3 planetDir = _planetDirection;
    simd_float3 planetAxis = simd_normalize(simd_make_float3(0.2f, 1.0f, 0.15f));
    params.sunDir = simd_make_float4(_sunDirection, 0.010f);
    params.galaxyNormal = simd_make_float4(galaxyNormal, 0);
    params.galaxyCenter = simd_make_float4(galaxyCenter, 0);
    params.planetDir = simd_make_float4(planetDir, 0.16f);
    params.planetAxis = simd_make_float4(planetAxis, 0);
    params.seed = seed;

    id<MTLCommandQueue> queue = [_device newCommandQueue];

    // Pass 1: volumetric nebula at low resolution (it is smooth anyway).
    NSUInteger nebSize = MAX(faceSize / 4, 128);
    MTLTextureDescriptor *nd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                     size:nebSize mipmapped:NO];
    nd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    nd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> nebula = [_device newTextureWithDescriptor:nd];
    params.faceSize = (uint32_t)nebSize;
    [self dispatch:[self pipeline:@"bakeNebula" library:library] queue:queue output:nebula input:nil params:params];

    // Pass 2: full-resolution composite with mip chain for image based lighting.
    MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                     size:faceSize mipmapped:YES];
    cd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    cd.storageMode = MTLStorageModePrivate;
    _cubeTexture = [_device newTextureWithDescriptor:cd];
    params.faceSize = (uint32_t)faceSize;
    [self dispatch:[self pipeline:@"composeSky" library:library] queue:queue output:_cubeTexture input:nebula params:params];

    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit generateMipmapsForTexture:_cubeTexture];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

#pragma mark - Dust

- (SCNNode *)makeDustNode {
    // Each streak is a line whose two ends share a base position; the
    // geometry shader wraps the base around the camera and pulls the tail
    // end back along the camera's motion, so dust reads as speed streaks.
    NSUInteger vcount = kDustCount * 2;
    simd_float3 *pos = malloc(sizeof(simd_float3) * vcount);
    simd_float2 *tc = malloc(sizeof(simd_float2) * vcount);
    uint32_t *idx = malloc(sizeof(uint32_t) * vcount);
    for (NSUInteger i = 0; i < kDustCount; i++) {
        simd_float3 p = simd_make_float3(((float)arc4random_uniform(10000) / 10000.0f - 0.5f) * kDustBox,
                                         ((float)arc4random_uniform(10000) / 10000.0f - 0.5f) * kDustBox,
                                         ((float)arc4random_uniform(10000) / 10000.0f - 0.5f) * kDustBox);
        pos[i * 2] = p;
        pos[i * 2 + 1] = p;
        tc[i * 2] = simd_make_float2(0, 0);
        tc[i * 2 + 1] = simd_make_float2(1, 0);
        idx[i * 2] = (uint32_t)(i * 2);
        idx[i * 2 + 1] = (uint32_t)(i * 2 + 1);
    }
    NSData *posData = [NSData dataWithBytesNoCopy:pos length:sizeof(simd_float3) * vcount freeWhenDone:YES];
    NSData *tcData = [NSData dataWithBytesNoCopy:tc length:sizeof(simd_float2) * vcount freeWhenDone:YES];
    NSData *idxData = [NSData dataWithBytesNoCopy:idx length:sizeof(uint32_t) * vcount freeWhenDone:YES];

    SCNGeometrySource *ps = [SCNGeometrySource geometrySourceWithData:posData semantic:SCNGeometrySourceSemanticVertex
                                                          vectorCount:vcount floatComponents:YES componentsPerVector:3
                                                    bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(simd_float3)];
    SCNGeometrySource *ts = [SCNGeometrySource geometrySourceWithData:tcData semantic:SCNGeometrySourceSemanticTexcoord
                                                          vectorCount:vcount floatComponents:YES componentsPerVector:2
                                                    bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(simd_float2)];
    SCNGeometryElement *el = [SCNGeometryElement geometryElementWithData:idxData primitiveType:SCNGeometryPrimitiveTypeLine
                                                          primitiveCount:kDustCount bytesPerIndex:sizeof(uint32_t)];
    SCNGeometry *geo = [SCNGeometry geometryWithSources:@[ps, ts] elements:@[el]];

    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;
    m.blendMode = SCNBlendModeAdd;
    m.writesToDepthBuffer = NO;
    m.doubleSided = YES;
    m.shaderModifiers = @{
        SCNShaderModifierEntryPointGeometry :
            @"#pragma arguments\n"
             "float3 camPos;\n"
             "float3 streak;\n"
             "float boxSize;\n"
             "#pragma varyings\n"
             "float fade;\n"
             "#pragma body\n"
             "float3 rel = _geometry.position.xyz - camPos;\n"
             "rel -= boxSize * floor(rel / boxSize + 0.5);\n"
             "float dist = length(rel);\n"
             "out.fade = (1.0 - smoothstep(boxSize * 0.2, boxSize * 0.5, dist)) * smoothstep(2.0, 12.0, dist);\n"
             "_geometry.position = float4(rel + streak * _geometry.texcoords[0].x, 1.0);\n",
        SCNShaderModifierEntryPointFragment :
            @"#pragma body\n"
             "_output.color = float4(float3(0.30, 0.36, 0.48) * in.fade, 1.0);\n",
    };
    [m setValue:@(kDustBox) forKey:@"boxSize"];
    geo.materials = @[m];

    SCNNode *node = [SCNNode nodeWithGeometry:geo];
    node.name = @"dust";
    node.castsShadow = NO;
    node.renderingOrder = 50;
    return node;
}

- (void)updateDust:(SCNNode *)dust cameraPosition:(simd_float3)cameraPosition velocity:(simd_float3)velocity {
    dust.simdPosition = cameraPosition;
    SCNMaterial *m = dust.geometry.firstMaterial;
    simd_float3 streak = velocity * -0.018f + simd_make_float3(0.02f, 0.02f, 0.02f);
    [m setValue:[NSValue valueWithSCNVector3:SCNVector3Make(cameraPosition.x, cameraPosition.y, cameraPosition.z)] forKey:@"camPos"];
    [m setValue:[NSValue valueWithSCNVector3:SCNVector3Make(streak.x, streak.y, streak.z)] forKey:@"streak"];
}

@end
