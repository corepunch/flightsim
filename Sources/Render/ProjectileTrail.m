#import "Render.h"

enum { TrailSamples = 128 };
static const double TrailLife = 2.0;

typedef struct {
    simd_float3 origin;
    double time;
} TrailPoint;

@implementation ProjectileTrail {
    SCNNode *_node;
    SCNMaterial *_material;
    TrailPoint _points[TrailSamples];
    NSUInteger _count;
    float _size;
}

- (instancetype)initWithParent:(SCNNode *)parent size:(float)size {
    if ((self = [super init])) {
        _size = fmaxf(size, 1);
        _node = [SCNNode node];
        _node.castsShadow = NO;
        _material = [SCNMaterial material];
        _material.lightingModelName = SCNLightingModelConstant;
        _material.blendMode = SCNBlendModeAdd;
        _material.writesToDepthBuffer = NO;
        _material.doubleSided = YES;
        _material.shaderModifiers = @{
            SCNShaderModifierEntryPointGeometry:
            @"#pragma varyings\n"
             "float2 trailUV;\n"
             "#pragma body\n"
             "out.trailUV = _geometry.texcoords[0];\n",
            SCNShaderModifierEntryPointFragment:
            @"#pragma transparent\n"
             "#pragma body\n"
             "float2 uv = in.trailUV;\n"
             "float age = saturate(uv.y);\n"
             "float across = abs(uv.x * 2.0 - 1.0);\n"
             "float edge = pow(max(1.0 - across * across, 0.0), 2.0);\n"
             "float fade = pow(1.0 - age, 1.5);\n"
             "float3 smoke = mix(float3(1.0, 0.88, 0.68), float3(0.62, 0.68, 0.76), saturate(age * 3.0));\n"
             "_output.color = float4(smoke * edge * fade * 0.12, 1.0);\n" };
        [parent addChildNode:_node];
    }
    return self;
}

- (void)addOrigin:(simd_float3)origin time:(double)time {
    if (_count) {
        TrailPoint last = _points[_count - 1];
        // Pausing must not fill the history with duplicate points; a new
        // snapshot after a teleport must not draw a ribbon across the level.
        if (time < last.time || simd_distance(origin, last.origin) > 1000) _count = 0;
        else if (time - last.time < 1.0 / 60.0 || simd_distance(origin, last.origin) < 0.25f) return;
    }
    if (_count == TrailSamples) {
        memmove(_points, _points + 1, sizeof(TrailPoint) * (TrailSamples - 1));
        _count--;
    }
    _points[_count++] = (TrailPoint){ origin, time };
}

- (BOOL)drawAtTime:(double)time camera:(simd_float3)camera {
    NSUInteger expired = 0;
    while (expired < _count && time - _points[expired].time >= TrailLife) expired++;
    if (expired) {
        _count -= expired;
        memmove(_points, _points + expired, sizeof(TrailPoint) * _count);
    }
    if (!_count) { [_node removeFromParentNode]; return NO; }
    if (_count < 2) { _node.geometry = nil; return YES; }

    simd_float3 vertices[TrailSamples * 2];
    simd_float2 uv[TrailSamples * 2];
    uint16_t indices[TrailSamples * 2];
    simd_float3 previousSide = simd_make_float3(1, 0, 0);
    for (NSUInteger i = 0; i < _count; i++) {
        TrailPoint point = _points[i];
        float age = fminf(fmaxf((time - point.time) / TrailLife, 0), 1);
        simd_float3 tangent = _points[MIN(i + 1, _count - 1)].origin - _points[i ? i - 1 : 0].origin;
        simd_float3 side = simd_cross(tangent, camera - point.origin);
        if (simd_length_squared(side) > 0.0001f) side = simd_normalize(side);
        else side = previousSide;
        if (simd_dot(side, previousSide) < 0) side = -side;
        previousSide = side;
        simd_float3 halfWidth = side * _size * (0.025f + age * 0.18f);
        vertices[i * 2] = point.origin - halfWidth;
        vertices[i * 2 + 1] = point.origin + halfWidth;
        float fade = i ? age : 1;
        uv[i * 2] = simd_make_float2(0, fade);
        uv[i * 2 + 1] = simd_make_float2(1, fade);
        indices[i * 2] = (uint16_t)(i * 2);
        indices[i * 2 + 1] = (uint16_t)(i * 2 + 1);
    }
    NSUInteger count = _count * 2;
    SCNGeometrySource *positions = [SCNGeometrySource geometrySourceWithData:[NSData dataWithBytes:vertices length:count * sizeof(*vertices)]
        semantic:SCNGeometrySourceSemanticVertex vectorCount:count floatComponents:YES componentsPerVector:3
        bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(*vertices)];
    SCNGeometrySource *texcoords = [SCNGeometrySource geometrySourceWithData:[NSData dataWithBytes:uv length:count * sizeof(*uv)]
        semantic:SCNGeometrySourceSemanticTexcoord vectorCount:count floatComponents:YES componentsPerVector:2
        bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(*uv)];
    SCNGeometryElement *strip = [SCNGeometryElement geometryElementWithData:[NSData dataWithBytes:indices length:count * sizeof(*indices)]
        primitiveType:SCNGeometryPrimitiveTypeTriangleStrip primitiveCount:count - 2 bytesPerIndex:sizeof(*indices)];
    SCNGeometry *geometry = [SCNGeometry geometryWithSources:@[positions, texcoords] elements:@[strip]];
    geometry.firstMaterial = _material;
    _node.geometry = geometry;
    return YES;
}

@end
