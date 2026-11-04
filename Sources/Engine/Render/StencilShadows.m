#import "StencilShadows.h"
#import <simd/simd.h>

enum { kMaxLights = 12, kMasks = kMaxLights / 4 };   // four lights per RGBA mask
static const uint32_t kFar = 0x80000000u;   // index flag: the vertex extruded past the light's reach

typedef struct { simd_float4 position; simd_float4 color; } LightDesc;   // world pos + reach; linear rgb * scale

typedef struct {
    simd_float4x4 viewProj;
    simd_float4 light;     // xyz world position
    simd_float4 push;      // x + y * distance: how far near-cap vertices move away from the light
} VolumeUniforms;

static NSString *const kShaders = @R"(
#include <metal_stdlib>
using namespace metal;
struct VolumeUniforms { float4x4 viewProj; float4 light; float4 push; };

vertex float4 depth_vs(uint vid [[vertex_id]], const device float4 *pos [[buffer(0)]],
                       constant float4x4 &viewProj [[buffer(1)]]) {
    return viewProj * float4(pos[vid].xyz, 1);
}

vertex float4 volume_vs(uint vid [[vertex_id]], const device float4 *pos [[buffer(0)]],
                        constant VolumeUniforms &u [[buffer(1)]]) {
    float3 p = pos[vid & 0x7fffffffu].xyz;
    float3 d = p - u.light.xyz;
    float len = max(length(d), 1e-4);
    // Far vertices go out just past the light's reach (1.25 times: a far cap
    // spanning up to 70 degrees still clears it; wider ones are next to the
    // light, where they're skipped): no light, no shadow beyond.
    if (vid & 0x80000000u) return u.viewProj * float4(u.light.xyz + d / len * u.push.z, 1);
    return u.viewProj * float4(p + d / len * (u.push.x + u.push.y * len), 1);
}

vertex float4 quad_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    return float4(p * 2 - 1, 0, 1);
}

fragment float4 zero_fs() { return float4(0); }
)";

#pragma mark - Geometry

// Welded world-space triangles (with the material-skip already applied).
typedef struct { uint32_t a, b, c; } Tri;

@interface ShadowMesh : NSObject {
@public
    NSMutableData *verts;     // simd_float4
    NSMutableData *tris;      // Tri
    NSMutableDictionary<NSValue *, NSNumber *> *weld;
}
@end
@implementation ShadowMesh
- (instancetype)init {
    if ((self = [super init])) {
        verts = [NSMutableData data];
        tris = [NSMutableData data];
        weld = [NSMutableDictionary dictionary];
    }
    return self;
}
- (uint32_t)vertex:(simd_float3)p {
    // Weld on a 0.1 mm grid so separate faces of one piece share edges.
    int32_t key[3] = { (int32_t)lrintf(p.x * 1e4f), (int32_t)lrintf(p.y * 1e4f), (int32_t)lrintf(p.z * 1e4f) };
    NSValue *k = [NSValue valueWithBytes:key objCType:@encode(int32_t[3])];
    NSNumber *i = weld[k];
    if (i) return i.unsignedIntValue;
    uint32_t n = (uint32_t)(verts.length / sizeof(simd_float4));
    simd_float4 v = simd_make_float4(p, 1);
    [verts appendBytes:&v length:sizeof v];
    weld[k] = @(n);
    return n;
}
- (uint32_t)triCount { return (uint32_t)(tris.length / sizeof(Tri)); }
- (uint32_t)vertCount { return (uint32_t)(verts.length / sizeof(simd_float4)); }
@end

static BOOL Skipped(NSString *name, NSArray<NSString *> *prefixes) {
    for (NSString *p in prefixes) if ([name hasPrefix:p]) return YES;
    return NO;
}

static void Collect(SCNNode *root, NSArray<NSString *> *skip, ShadowMesh *mesh) {
    [root enumerateHierarchyUsingBlock:^(SCNNode *node, BOOL *stop) {
        SCNGeometry *g = node.geometry;
        if (!g || node.hidden) return;
        SCNGeometrySource *src = [g geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
        if (!src || !src.floatComponents || src.bytesPerComponent != 4) return;
        simd_float4x4 m = node.simdWorldTransform;
        const uint8_t *bytes = (const uint8_t *)src.data.bytes + src.dataOffset;
        NSInteger nv = src.vectorCount;
        uint32_t *remap = malloc(sizeof(uint32_t) * (size_t)MAX(nv, 1));
        for (NSInteger i = 0; i < nv; i++) {
            const float *f = (const float *)(bytes + i * src.dataStride);
            simd_float4 w = simd_mul(m, simd_make_float4(f[0], f[1], f[2], 1));
            remap[i] = [mesh vertex:w.xyz];
        }
        NSArray<SCNMaterial *> *mats = g.materials;
        for (NSInteger e = 0; e < g.geometryElementCount; e++) {
            SCNGeometryElement *el = [g geometryElementAtIndex:e];
            NSString *mname = mats.count ? (mats[(NSUInteger)e % mats.count].name ?: @"") : @"";
            if (Skipped(mname, skip) || el.primitiveType != SCNGeometryPrimitiveTypeTriangles) continue;
            const uint8_t *ib = el.data.bytes;
            NSInteger bpi = el.bytesPerIndex;
            for (NSInteger t = 0; t < el.primitiveCount; t++) {
                uint32_t idx[3];
                for (int k = 0; k < 3; k++) {
                    const uint8_t *p = ib + (t * 3 + k) * bpi;
                    idx[k] = bpi == 2 ? *(const uint16_t *)p : bpi == 1 ? *p : *(const uint32_t *)p;
                }
                if (idx[0] >= nv || idx[1] >= nv || idx[2] >= nv) continue;
                Tri tri = { remap[idx[0]], remap[idx[1]], remap[idx[2]] };
                if (tri.a == tri.b || tri.b == tri.c || tri.a == tri.c) continue;
                [mesh->tris appendBytes:&tri length:sizeof tri];
            }
        }
        free(remap);
    }];
}

#pragma mark - Directed edge counts

// Open addressing: key a<<32|b (a<b), value = net count of a->b minus b->a.
typedef struct { uint64_t *keys; int32_t *vals; size_t cap; } EdgeTable;

static void EdgesInit(EdgeTable *t, size_t n) {
    size_t cap = 1024;
    while (cap < n * 2) cap <<= 1;
    t->cap = cap;
    t->keys = malloc(cap * sizeof(uint64_t));
    memset(t->keys, 0xff, cap * sizeof(uint64_t));
    t->vals = calloc(cap, sizeof(int32_t));
}
static void EdgesFree(EdgeTable *t) { free(t->keys); free(t->vals); }
static void EdgesAdd(EdgeTable *t, uint32_t a, uint32_t b) {
    int32_t s = 1;
    if (a > b) { uint32_t x = a; a = b; b = x; s = -1; }
    uint64_t key = ((uint64_t)a << 32) | b;
    size_t h = (size_t)((key * 0x9E3779B97F4A7C15ull) >> 20) & (t->cap - 1);
    while (t->keys[h] != UINT64_MAX && t->keys[h] != key) h = (h + 1) & (t->cap - 1);
    t->keys[h] = key;
    t->vals[h] += s;
}

// Per triangle of a mesh: does its piece (connected through shared
// vertices) close up, every edge met once each way?
static uint8_t *ClosedPieces(ShadowMesh *mesh) {
    uint32_t nt = mesh.triCount, nv = mesh.vertCount;
    const Tri *tris = mesh->tris.bytes;
    uint32_t *parent = malloc(sizeof(uint32_t) * nv);
    for (uint32_t i = 0; i < nv; i++) parent[i] = i;
    uint32_t (^find)(uint32_t) = ^uint32_t(uint32_t x) {
        while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
        return x;
    };
    for (uint32_t i = 0; i < nt; i++) {
        uint32_t r = find(tris[i].a);
        parent[find(tris[i].b)] = r;
        parent[find(tris[i].c)] = find(tris[i].a);
    }
    EdgeTable edges;
    EdgesInit(&edges, (size_t)nt * 3);
    for (uint32_t i = 0; i < nt; i++) {
        EdgesAdd(&edges, tris[i].a, tris[i].b);
        EdgesAdd(&edges, tris[i].b, tris[i].c);
        EdgesAdd(&edges, tris[i].c, tris[i].a);
    }
    uint8_t *openRoot = calloc(nv, 1);
    for (size_t h = 0; h < edges.cap; h++) {
        if (edges.keys[h] == UINT64_MAX || edges.vals[h] == 0) continue;
        openRoot[find((uint32_t)(edges.keys[h] >> 32))] = 1;
    }
    uint8_t *closed = malloc(MAX(nt, 1));
    for (uint32_t i = 0; i < nt; i++) closed[i] = !openRoot[find(tris[i].a)];
    EdgesFree(&edges);
    free(openRoot);
    free(parent);
    return closed;
}

// The volume of one light: a prism from every triangle that casts (turned
// to face the light), sides only where neighbouring prisms don't cancel.
static NSData *BuildVolume(ShadowMesh *mesh, const uint8_t *closed, simd_float3 L, float reach) {
    uint32_t nt = mesh.triCount;
    const Tri *tris = mesh->tris.bytes;
    const simd_float4 *v = mesh->verts.bytes;
    NSMutableData *out = [NSMutableData data];
    EdgeTable edges;
    EdgesInit(&edges, (size_t)nt * 3);
    for (uint32_t i = 0; i < nt; i++) {
        Tri t = tris[i];
        simd_float3 a = v[t.a].xyz, b = v[t.b].xyz, c = v[t.c].xyz;
        simd_float3 n = simd_cross(b - a, c - a);
        float area2 = simd_length(n);
        if (area2 < 1e-10f) continue;
        n /= area2;
        // Out of the light's reach, or so close it would be inside its fixture.
        simd_float3 mid = (a + b + c) / 3;
        float r = fmaxf(simd_distance(mid, a), fmaxf(simd_distance(mid, b), simd_distance(mid, c)));
        float plane = simd_dot(n, L - a);
        if (simd_distance(mid, L) - r > reach || fabsf(plane) < 0.05f) continue;
        if (plane < 0) {
            if (closed[i]) continue;          // the light-facing side of a closed piece covers it
            uint32_t x = t.b; t.b = t.c; t.c = x;
        }
        uint32_t cap[6] = { t.a, t.b, t.c, t.c | kFar, t.b | kFar, t.a | kFar };
        [out appendBytes:cap length:sizeof cap];
        EdgesAdd(&edges, t.a, t.b);
        EdgesAdd(&edges, t.b, t.c);
        EdgesAdd(&edges, t.c, t.a);
    }
    for (size_t h = 0; h < edges.cap; h++) {
        if (edges.keys[h] == UINT64_MAX) continue;
        int32_t net = edges.vals[h];
        uint32_t a = (uint32_t)(edges.keys[h] >> 32), b = (uint32_t)edges.keys[h];
        if (net < 0) { uint32_t x = a; a = b; b = x; net = -net; }
        for (int32_t k = 0; k < net; k++) {   // edge a->b of a prism's top: side b, a, a', b'
            uint32_t side[6] = { b, a, a | kFar, b, a | kFar, b | kFar };
            [out appendBytes:side length:sizeof side];
        }
    }
    EdgesFree(&edges);
    return out;
}

#pragma mark -

@implementation StencilShadows {
    id<MTLDevice> _device;
    ShadowMesh *_receivers, *_casters;
    LightDesc _lights[kMaxLights];
    NSUInteger _nlights;

    id<MTLBuffer> _receiverVerts, _receiverIndex, _casterVerts;
    id<MTLBuffer> _volumes[kMaxLights];
    NSUInteger _receiverCount, _volumeCount[kMaxLights];

    id<MTLRenderPipelineState> _depthPipe, _volumePipe, _maskPipe[kMaxLights];
    id<MTLDepthStencilState> _depthState, _volumeState, _maskState;
    id<MTLCommandQueue> _queue;
    id<MTLTexture> _mask[kMasks], _depth;
    SCNMaterialProperty *_maskProp[kMasks];
    NSMutableArray<SCNMaterial *> *_materials;
    float _resolution;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        _receivers = [ShadowMesh new];
        _casters = [ShadowMesh new];
        _materials = [NSMutableArray array];
        _resolution = getenv("SF_STENCIL_RES") ? (float)atof(getenv("SF_STENCIL_RES")) : 0.5f;
        for (int i = 0; i < kMasks; i++) {
            _maskProp[i] = [SCNMaterialProperty materialPropertyWithContents:[NSColor whiteColor]];
            _maskProp[i].minificationFilter = _maskProp[i].magnificationFilter = SCNFilterModeLinear;
            _maskProp[i].mipFilter = SCNFilterModeNone;
        }
    }
    return self;
}

- (NSUInteger)lightCount { return _nlights; }

- (void)addReceiver:(SCNNode *)node skip:(NSArray<NSString *> *)skip { Collect(node, skip, _receivers); }
- (void)addCaster:(SCNNode *)node skip:(NSArray<NSString *> *)skip { Collect(node, skip, _casters); }

- (void)addLight:(simd_float3)p color:(NSColor *)color intensity:(float)intensity reach:(float)reach {
    if (_nlights >= kMaxLights) { NSLog(@"StencilShadows: more than %d lights", kMaxLights); return; }
    NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
    simd_float3 lin = simd_make_float3(powf((float)c.redComponent, 2.2f), powf((float)c.greenComponent, 2.2f),
                                       powf((float)c.blueComponent, 2.2f));
    // Fitted against SceneKit's own omni lights in the briefing room
    // (SF_STENCIL=0 against SF_STENCIL=lit): within ~10% across the frame.
    _lights[_nlights++] = (LightDesc){ simd_make_float4(p, reach), simd_make_float4(lin * (intensity * 0.42f), 0) };
}

- (void)finish {
    CFTimeInterval t0 = CACurrentMediaTime();
    _receiverVerts = [_device newBufferWithBytes:_receivers->verts.bytes length:MAX(_receivers->verts.length, 16)
                                         options:MTLResourceStorageModeShared];
    _receiverIndex = [_device newBufferWithBytes:_receivers->tris.bytes length:MAX(_receivers->tris.length, 16)
                                         options:MTLResourceStorageModeShared];
    _receiverCount = _receivers.triCount * 3;
    _casterVerts = [_device newBufferWithBytes:_casters->verts.bytes length:MAX(_casters->verts.length, 16)
                                       options:MTLResourceStorageModeShared];
    uint8_t *closed = ClosedPieces(_casters);
    size_t total = 0;
    for (NSUInteger i = 0; i < _nlights; i++) {
        NSData *idx = BuildVolume(_casters, closed, _lights[i].position.xyz, _lights[i].position.w);
        _volumes[i] = [_device newBufferWithBytes:idx.bytes length:MAX(idx.length, 16) options:MTLResourceStorageModeShared];
        _volumeCount[i] = idx.length / sizeof(uint32_t);
        total += _volumeCount[i] / 3;
    }
    free(closed);
    NSLog(@"StencilShadows: %u receiver and %u caster triangles, %zu volume triangles for %lu lights in %.0f ms",
          _receivers.triCount, _casters.triCount, total, (unsigned long)_nlights, (CACurrentMediaTime() - t0) * 1000);
    _receivers = _casters = nil;
    [self buildPipelines];
}

- (void)buildPipelines {
    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithSource:kShaders options:nil error:&err];
    if (!lib) { NSLog(@"StencilShadows: %@", err); return; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    for (int k = 0; k < kMasks; k++) pd.colorAttachments[k].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    for (int k = 0; k < kMasks; k++) pd.colorAttachments[k].writeMask = MTLColorWriteMaskNone;
    pd.fragmentFunction = nil;
    pd.vertexFunction = [lib newFunctionWithName:@"depth_vs"];
    _depthPipe = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    pd.vertexFunction = [lib newFunctionWithName:@"volume_vs"];
    _volumePipe = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    pd.vertexFunction = [lib newFunctionWithName:@"quad_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"zero_fs"];
    static const MTLColorWriteMask channel[4] = { MTLColorWriteMaskRed, MTLColorWriteMaskGreen,
                                                  MTLColorWriteMaskBlue, MTLColorWriteMaskAlpha };
    for (int i = 0; i < kMaxLights; i++) {
        for (int k = 0; k < kMasks; k++) pd.colorAttachments[k].writeMask = k == i / 4 ? channel[i % 4] : MTLColorWriteMaskNone;
        _maskPipe[i] = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    }
    if (err) NSLog(@"StencilShadows: %@", err);

    // Reversed, infinite depth: 1 at the near plane, 0 at infinity.
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionGreater;
    dd.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:dd];

    // Z-fail (Carmack's reverse): count the volume's faces behind the surface.
    dd.depthWriteEnabled = NO;
    MTLStencilDescriptor *front = [MTLStencilDescriptor new], *back = [MTLStencilDescriptor new];
    front.stencilCompareFunction = back.stencilCompareFunction = MTLCompareFunctionAlways;
    front.depthFailureOperation = MTLStencilOperationDecrementWrap;
    back.depthFailureOperation = MTLStencilOperationIncrementWrap;
    dd.frontFaceStencil = front;
    dd.backFaceStencil = back;
    _volumeState = [_device newDepthStencilStateWithDescriptor:dd];

    // Where the count isn't 0: shadow; and put the stencil back to 0 for the next light.
    MTLStencilDescriptor *mask = [MTLStencilDescriptor new];
    mask.stencilCompareFunction = MTLCompareFunctionNotEqual;
    mask.depthStencilPassOperation = MTLStencilOperationZero;
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.frontFaceStencil = dd.backFaceStencil = mask;
    _maskState = [_device newDepthStencilStateWithDescriptor:dd];
}

#pragma mark - Materials

- (void)applyToMaterial:(SCNMaterial *)m tint:(NSColor *)tint {
    NSMutableString *args = [NSMutableString stringWithString:@"#pragma arguments\ntexture2d<float> sl_mask0;\ntexture2d<float> sl_mask1;\ntexture2d<float> sl_mask2;\nfloat4 sl_tint;\n"];
    NSMutableString *table = [NSMutableString string];
    for (NSUInteger i = 0; i < _nlights; i++) {
        [args appendFormat:@"float4 sl_p%lu;\nfloat4 sl_c%lu;\n", i, i];
        [table appendFormat:@"P[%lu] = sl_p%lu; C[%lu] = sl_c%lu;\n", i, i, i, i];
    }
    NSString *body = [NSString stringWithFormat:@
        "#pragma body\n"
        "float4 P[%d]; float4 C[%d];\n%@"
        "float4 clip = scn_frame.projectionTransform * float4(_surface.position, 1);\n"
        "float2 uv = float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);\n"
        "constexpr sampler ms(filter::linear, address::clamp_to_edge);\n"
        "float4 m0 = sl_mask0.sample(ms, uv), m1 = sl_mask1.sample(ms, uv), m2 = sl_mask2.sample(ms, uv);\n"
        "float lit[12] = { m0.r, m0.g, m0.b, m0.a, m1.r, m1.g, m1.b, m1.a, m2.r, m2.g, m2.b, m2.a };\n"
        "float3 N = normalize(_surface.normal), V = normalize(_surface.view);\n"
        "float3 albedo = _surface.diffuse.rgb;\n"
        "float rough = clamp(_surface.roughness, 0.04, 1.0), metal = saturate(_surface.metalness);\n"
        "float a2 = rough * rough * rough * rough, k = (rough + 1) * (rough + 1) / 8;\n"
        "float3 F0 = mix(float3(0.04), albedo, metal);\n"
        "float NdV = max(dot(N, V), 1e-4);\n"
        "float3 sum = float3(0);\n"
        "for (int i = 0; i < %lu; i++) {\n"
        "    if (lit[i] <= 0) continue;\n"
        "    float3 Lv = (scn_frame.viewTransform * float4(P[i].xyz, 1)).xyz - _surface.position;\n"
        "    float d = length(Lv);\n"
        "    float w = saturate(1 - pow(d / P[i].w, 4.0));\n"
        "    float att = w * w / max(d * d, 0.01);   // inverse square, windowed to the reach\n"
        "    float3 L = Lv / max(d, 1e-4);\n"
        "    float NdL = dot(N, L);\n"
        "    if (NdL <= 0 || att <= 0) continue;\n"
        "    float3 H = normalize(L + V);\n"
        "    float NdH = saturate(dot(N, H)), VdH = saturate(dot(V, H));\n"
        "    float dd = NdH * NdH * (a2 - 1) + 1;\n"
        "    float D = a2 / (3.14159265 * dd * dd);\n"
        "    float G = NdL / (NdL * (1 - k) + k) * NdV / (NdV * (1 - k) + k);\n"
        "    float3 F = F0 + (1 - F0) * pow(1 - VdH, 5.0);\n"
        "    float3 spec = D * G * F / (4 * NdL * NdV + 1e-4);\n"
        "    float3 kd = (1 - F) * (1 - metal);\n"
        "    sum += (kd * albedo / 3.14159265 + spec) * C[i].rgb * (NdL * att * lit[i]);\n"
        "}\n"
        "_output.color.rgb += sum * sl_tint.rgb * 3.14159265;\n%@",
        kMaxLights, kMaxLights, table, (unsigned long)_nlights,
        getenv("SF_STENCIL_DEBUG") ? @"_output.color.rgb = float3(lit[0], lit[1], lit[2]) * 0.5 + sum * 0.0001;\n" : @""];
    NSMutableDictionary *mods = [m.shaderModifiers mutableCopy] ?: [NSMutableDictionary dictionary];
    mods[SCNShaderModifierEntryPointFragment] = [args stringByAppendingString:body];
    m.shaderModifiers = mods;
    NSColor *t = [(tint ?: [NSColor whiteColor]) colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    [m setValue:[NSValue valueWithSCNVector4:SCNVector4Make(powf((float)t.redComponent, 2.2f), powf((float)t.greenComponent, 2.2f),
                                                             powf((float)t.blueComponent, 2.2f), 1)] forKey:@"sl_tint"];
    for (NSUInteger i = 0; i < _nlights; i++) {
        simd_float4 p = _lights[i].position, c = _lights[i].color;
        [m setValue:[NSValue valueWithSCNVector4:SCNVector4Make(p.x, p.y, p.z, p.w)] forKey:[NSString stringWithFormat:@"sl_p%lu", i]];
        [m setValue:[NSValue valueWithSCNVector4:SCNVector4Make(c.x, c.y, c.z, 0)] forKey:[NSString stringWithFormat:@"sl_c%lu", i]];
    }
    for (int k = 0; k < kMasks; k++) [m setValue:_maskProp[k] forKey:[NSString stringWithFormat:@"sl_mask%d", k]];
    [_materials addObject:m];
}

#pragma mark - Per frame

- (void)ensureTargets:(CGSize)size {
    NSUInteger w = (NSUInteger)MAX(size.width, 1), h = (NSUInteger)MAX(size.height, 1);
    if (_depth && _depth.width == w && _depth.height == h) return;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    for (int i = 0; i < kMasks; i++) {
        _mask[i] = [_device newTextureWithDescriptor:td];
        _maskProp[i].contents = _mask[i];
    }
    td.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    td.usage = MTLTextureUsageRenderTarget;
    _depth = [_device newTextureWithDescriptor:td];
}

// The screen rectangle the light's sphere of reach covers; NO if none.
static BOOL ScissorFor(simd_float4 light, simd_float4x4 viewProj, float zNear, NSUInteger w, NSUInteger h, MTLScissorRect *out) {
    float x0 = 1, y0 = 1, x1 = -1, y1 = -1;
    for (int k = 0; k < 8; k++) {
        simd_float3 c = light.xyz + light.w * simd_make_float3(k & 1 ? 1 : -1, k & 2 ? 1 : -1, k & 4 ? 1 : -1);
        simd_float4 p = simd_mul(viewProj, simd_make_float4(c, 1));
        if (p.w <= zNear) { x0 = y0 = -1; x1 = y1 = 1; break; }   // reaches behind us: the whole screen
        x0 = fminf(x0, p.x / p.w); x1 = fmaxf(x1, p.x / p.w);
        y0 = fminf(y0, p.y / p.w); y1 = fmaxf(y1, p.y / p.w);
    }
    x0 = fmaxf(x0, -1); y0 = fmaxf(y0, -1); x1 = fminf(x1, 1); y1 = fminf(y1, 1);
    if (x0 >= x1 || y0 >= y1) return NO;
    NSUInteger px0 = (NSUInteger)floorf((x0 * 0.5f + 0.5f) * w), px1 = (NSUInteger)ceilf((x1 * 0.5f + 0.5f) * w);
    NSUInteger py0 = (NSUInteger)floorf((0.5f - y1 * 0.5f) * h), py1 = (NSUInteger)ceilf((0.5f - y0 * 0.5f) * h);
    px1 = MIN(px1, w); py1 = MIN(py1, h);
    if (px1 <= px0 || py1 <= py0) return NO;
    *out = (MTLScissorRect){ px0, py0, px1 - px0, py1 - py0 };
    return YES;
}

- (void)renderWithRenderer:(id<SCNSceneRenderer>)renderer camera:(SCNNode *)cameraNode {
    if (!_depthPipe || !cameraNode.camera) return;
    if (!_queue) _queue = renderer.commandQueue;
    // The volumes' fill is the cost: the mask is half the drawable (one
    // pixel per point on a Retina screen), sampled bilinear.
    CGSize full = renderer.currentViewport.size;
    CGSize size = CGSizeMake(ceil(full.width * _resolution), ceil(full.height * _resolution));
    if (size.width < 1 || size.height < 1) return;
    [self ensureTargets:size];

    // SceneKit's projection for x and y; our own reversed, infinite depth.
    simd_float4x4 proj = SCNMatrix4ToMat4([cameraNode.camera projectionTransformWithViewportSize:full]);
    float n = (float)cameraNode.camera.zNear;
    proj.columns[0][2] = 0; proj.columns[1][2] = 0; proj.columns[2][2] = 0; proj.columns[3][2] = n;
    proj.columns[0][3] = 0; proj.columns[1][3] = 0; proj.columns[2][3] = -1; proj.columns[3][3] = 0;
    simd_float4x4 view = simd_inverse(cameraNode.presentationNode.simdWorldTransform);
    simd_float4x4 viewProj = simd_mul(proj, view);

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    cb.label = @"Stencil shadows";
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (int i = 0; i < kMasks; i++) {
        rp.colorAttachments[i].texture = _mask[i];
        rp.colorAttachments[i].loadAction = MTLLoadActionClear;
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        rp.colorAttachments[i].clearColor = MTLClearColorMake(1, 1, 1, 1);
    }
    rp.depthAttachment.texture = _depth;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    rp.depthAttachment.clearDepth = 0;
    rp.stencilAttachment.texture = _depth;
    rp.stencilAttachment.loadAction = MTLLoadActionClear;
    rp.stencilAttachment.storeAction = MTLStoreActionDontCare;
    rp.stencilAttachment.clearStencil = 0;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    if (!_disabled) {
        [enc setRenderPipelineState:_depthPipe];
        [enc setDepthStencilState:_depthState];
        [enc setCullMode:MTLCullModeNone];
        [enc setVertexBuffer:_receiverVerts offset:0 atIndex:0];
        [enc setVertexBytes:&viewProj length:sizeof viewProj atIndex:1];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_receiverCount indexType:MTLIndexTypeUInt32
                       indexBuffer:_receiverIndex indexBufferOffset:0];
        [enc setDepthClipMode:MTLDepthClipModeClamp];
        for (NSUInteger i = 0; i < _nlights; i++) {
            if (!_volumeCount[i]) continue;
            MTLScissorRect sc;
            if (!ScissorFor(_lights[i].position, viewProj, n, _depth.width, _depth.height, &sc)) continue;
            [enc setScissorRect:sc];
            VolumeUniforms u = { viewProj, _lights[i].position, simd_make_float4(0.01f, 0.002f, 1.25f * _lights[i].position.w, 0) };
            [enc setRenderPipelineState:_volumePipe];
            [enc setDepthStencilState:_volumeState];
            [enc setVertexBuffer:_casterVerts offset:0 atIndex:0];
            [enc setVertexBytes:&u length:sizeof u atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:_volumeCount[i] indexType:MTLIndexTypeUInt32
                           indexBuffer:_volumes[i] indexBufferOffset:0];
            [enc setRenderPipelineState:_maskPipe[i]];
            [enc setDepthStencilState:_maskState];
            [enc setStencilReferenceValue:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
    }
    [enc endEncoding];
    [cb commit];
}

@end
