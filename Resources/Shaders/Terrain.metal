// Geometry-clipmap terrain and sky dome for SceneKit, after Losasso and Hoppe: nested
// rings of one shared grid, each scaled and placed by its node, with the procedural
// surface evaluated per vertex and per pixel. Nothing is stored but the grid, so the
// landscape costs under a megabyte at any size. Hosted by Sources/Render/Terrain.m,
// which prepends TerrainCommon.metal.

// Runtime Metal compilation cannot resolve SDK framework headers on devices.
// These are the public SceneKit frame and node buffer layouts.
enum { SCNVertexSemanticPosition = 0 };
struct SCNSceneBuffer {
    float4x4 viewTransform, inverseViewTransform, projectionTransform;
    float4x4 viewProjectionTransform, viewToCubeTransform, lastFrameViewProjectionTransform;
    float4 ambientLightingColor, fogColor;
    float3 fogParameters;
    float2 inverseResolution;
    float time, sinTime, cosTime, random01, motionBlurIntensity, environmentIntensity;
    float4x4 inverseProjectionTransform, inverseViewProjectionTransform;
    float2 nearFar;
    float4 viewportSize;
};
struct NodeBuffer {
    float4x4 modelTransform, inverseModelTransform, modelViewTransform, inverseModelViewTransform;
    float4x4 normalTransform, modelViewProjectionTransform, inverseModelViewProjectionTransform;
    float2x3 boundingBox, worldBoundingBox;
};

struct TerrainParams {
    float4 camera;      // xyz, w = seconds
    float4 sun;         // xyz toward the sun
    float4 fog;         // rgb display-linear fog colour, w = fog start
    float4 misc;        // x = fog end, y = half grid in cells, z = HDR camera, w = cloud steps
};

// Canopy relief and fine noise fade out where they would be smaller than a pixel.
static float detailAt(float distance) { return 1.0 - smoothstep(1500.0, 3500.0, distance); }

static float3 display(float3 col, bool hdr) { return hdr ? col * 0.45 : tonemap(col); }

// MARK: - Terrain

struct TerrainVertexIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];   // xz grid indices; y only sizes the culling box
};
struct TerrainVarying {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 ground;      // bare height, cavity, canopy height
};

vertex TerrainVarying terrainVertex(TerrainVertexIn in [[stage_in]],
                                    constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                                    constant NodeBuffer &scn_node [[buffer(1)]],
                                    constant TerrainParams &T [[buffer(2)]]) {
    float2 g = in.position.xz;
    float spacing = scn_node.modelTransform[0][0];
    float2 origin = scn_node.modelTransform[3].xz;
    // CDLOD morph: over the outer band odd vertices slide onto their even neighbours, so
    // the rim is exactly the next coarser grid and no seam or T-junction remains.
    float2 rel = abs(g) / T.misc.y;
    float morph = saturate((max(rel.x, rel.y) - 0.70) / 0.28);
    g -= fract(g * 0.5) * 2.0 * morph;
    float2 xz = origin + g * spacing;
    float detail = detailAt(distance(xz, T.camera.xz));
    Surface s = surface(xz, 3, detail, true);
    float e = spacing * 0.5;
    float hx = surface(xz + float2(e, 0.0), 3, detail, true).y;
    float hz = surface(xz + float2(0.0, e), 3, detail, true).y;
    TerrainVarying out;
    out.world = float3(xz.x, s.y, xz.y);
    out.normal = normalize(float3(s.y - hx, e, s.y - hz));
    out.ground = float3(s.ground, s.cavity, s.cover);
    out.position = scn_frame.viewProjectionTransform * float4(out.world, 1.0);
    return out;
}

fragment half4 terrainFragment(TerrainVarying in [[stage_in]],
                               constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                               constant TerrainParams &T [[buffer(2)]]) {
    float3 sun = T.sun.xyz;
    float3 view = in.world - T.camera.xyz;
    float dist = length(view);
    float3 rd = view / dist;
    float detail = detailAt(dist);
    Surface s = coverAt(in.world.xz, in.ground.x, in.ground.y, detail, false);
    s.cover = max(s.cover, in.ground.z);
    float cloud = cloudShadow(in.world.xz, in.world.y, sun);
    float3 col;
    if (s.kind == Water) {
        col = waterColour(s, in.world.xz, rd, sun, cloud);
    } else {
        float3 n = detailNormal(s, normalize(in.normal), in.world.xz, detail);
        col = surfaceAlbedo(s, in.world.xz, 1.0 - n.y, detail) * surfaceLight(n, sun, cloud, 1.0);
    }
    col = display(col, T.misc.z > 0.5);
    float fog = saturate((dist - T.fog.w) / max(T.misc.x - T.fog.w, 1.0));
    return half4(half3(mix(col, T.fog.rgb, fog)), 1.0);
}

// MARK: - Sky

struct SkyVertexIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
};
struct SkyVarying {
    float4 position [[position]];
    float3 direction;
};

vertex SkyVarying terrainSkyVertex(SkyVertexIn in [[stage_in]],
                                   constant SCNSceneBuffer &scn_frame [[buffer(0)]]) {
    SkyVarying out;
    // Ignore translation: the dome stays infinitely far away as the aircraft moves.
    float4 view = scn_frame.viewTransform * float4(in.position, 0.0);
    out.position = scn_frame.projectionTransform * view;
    out.position.z = out.position.w;
    out.direction = in.position;
    return out;
}

fragment half4 terrainSkyFragment(SkyVarying in [[stage_in]],
                                  constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                                  constant TerrainParams &T [[buffer(2)]]) {
    float3 rd = normalize(in.direction);
    float3 sun = T.sun.xyz;
    // The sun's disc is drawn by the screen-space glare shader.
    float3 col = skyColor(rd, sun, false);
    float jitter = hash12(in.position.xy);
    float4 clouds = marchClouds(T.camera.xyz, rd, sun, 1e6, jitter, int(T.misc.w), 4);
    col = col * (1.0 - clouds.a) + clouds.rgb;
    col = display(col, T.misc.z > 0.5);
    // Terrain at the fog limit must meet the sky: haze the dome into the fog colour.
    float haze = exp(-max(rd.y, 0.0) * 14.0);
    return half4(half3(mix(col, T.fog.rgb, haze)), 1.0);
}
