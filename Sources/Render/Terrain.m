#import "Render.h"

enum { kMaxMapLevels = 10 };

typedef struct {
    simd_float4 camera, sun, fog, misc, trees, map, heights;
    simd_float4 mapOrigin[kMaxMapLevels];
} TerrainParams;

typedef struct {
    simd_int4 origin;       // xy = world texel index of thread (0, 0), z = level, w = texels per edge
    simd_float4 spacing;    // x = metres per texel, y = detail
} BakeParams;

typedef struct {
    simd_float4x4 inverseViewProjection;
} SkyBakeParams;

// A rectangle of one level's texels, in world texel indices, waiting to be baked.
typedef struct {
    int level;
    simd_int2 origin, size;
} Strip;

static const float kFinestSpacing = 4;      // metres between vertices of the innermost ring
enum { kLevels = 8 };                       // 4 m to 512 m spacing; the coarsest ring reaches 32 km
enum { kVariants = 5 };                     // 0: full square; 1-4: rings, hole shifted by (dx, dz)
static const float kMinHeight = -60, kMaxHeight = 2600;
static const float kTreeSpacing = 5;        // metres between tree slots in the innermost tree ring
enum { kTreeLevels = 4 };                   // 5 m to 40 m slots; trees reach about 1.4 km at the default grid
static const float kMapSpacing = 1;         // metres per texel of the finest ground map
enum { kMaxStrips = 2 * kMaxMapLevels };
static const int kSkyScale = 4;             // the sky texture is the drawable over this, each way

static float Snap(float v, float step) { return floorf(v / step) * step; }

static float LinearChannel(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }

static NSUInteger TextureBytes(id<MTLTexture> t) {
    return t ? t.allocatedSize : 0;
}

@implementation ProceduralTerrain {
    int _cells;
    SCNNode *_variants[kLevels][kVariants];
    SCNNode *_treeRings[kTreeLevels];
    int _treeSlots;
    TerrainParams _params;
    NSUInteger _bytes;
    int _finest;

    id<MTLDevice> _device;
    id<MTLComputePipelineState> _groundBake, _skyBake;
    id<MTLTexture> _groundMap, _heightMap, _skyMap;
    SCNMaterial *_skyMaterial;
    int _mapTexels, _mapLevels;
    simd_int2 _mapOrigin[kMaxMapLevels];
    BOOL _mapFilled;
    Strip _strips[kMaxStrips];
    int _stripCount;
    SkyBakeParams _skyParams;
    BOOL _skyReady;
}

+ (id<MTLLibrary>)libraryWithDevice:(id<MTLDevice>)device shaderDirectory:(NSURL *)directory {
    NSMutableString *source = [NSMutableString string];
    for (NSString *name in @[@"TerrainCommon", @"Terrain"]) {
        NSURL *url = [directory URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"metal"]];
        NSString *part = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
        if (!part) { NSLog(@"Terrain: missing %@", url.path); return nil; }
        [source appendFormat:@"%@\n", part];
    }
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) NSLog(@"Terrain: shader compile failed: %@", error);
    return library;
}

// One ring's triangles; with hole, the central n/2 cells shifted by (dx, dz) are left out.
- (SCNGeometryElement *)elementWithHole:(BOOL)hole dx:(int)dx dz:(int)dz {
    int n = _cells, side = n + 1, half = n / 2, quarter = n / 4;
    NSMutableData *data = [NSMutableData dataWithCapacity:(size_t)n * n * 6 * sizeof(uint16_t)];
    for (int cz = -half; cz < half; cz++) {
        for (int cx = -half; cx < half; cx++) {
            if (hole && cx >= -quarter + dx && cx < quarter + dx && cz >= -quarter + dz && cz < quarter + dz) continue;
            uint16_t a = (uint16_t)((cz + half) * side + (cx + half)), b = a + 1, c = a + side, d = c + 1;
            uint16_t tris[6] = { a, c, b, b, c, d };       // counter-clockwise seen from above
            [data appendBytes:tris length:sizeof(tris)];
        }
    }
    _bytes += data.length;
    return [SCNGeometryElement geometryElementWithData:data primitiveType:SCNGeometryPrimitiveTypeTriangles
                                        primitiveCount:data.length / (3 * sizeof(uint16_t)) bytesPerIndex:sizeof(uint16_t)];
}

- (SCNMaterial *)materialWithLibrary:(id<MTLLibrary>)library vertex:(NSString *)vertex fragment:(NSString *)fragment {
    SCNProgram *program = [SCNProgram new];
    program.library = library;
    program.vertexFunctionName = vertex;
    program.fragmentFunctionName = fragment;
    program.opaque = YES;
    __weak ProceduralTerrain *weakSelf = self;
    [program handleBindingOfBufferNamed:@"T" frequency:SCNBufferFrequencyPerFrame
                            usingBlock:^(id<SCNBufferStream> stream, SCNNode *node, id<SCNShadable> shadable, SCNRenderer *renderer) {
        ProceduralTerrain *terrain = weakSelf;
        if (terrain) [stream writeBytes:&terrain->_params length:sizeof(TerrainParams)];
    }];
    SCNMaterial *material = [SCNMaterial material];
    material.program = program;
    // SceneKit binds textures to the shader arguments of the same names.
    [material setValue:[SCNMaterialProperty materialPropertyWithContents:_groundMap] forKey:@"groundMap"];
    [material setValue:[SCNMaterialProperty materialPropertyWithContents:_heightMap] forKey:@"heightMap"];
    return material;
}

// The ground maps: one window per level, each twice the spacing of the last, enough of
// them that the coarsest covers the coarsest ring.
- (void)makeMapsWithLibrary:(id<MTLLibrary>)library texels:(NSUInteger)texels {
    _device = library.device;
    int t = 256;
    while (t < (int)texels && t < 2048) t *= 2;     // the torus needs a power of two
    _mapTexels = t;
    float reach = _cells / 2.0f * kFinestSpacing * (1 << (kLevels - 1));
    _mapLevels = (int)MIN(kMaxMapLevels, 1 + ceilf(log2f(reach / (_mapTexels / 2.0f * kMapSpacing))));
    NSError *error = nil;
    _groundBake = [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"groundBake"] error:&error];
    _skyBake = _groundBake ? [_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"skyBake"] error:&error] : nil;
    if (!_skyBake) { NSLog(@"Terrain: bake pipeline failed: %@", error); return; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                                                width:_mapTexels height:_mapTexels mipmapped:NO];
    d.textureType = MTLTextureType2DArray;
    d.arrayLength = _mapLevels;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    _groundMap = [_device newTextureWithDescriptor:d];
    _groundMap.label = @"Terrain ground map";
    d.pixelFormat = MTLPixelFormatRG16Unorm;
    _heightMap = [_device newTextureWithDescriptor:d];
    _heightMap.label = @"Terrain height map";
    _params.map = simd_make_float4(_mapTexels, _mapLevels, kMapSpacing, 0);
    _params.heights = simd_make_float4(kMinHeight, kMaxHeight - kMinHeight, 0, 0);
}

- (instancetype)initWithLibrary:(id<MTLLibrary>)library cells:(NSUInteger)cells treeCells:(NSUInteger)treeCells
                       mapTexels:(NSUInteger)mapTexels hdr:(BOOL)hdr {
    if (!(self = [super init])) return nil;
    _cells = (int)MAX(16, MIN(252, cells & ~(NSUInteger)3));   // multiples of 4 keep the hole on the coarser grid
    _finest = -1;
    _sunDirection = simd_normalize(simd_make_float3(-0.4f, 0.7f, -0.5f));
    _params.misc = simd_make_float4(12000, _cells / 2.0f, hdr ? 1 : 0, TARGET_OS_IOS ? 8 : 12);
    _node = [SCNNode node];
    _node.name = @"Terrain";
    _treeSlots = (int)MIN(256, treeCells & ~(NSUInteger)1);
    _params.trees = simd_make_float4(_treeSlots / 2.0f, kTreeSpacing, _treeSlots / 2.0f * kTreeSpacing * (1 << (kTreeLevels - 1)), 0);
    _skyNode = [SCNNode node];
    _skyNode.name = @"Terrain sky";
    _skyNode.categoryBitMask = RenderCategoryBackground;
    if (!library) return self;
    [self makeMapsWithLibrary:library texels:mapTexels];
    if (!_heightMap) return self;

    // The grid is the only vertex data; the shader reads the ring's place and spacing from
    // its node transform. Two corners carry the height range so culling boxes cover hills.
    int n = _cells, side = n + 1;
    NSMutableData *vertices = [NSMutableData dataWithLength:(size_t)side * side * sizeof(simd_float3)];
    simd_float3 *v = vertices.mutableBytes;
    for (int z = 0; z < side; z++)
        for (int x = 0; x < side; x++)
            v[z * side + x] = simd_make_float3(x - n / 2, 0, z - n / 2);
    v[0].y = kMinHeight;
    v[side * side - 1].y = kMaxHeight;
    _bytes = vertices.length;
    SCNGeometrySource *positions = [SCNGeometrySource geometrySourceWithData:vertices semantic:SCNGeometrySourceSemanticVertex
                                                                 vectorCount:side * side floatComponents:YES componentsPerVector:3
                                                           bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(simd_float3)];
    SCNMaterial *material = [self materialWithLibrary:library vertex:@"terrainVertex" fragment:@"terrainFragment"];
    SCNGeometry *geometries[kVariants];
    for (int i = 0; i < kVariants; i++) {
        SCNGeometryElement *element = i == 0 ? [self elementWithHole:NO dx:0 dz:0]
                                             : [self elementWithHole:YES dx:(i - 1) & 1 dz:(i - 1) >> 1];
        geometries[i] = [SCNGeometry geometryWithSources:@[positions] elements:@[element]];
        geometries[i].materials = @[material];
    }
    for (int level = 0; level < kLevels; level++) {
        SCNNode *ring = [SCNNode node];
        ring.name = [NSString stringWithFormat:@"Ring %d", level];
        for (int i = 0; i < kVariants; i++) {
            SCNNode *part = [SCNNode nodeWithGeometry:geometries[i]];
            part.hidden = YES;
            part.castsShadow = NO;
            part.categoryBitMask = RenderCategoryBackground;   // the undisplaced grid must not answer hit tests
            [ring addChildNode:part];
            _variants[level][i] = part;
        }
        [_node addChildNode:ring];
    }

    if (_treeSlots > 0) [self addTreesWithLibrary:library];

    // The dome is a unit cube around the camera; its fragment shader only needs directions.
    static const simd_float3 corners[8] = {
        { -1, -1, -1 }, { 1, -1, -1 }, { -1, 1, -1 }, { 1, 1, -1 }, { -1, -1, 1 }, { 1, -1, 1 }, { -1, 1, 1 }, { 1, 1, 1 } };
    static const uint16_t faces[36] = { 0, 2, 1, 1, 2, 3,  4, 5, 6, 5, 7, 6,  0, 4, 2, 2, 4, 6,
                                        1, 3, 5, 3, 7, 5,  0, 1, 4, 1, 5, 4,  2, 6, 3, 3, 6, 7 };
    SCNGeometrySource *cube = [SCNGeometrySource geometrySourceWithData:[NSData dataWithBytes:corners length:sizeof(corners)]
        semantic:SCNGeometrySourceSemanticVertex vectorCount:8 floatComponents:YES componentsPerVector:3
        bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(simd_float3)];
    SCNGeometryElement *cubeFaces = [SCNGeometryElement geometryElementWithData:[NSData dataWithBytes:faces length:sizeof(faces)]
        primitiveType:SCNGeometryPrimitiveTypeTriangles primitiveCount:12 bytesPerIndex:sizeof(uint16_t)];
    SCNGeometry *dome = [SCNGeometry geometryWithSources:@[cube] elements:@[cubeFaces]];
    _skyMaterial = [self materialWithLibrary:library vertex:@"terrainSkyVertex" fragment:@"terrainSkyFragment"];
    _skyMaterial.doubleSided = YES;
    _skyMaterial.readsFromDepthBuffer = NO;
    _skyMaterial.writesToDepthBuffer = NO;
    dome.materials = @[_skyMaterial];
    _skyNode.geometry = dome;
    _skyNode.categoryBitMask = RenderCategoryBackground;
    _skyNode.castsShadow = NO;
    _skyNode.renderingOrder = -1000;
    return self;
}

// One shared grid of tree slots, five vertices each (top, three corners, bottom, all at the
// slot's indices; the shader places them), drawn by every tree ring. Indices are 32-bit:
// a ring of 256 slots per edge has over 300 000 vertices. Two unindexed vertices
// carry the height range so culling boxes cover hills and trees.
- (void)addTreesWithLibrary:(id<MTLLibrary>)library {
    int n = _treeSlots, half = n / 2, count = n * n * 5 + 2;
    NSMutableData *vertices = [NSMutableData dataWithLength:(size_t)count * sizeof(simd_float3)];
    NSMutableData *indices = [NSMutableData dataWithCapacity:(size_t)n * n * 18 * sizeof(uint32_t)];
    simd_float3 *v = vertices.mutableBytes;
    for (int z = 0; z < n; z++) {
        for (int x = 0; x < n; x++) {
            uint32_t f = (uint32_t)((z * n + x) * 5);
            for (int corner = 0; corner < 5; corner++) v[f + corner] = simd_make_float3(x - half, corner, z - half);
            uint32_t tris[18] = { f, f + 1, f + 2,  f, f + 2, f + 3,  f, f + 3, f + 1,
                                  f + 4, f + 2, f + 1,  f + 4, f + 3, f + 2,  f + 4, f + 1, f + 3 };
            [indices appendBytes:tris length:sizeof(tris)];
        }
    }
    v[count - 2] = simd_make_float3(-half, kMinHeight, -half);
    v[count - 1] = simd_make_float3(half, kMaxHeight, half);
    _bytes += vertices.length + indices.length;
    SCNGeometrySource *positions = [SCNGeometrySource geometrySourceWithData:vertices semantic:SCNGeometrySourceSemanticVertex
                                                                 vectorCount:count floatComponents:YES componentsPerVector:3
                                                           bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(simd_float3)];
    SCNGeometryElement *element = [SCNGeometryElement geometryElementWithData:indices primitiveType:SCNGeometryPrimitiveTypeTriangles
                                                               primitiveCount:n * n * 6 bytesPerIndex:sizeof(uint32_t)];
    SCNGeometry *geometry = [SCNGeometry geometryWithSources:@[positions] elements:@[element]];
    SCNMaterial *material = [self materialWithLibrary:library vertex:@"treeVertex" fragment:@"treeFragment"];
    geometry.materials = @[material];
    for (int level = 0; level < kTreeLevels; level++) {
        SCNNode *ring = [SCNNode nodeWithGeometry:geometry];
        ring.name = [NSString stringWithFormat:@"Trees %d", level];
        ring.castsShadow = NO;
        ring.categoryBitMask = RenderCategoryBackground;
        [_node addChildNode:ring];
        _treeRings[level] = ring;
    }
}

- (void)setEnvironment:(LevelEnvironment)environment {
    _environment = environment;
    _params.fog = simd_make_float4(LinearChannel(environment.fogColor.x), LinearChannel(environment.fogColor.y),
                                   LinearChannel(environment.fogColor.z), environment.fogStart);
    _params.misc.x = environment.fogEnd;
}

- (void)setSunDirection:(simd_float3)sunDirection {
    _sunDirection = sunDirection;
    _mapFilled = NO;    // the maps hold the sun's light
}

- (void)addStrip:(int)level origin:(simd_int2)origin size:(simd_int2)size {
    if (size.x <= 0 || size.y <= 0 || _stripCount >= kMaxStrips) return;
    _strips[_stripCount++] = (Strip){ level, origin, size };
}

// Moves each level's window to the camera and queues the texels that scrolled in: a
// column band and a row band, or the whole window after a jump.
- (void)scrollMapsToCamera:(simd_float3)position {
    int n = _mapTexels;
    for (int level = 0; level < _mapLevels; level++) {
        float spacing = kMapSpacing * (1 << level);
        simd_int2 origin = simd_make_int2((int)floorf(position.x / spacing) - n / 2, (int)floorf(position.z / spacing) - n / 2);
        simd_int2 shift = origin - _mapOrigin[level];
        _mapOrigin[level] = origin;
        _params.mapOrigin[level] = simd_make_float4(origin.x, origin.y, 0, 0);
        if (!_mapFilled || abs(shift.x) >= n || abs(shift.y) >= n) {
            [self addStrip:level origin:origin size:simd_make_int2(n, n)];
            continue;
        }
        if (shift.x > 0) [self addStrip:level origin:simd_make_int2(origin.x + n - shift.x, origin.y) size:simd_make_int2(shift.x, n)];
        if (shift.x < 0) [self addStrip:level origin:origin size:simd_make_int2(-shift.x, n)];
        if (shift.y > 0) [self addStrip:level origin:simd_make_int2(origin.x, origin.y + n - shift.y) size:simd_make_int2(n, shift.y)];
        if (shift.y < 0) [self addStrip:level origin:origin size:simd_make_int2(n, -shift.y)];
    }
    _mapFilled = YES;
}

- (void)updateForCamera:(SCNNode *)camera viewport:(CGSize)viewport time:(double)time {
    simd_float3 position = camera.simdWorldPosition;
    _params.camera = simd_make_float4(position, (float)fmod(time, 3600.0));
    _params.sun = simd_make_float4(simd_normalize(_sunDirection), 0);
    _skyNode.simdPosition = position;

    // Rings finer than about half the camera's height only add sub-pixel triangles
    // (Asirvatham and Hoppe), so the finest shown ring is drawn as a full square.
    float height = MAX(position.y, 60.0f);
    int finest = kLevels - 1;
    for (int level = 0; level < kLevels; level++) {
        if (_cells * kFinestSpacing * (1 << level) >= 2.2f * height) { finest = level; break; }
    }
    simd_float2 previous = 0;
    for (int level = 0; level < kLevels; level++) {
        float spacing = kFinestSpacing * (1 << level);
        // Origins sit on the next ring's grid, so this ring's even vertices are its vertices.
        simd_float2 origin = simd_make_float2(Snap(position.x, 2 * spacing), Snap(position.z, 2 * spacing));
        SCNNode *ring = _variants[level][0].parentNode;
        ring.simdPosition = simd_make_float3(origin.x, 0, origin.y);
        ring.simdScale = simd_make_float3(spacing, 1, spacing);
        int variant = -1;
        if (level == finest) variant = 0;
        else if (level > finest) {
            // The finer ring sits 0 or 1 of our cells off centre; the hole follows it.
            simd_float2 shift = (previous - origin) / spacing;
            variant = 1 + (int)lrintf(shift.x) + 2 * (int)lrintf(shift.y);
        }
        for (int i = 0; i < kVariants; i++) _variants[level][i].hidden = i != variant;
        previous = origin;
    }
    _finest = finest;

    // Each tree ring sits on its own slot grid, which the shader repeats to find the hole.
    for (int level = 0; level < kTreeLevels; level++) {
        float spacing = kTreeSpacing * (1 << level);
        _treeRings[level].simdPosition = simd_make_float3(Snap(position.x, spacing), 0, Snap(position.z, spacing));
        _treeRings[level].simdScale = simd_make_float3(spacing, 1, spacing);
    }
    if (!_heightMap) return;
    [self scrollMapsToCamera:position];

    // The sky is marched for this frame's view into a texture a quarter of the drawable.
    NSUInteger width = MAX(16, (NSUInteger)ceil(viewport.width / kSkyScale)), heightPx = MAX(16, (NSUInteger)ceil(viewport.height / kSkyScale));
    if (!_skyMap || _skyMap.width != width || _skyMap.height != heightPx) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                    width:width height:heightPx mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        d.storageMode = MTLStorageModePrivate;
        _skyMap = [_device newTextureWithDescriptor:d];
        _skyMap.label = @"Terrain sky";
        [_skyMaterial setValue:[SCNMaterialProperty materialPropertyWithContents:_skyMap] forKey:@"skyMap"];
    }
    simd_float4x4 projection = SCNMatrix4ToMat4([camera.camera projectionTransformWithViewportSize:viewport]);
    _skyParams.inverseViewProjection = simd_inverse(simd_mul(projection, simd_inverse(camera.simdWorldTransform)));
    _skyReady = YES;
}

- (void)bakeWithQueue:(id<MTLCommandQueue>)queue {
    if (!_heightMap || !_skyReady) return;
    TerrainParams params = _params;
    for (int i = 0; i < _stripCount; i++) {
        // A command buffer per strip keeps a whole level's first fill short of the GPU watchdog.
        Strip s = _strips[i];
        BakeParams b = { simd_make_int4(s.origin.x, s.origin.y, s.level, _mapTexels),
                         simd_make_float4(kMapSpacing * (1 << s.level), MAX(0.0f, 1.0f - 0.5f * s.level), 0, 0) };
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        cb.label = @"Terrain ground bake";
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:_groundBake];
        [enc setTexture:_groundMap atIndex:0];
        [enc setTexture:_heightMap atIndex:1];
        [enc setBytes:&params length:sizeof(params) atIndex:0];
        [enc setBytes:&b length:sizeof(b) atIndex:1];
        [enc dispatchThreads:MTLSizeMake(s.size.x, s.size.y, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [enc endEncoding];
        [cb commit];
    }
    _stripCount = 0;

    id<MTLCommandBuffer> cb = [queue commandBuffer];
    cb.label = @"Terrain sky bake";
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:_skyBake];
    [enc setTexture:_skyMap atIndex:0];
    [enc setBytes:&params length:sizeof(params) atIndex:0];
    [enc setBytes:&_skyParams length:sizeof(_skyParams) atIndex:1];
    [enc dispatchThreads:MTLSizeMake(_skyMap.width, _skyMap.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [enc endEncoding];
    [cb commit];
}

- (NSString *)stats {
    NSUInteger textures = TextureBytes(_groundMap) + TextureBytes(_heightMap) + TextureBytes(_skyMap);
    return [NSString stringWithFormat:@"Terrain: %d rings of %d cells, finest ring %d, %d tree rings of %d slots, %.2f MiB grid and index data; "
            @"%d ground map levels of %d texels (%g m per texel and up), sky %lux%lu, %.1f MiB of textures",
            kLevels, _cells, _finest, kTreeLevels, _treeSlots, _bytes / 1048576.0,
            _mapLevels, _mapTexels, kMapSpacing, (unsigned long)_skyMap.width, (unsigned long)_skyMap.height, textures / 1048576.0];
}

@end
