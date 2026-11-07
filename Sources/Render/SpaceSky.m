#import "Render.h"
#import "Common.h"

typedef struct {
    simd_float4 sunDir, galaxyNormal, galaxyCenter, planetDir, planetAxis;
    uint32_t seed, vertexCount, pad[2];
} SkyParams;

static const float kDustBox = 360.0f;
static const NSUInteger kDustCount = 1400;

static simd_float3 SkyDirection(unsigned face, float u, float v) {
    switch (face) {
        case 0: return simd_make_float3(1, -v, -u);
        case 1: return simd_make_float3(-1, -v, u);
        case 2: return simd_make_float3(u, 1, v);
        case 3: return simd_make_float3(u, -1, -v);
        case 4: return simd_make_float3(u, -v, 1);
        default: return simd_make_float3(-u, -v, -1);
    }
}

static simd_float3 SkyRandom(uint32_t index, uint32_t seed) {
    simd_uint3 v = simd_make_uint3(index, seed, index ^ seed);
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return __builtin_convertvector(v, simd_float3) * (1.0f / 4294967295.0f);
}

@implementation SpaceSky

- (SCNMaterial *)materialWithLibrary:(id<MTLLibrary>)library vertex:(NSString *)vertex
                           fragment:(NSString *)fragment params:(SkyParams)params additive:(BOOL)additive {
    SCNProgram *program = [SCNProgram new];
    program.library = library;
    program.vertexFunctionName = vertex;
    program.fragmentFunctionName = fragment;
    program.opaque = !additive;
    [program handleBindingOfBufferNamed:@"P" frequency:SCNBufferFrequencyPerFrame
                            usingBlock:^(id<SCNBufferStream> stream, SCNNode *node, id<SCNShadable> shadable, SCNRenderer *renderer) {
        [stream writeBytes:&params length:sizeof(params)];
    }];
    SCNMaterial *material = [SCNMaterial material];
    material.program = program;
    material.doubleSided = YES;
    material.readsFromDepthBuffer = NO;
    material.writesToDepthBuffer = NO;
    material.blendMode = additive ? SCNBlendModeAdd : SCNBlendModeReplace;
    return material;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device seed:(uint32_t)seed {
    if (!(self = [super init])) return nil;
    _sunDirection = simd_normalize(simd_make_float3(0.55f, 0.32f, -0.77f));
    _planetDirection = simd_normalize(simd_make_float3(-0.62f, -0.18f, -0.76f));
    _node = [SCNNode node];
    _node.name = @"Procedural sky";
    _node.categoryBitMask = RenderCategoryBackground;
    _node.castsShadow = NO;
    _node.renderingOrder = -1000;

    static id<MTLLibrary> library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"SpaceSky" withExtension:@"metal" subdirectory:@"Shaders"];
        NSString *source = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        NSError *error = nil;
        library = [device newLibraryWithSource:source ?: @"" options:nil error:&error];
        if (!library) NSLog(@"SpaceSky: shader compile failed: %@", error);
    });
    if (!library) return self;

    // The nebula changes slowly across the sky, so interpolate its colours on
    // a mesh instead of retaining six image faces and their mip chains.
    const unsigned divisions = 64, side = divisions + 1;
    const unsigned count = 6 * side * side, indexCount = 6 * divisions * divisions * 6;
    id<MTLBuffer> directions = [device newBufferWithLength:count * sizeof(simd_float3) options:MTLResourceStorageModeShared];
    id<MTLBuffer> colours = [device newBufferWithLength:count * sizeof(simd_half4) options:MTLResourceStorageModeShared];
    simd_float3 *positions = directions.contents;
    NSMutableData *indices = [NSMutableData dataWithLength:indexCount * sizeof(uint32_t)];
    uint32_t *triangles = indices.mutableBytes;
    unsigned vertex = 0, index = 0;
    for (unsigned face = 0; face < 6; face++) {
        for (unsigned y = 0; y <= divisions; y++) {
            for (unsigned x = 0; x <= divisions; x++)
                positions[vertex++] = SkyDirection(face, 2.0f * x / divisions - 1, 2.0f * y / divisions - 1);
        }
        for (unsigned y = 0; y < divisions; y++) {
            for (unsigned x = 0; x < divisions; x++) {
                unsigned a = face * side * side + y * side + x, b = a + 1, c = a + side, d = c + 1;
                triangles[index++] = a; triangles[index++] = b; triangles[index++] = c;
                triangles[index++] = b; triangles[index++] = d; triangles[index++] = c;
            }
        }
    }
    SkyParams params = {0};
    params.sunDir = simd_make_float4(_sunDirection, 0.010f);
    simd_float3 normal = simd_normalize(simd_make_float3(0.25f, 0.9f, 0.35f));
    params.galaxyNormal = simd_make_float4(normal, 0);
    params.galaxyCenter = simd_make_float4(simd_normalize(simd_cross(normal, simd_make_float3(1, 0, 0))), 0);
    params.planetDir = simd_make_float4(_planetDirection, 0.16f);
    params.planetAxis = simd_make_float4(simd_normalize(simd_make_float3(0.2f, 1.0f, 0.15f)), 0);
    params.seed = seed;
    params.vertexCount = count;
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"colourSkyMesh"] error:&error];
    if (!pipeline) { NSLog(@"SpaceSky: mesh colours failed: %@", error); return self; }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:directions offset:0 atIndex:0];
    [encoder setBuffer:colours offset:0 atIndex:1];
    [encoder setBytes:&params length:sizeof(params) atIndex:2];
    [encoder dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(pipeline.threadExecutionWidth, 1, 1)];
    [encoder endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    if (commands.error) NSLog(@"SpaceSky: mesh colours failed: %@", commands.error);
    SCNGeometrySource *positionSource = [SCNGeometrySource geometrySourceWithBuffer:directions vertexFormat:MTLVertexFormatFloat3
        semantic:SCNGeometrySourceSemanticVertex vertexCount:count dataOffset:0 dataStride:sizeof(simd_float3)];
    SCNGeometrySource *colourSource = [SCNGeometrySource geometrySourceWithBuffer:colours vertexFormat:MTLVertexFormatHalf4
        semantic:SCNGeometrySourceSemanticColor vertexCount:count dataOffset:0 dataStride:sizeof(simd_half4)];
    SCNGeometryElement *element = [SCNGeometryElement geometryElementWithData:indices primitiveType:SCNGeometryPrimitiveTypeTriangles
        primitiveCount:indexCount / 3 bytesPerIndex:sizeof(uint32_t)];
    SCNGeometry *geometry = [SCNGeometry geometryWithSources:@[positionSource, colourSource] elements:@[element]];
    geometry.materials = @[[self materialWithLibrary:library vertex:@"skyVertex" fragment:@"skyFragment" params:params additive:NO]];
    _node.geometry = geometry;

    // Point sprites have an angular size in the vertex shader. Their tiny
    // Gaussian fragments stay sharp at every screen size without star textures.
    const unsigned starCount = 150000;
    id<MTLBuffer> stars = [device newBufferWithLength:starCount * sizeof(simd_float3) options:MTLResourceStorageModeShared];
    id<MTLBuffer> starColours = [device newBufferWithLength:starCount * sizeof(simd_half4) options:MTLResourceStorageModeShared];
    simd_float3 *starPositions = stars.contents;
    simd_half4 *starValues = starColours.contents;
    simd_float3 tangent = simd_normalize(simd_cross(normal, simd_make_float3(1, 0, 0)));
    simd_float3 bitangent = simd_cross(normal, tangent);
    for (unsigned i = 0; i < starCount; i++) {
        simd_float3 h = SkyRandom(i, seed);
        simd_float3 random = SkyRandom(i, seed + 100);
        // Match the original three star layers: the faint population gathers
        // along the galactic plane while nearby bright stars fill the sky.
        float planeFraction = i < 5600 ? 0 : i < 37200 ? 0.328f : 0.52f;
        float latitude = h.x * 2 - 1;
        if (h.z < planeFraction)
            latitude = clampf(0.13f * sqrtf(-2 * logf(fmaxf(random.x, 0.000001f))) * cosf(random.z * 2 * M_PI), -1, 1);
        float phi = h.y * 2 * M_PI, radius = sqrtf(MAX(0, 1 - latitude * latitude));
        starPositions[i] = normal * latitude + radius * (tangent * cosf(phi) + bitangent * sinf(phi));
        float t = random.z;
        simd_float3 cool = simd_make_float3(1, 0.62f, 0.38f), mid = simd_make_float3(1, 0.94f, 0.88f), hot = simd_make_float3(0.66f, 0.78f, 1);
        simd_float3 colour = t < 0.55f ? simd_mix(cool, mid, t / 0.55f) : simd_mix(mid, hot, (t - 0.55f) / 0.45f);
        float brightness = (0.015f + powf(random.y, 14)) * (i < 5600 ? 7 : i < 37200 ? 1.6f : 0.6f);
        simd_float4 value = simd_make_float4(colour, brightness);
        starValues[i] = __builtin_convertvector(value, simd_half4);
    }
    SCNGeometrySource *starSource = [SCNGeometrySource geometrySourceWithBuffer:stars vertexFormat:MTLVertexFormatFloat3
        semantic:SCNGeometrySourceSemanticVertex vertexCount:starCount dataOffset:0 dataStride:sizeof(simd_float3)];
    SCNGeometrySource *starColourSource = [SCNGeometrySource geometrySourceWithBuffer:starColours vertexFormat:MTLVertexFormatHalf4
        semantic:SCNGeometrySourceSemanticColor vertexCount:starCount dataOffset:0 dataStride:sizeof(simd_half4)];
    SCNGeometryElement *points = [SCNGeometryElement geometryElementWithData:nil primitiveType:SCNGeometryPrimitiveTypePoint
        primitiveCount:starCount bytesPerIndex:sizeof(uint32_t)];
    SCNGeometry *starGeometry = [SCNGeometry geometryWithSources:@[starSource, starColourSource] elements:@[points]];
    starGeometry.materials = @[[self materialWithLibrary:library vertex:@"starVertex" fragment:@"starFragment" params:params additive:YES]];
    SCNNode *starNode = [SCNNode nodeWithGeometry:starGeometry];
    starNode.categoryBitMask = RenderCategoryBackground;
    starNode.castsShadow = NO;
    starNode.renderingOrder = -999;
    [_node addChildNode:starNode];
    NSLog(@"SpaceSky: %u coloured vertices, %u shader stars, %.1f MiB buffers, no sky textures", count, starCount,
          (directions.length + colours.length + indices.length + stars.length + starColours.length) / 1048576.0);
    return self;
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
    node.categoryBitMask = RenderCategoryBackground;
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
