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
    float4 trees;       // x = half tree grid in slots, y = finest slot spacing, z = reach
};

// Crown shading and fine noise fade out where they would be smaller than a pixel.
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
    float sunlight;     // 0 where hills hide the sun
};

// Soft hill shadow: how far the landform rises into the path toward the sun. Samples
// double in distance and use a cheaper landform, so it starts a little above the ground.
static float hillShadow(float3 p, float3 sun) {
    float res = 1.0;
    for (int i = 0; i < 6; i++) {
        float t = 50.0 * exp2(float(i));
        float3 q = p + sun * t;
        res = min(res, 10.0 * (q.y - groundOnly(q.xz, 2)) / t);
    }
    return smoothstep(0.0, 1.0, res);
}

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
    Surface sx = surface(xz + float2(e, 0.0), 3, detail, true);
    Surface sz = surface(xz + float2(0.0, e), 3, detail, true);
    TerrainVarying out;
    out.world = float3(xz.x, s.y, xz.y);
    out.normal = normalize(float3(s.y - sx.y, e, s.y - sz.y));
    out.ground = float2(s.ground, s.cavity);
    // From the water surface, not the channel bed, or the river's own banks shade it.
    out.sunlight = hillShadow(float3(xz.x, max(s.ground, 0.0) + 8.0, xz.y), T.sun.xyz);
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
    // The river and shorelines are narrower than the coarse rings' triangles, so heights
    // interpolated between vertices would draw them as zigzags. Near the river (its centre
    // line is cheap to test) and near any water line, take the ground per pixel, as roads are.
    float ground = in.ground.x, cavity = in.ground.y;
    if (abs(riverSigned(in.world.xz)) < 90.0 || abs(ground) < 6.0) ground = groundHeight(in.world.xz, 3, cavity);
    Surface s = coverAt(in.world.xz, ground, cavity, detail, false);
    float light = cloudShadow(in.world.xz, in.world.y, sun) * in.sunlight;
    float3 col;
    if (s.kind == Water) {
        col = waterColour(s, in.world.xz, rd, sun, light);
    } else {
        float3 n = detailNormal(s, normalize(in.normal), in.world.xz, detail);
        float shade = canopyShade(s, in.world.xz, detail);
        col = surfaceAlbedo(s, in.world.xz, 1.0 - n.y, detail) * surfaceLight(n, sun, light * shade, shade);
    }
    col = display(col, T.misc.z > 0.5);
    // The level's fog end is the haze visibility; fog start applies only to SceneKit fog.
    col = aerial(col, dist, T.camera.xyz, rd, sun, T.fog.rgb, T.misc.x);
    return half4(half3(col), 1.0);
}

// MARK: - Trees

// Standing trees as small double pyramids on the flat ground (a top, three corners where the
// crown is widest and a bottom: a cone for conifers, a rounded crown on a trunk otherwise), from a grid of slots per
// ring like the terrain's: each ring doubles the slot spacing and leaves out the area its
// finer ring draws. A slot jitters its tree inside itself and asks standingTree whether one
// stands there; empty slots collapse outside the clip volume. Slots thin out with distance
// so trees keep a roughly even density on screen, and grow a little to make up for it.

struct TreeVertexIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];   // xz slot indices; y corner (0 top, 1-3 widest, 4 bottom)
};
struct TreeVarying {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 albedo;
    float up;           // 0 at the base, 1 at the top
    float sunlight;
};

vertex TreeVarying treeVertex(TreeVertexIn in [[stage_in]],
                              constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                              constant NodeBuffer &scn_node [[buffer(1)]],
                              constant TerrainParams &T [[buffer(2)]]) {
    TreeVarying out;
    out.position = float4(2.0, 2.0, 2.0, 1.0);
    out.world = 0.0; out.normal = float3(0, 1, 0); out.albedo = 0.0; out.up = 0.0; out.sunlight = 1.0;
    float spacing = scn_node.modelTransform[0][0];
    float2 slot = scn_node.modelTransform[3].xz + in.position.xz * spacing;
    float halfSlots = T.trees.x, finest = T.trees.y;
    if (spacing > finest * 1.5) {
        float fine = spacing * 0.5;
        float2 rel = (slot - floor(T.camera.xz / fine) * fine) / fine;
        if (all(rel >= -halfSlots) && all(rel < halfSlots)) return out;
    }
    float2 xz = slot + (0.1 + 0.8 * hash22(slot * 0.731 + 17.0)) * spacing;
    float dist = distance(xz, T.camera.xz);
    float near = halfSlots * finest * 0.75;
    float keep = min(1.0, (near * near) / max(dist * dist, 1.0) * (spacing * spacing) / (finest * finest));
    float fade = 1.0 - smoothstep(0.8 * T.trees.z, T.trees.z, dist);
    if (hash12(slot + 3.7) >= keep || fade <= 0.0) return out;

    float cavity;
    float ground = groundHeight(xz, 3, cavity);
    StandingTree tree = standingTree(xz, ground, cavity, hash12(slot + 9.1), hash12(slot + 5.3));
    if (tree.height <= 0.0) return out;
    float grow = (1.0 + 0.5 * smoothstep(300.0, 2500.0, dist)) * fade;
    int corner = int(in.position.y + 0.5);
    float height = tree.height * grow;
    // Sunk a little, so trees on coarse terrain triangles never float.
    float3 base = float3(xz.x, ground - 1.5, xz.y);
    float3 p;
    if (corner == 0) {
        p = base + float3(0.0, height + 1.5, 0.0);
        out.normal = float3(0.0, 1.0, 0.0);
        out.up = 1.0;
    } else if (corner == 4) {
        p = base + float3(0.0, tree.bottom * height + (tree.bottom > 0.0 ? 1.5 : 0.0), 0.0);
        out.normal = float3(0.0, -1.0, 0.0);
        out.up = 0.0;
    } else {
        float a = hash12(slot + 1.3) * 2.0 * M_PI_F + float(corner) * 2.0943951;
        float2 dir = float2(cos(a), sin(a));
        p = base + float3(dir.x * tree.radius * grow, tree.widest * height + (tree.widest > 0.0 ? 1.5 : 0.0), dir.y * tree.radius * grow);
        out.normal = normalize(float3(dir.x, tree.widest > 0.0 ? 0.25 : 0.6, dir.y));
        out.up = tree.widest;
    }
    out.world = p;
    out.albedo = tree.albedo;
    out.sunlight = hillShadow(float3(xz.x, ground + 8.0, xz.y), T.sun.xyz);
    out.position = scn_frame.viewProjectionTransform * float4(p, 1.0);
    return out;
}

fragment half4 treeFragment(TreeVarying in [[stage_in]],
                            constant TerrainParams &T [[buffer(2)]]) {
    float3 sun = T.sun.xyz;
    float3 view = in.world - T.camera.xyz;
    float dist = length(view);
    // Leaf clumps break up the flat faces up close; lower branches sit in the shade of the
    // crown and its neighbours.
    float detail = detailAt(dist);
    float3 c = noised(in.world.xz / 1.8 + in.world.y * 0.7);
    float3 n = normalize(normalize(in.normal) + float3(c.y, 0.0, c.z) * 0.12 * detail);
    float occ = mix(0.3, 1.0, in.up) * mix(1.0, 0.8 + 0.25 * c.x, detail);
    float light = cloudShadow(in.world.xz, in.world.y, sun) * in.sunlight * occ;
    float3 col = in.albedo * surfaceLight(n, sun, light, occ);
    col = display(col, T.misc.z > 0.5);
    col = aerial(col, dist, T.camera.xyz, view / dist, sun, T.fog.rgb, T.misc.x);
    return half4(half3(col), 1.0);
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
