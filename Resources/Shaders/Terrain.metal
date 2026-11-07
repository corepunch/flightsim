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
    float4 trees;       // x = finest tree spacing in metres, y = half tree grid in cells
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
    float2 ground;      // bare height, cavity
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
    out.ground = float2(s.ground, s.cavity);
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

// MARK: - Trees

// Trees are camera-facing opaque triangles, two feet on the ground and the apex at the
// crown, one per cell of a lattice that rings the camera like the terrain does. All
// trees live on the finest lattice; a ring of 2^k times the spacing draws every 2^k-th
// tree, grown to stand in for the ones it skips. Cells outside a forest collapse to a
// clipped point.

struct TreeVarying {
    float4 position [[position]];
    half3 colour;
};

vertex TreeVarying treeVertex(TerrainVertexIn in [[stage_in]], uint vid [[vertex_id]],
                              constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                              constant NodeBuffer &scn_node [[buffer(1)]],
                              constant TerrainParams &T [[buffer(2)]]) {
    TreeVarying out;
    out.position = float4(0.0, 0.0, -2.0, 1.0);
    out.colour = 0.0h;
    float fine = T.trees.x;
    float spacing = scn_node.modelTransform[0][0];
    float grow = spacing / fine;
    float outer = spacing * T.trees.y;
    float inner = grow > 1.5 ? outer * 0.5 : 0.0;
    float2 cell = round((scn_node.modelTransform[3].xz / spacing + in.position.xz) * grow);
    float2 j = cellHash(cell);
    float2 xz = (cell + 0.1 + 0.8 * j) * fine;
    float d = distance(xz, T.camera.xz);
    if (d < inner || d >= outer) return out;
    Surface s = surface(xz, 3, 1.0, false);
    if (s.kind != Tree) return out;

    float2 k = cellHash(cell + 4096.0);
    bool conifer = s.id >= 1.0 ? k.x < 0.85 : k.x < 0.15;
    float h = s.cover * (0.75 + 0.5 * k.y) * (conifer ? 1.1 : 0.85) * sqrt(grow);
    float w = h * (conifer ? 0.5 : 0.85) * sqrt(grow);
    float3 base = float3(xz.x, s.ground - 1.0, xz.y);     // feet sunk so the coarser mesh never floats them
    float3 toCam = T.camera.xyz - base;
    float2 r = normalize(float2(toCam.z, -toCam.x));      // foot 0 left, foot 1 right: counter-clockwise from the camera
    uint corner = vid % 3u;
    float side = corner == 0u ? -1.0 : corner == 1u ? 1.0 : 0.0;
    float3 pos = corner == 2u ? base + float3(0.0, h + 1.0, 0.0) : base + float3(r.x, 0.0, r.y) * (0.5 * w * side);

    // Each tree has its own shade; the feet lean their normals apart so one flank is lit.
    float3 albedo = conifer ? mix(float3(0.040, 0.070, 0.045), float3(0.075, 0.105, 0.060), k.y)
                            : mix(float3(0.080, 0.130, 0.045), float3(0.135, 0.150, 0.055), k.y);
    albedo *= 0.85 + 0.3 * fract(s.id);
    float3 n = normalize(float3(r.x * side * 0.8, 1.0, r.y * side * 0.8));
    float cloud = cloudShadow(xz, s.ground, T.sun.xyz);
    float3 col = display(albedo * surfaceLight(n, T.sun.xyz, cloud, 0.7), T.misc.z > 0.5);
    float fog = saturate((d - T.fog.w) / max(T.misc.x - T.fog.w, 1.0));
    out.colour = half3(mix(col, T.fog.rgb, fog));
    out.position = scn_frame.viewProjectionTransform * float4(pos, 1.0);
    return out;
}

fragment half4 treeFragment(TreeVarying in [[stage_in]]) {
    return half4(in.colour, 1.0h);
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
