// Geometry-clipmap terrain and sky dome for SceneKit, after Losasso and Hoppe: nested
// rings of one shared grid, each scaled and placed by its node. The landscape itself is a
// texture clipmap (Tanner, Migdal and Jones): nested windows of a lit ground image and a
// height map, one per power-of-two spacing, that follow the camera and are baked by the
// groundBake kernel from the procedural surface as they scroll. So the procedural maths
// runs once per texel when it comes into view, not once per pixel per frame; the ring
// shaders only sample. The cloud sky is marched once per frame into a quarter-size
// screen texture (skyBake) that the dome spreads over the screen. Hosted by
// Sources/Render/Terrain.m, which prepends TerrainCommon.metal.

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

constant int kMaxMapLevels = 10;

struct TerrainParams {
    float4 camera;      // xyz, w = seconds
    float4 sun;         // xyz toward the sun
    float4 fog;         // rgb display-linear fog colour, w = fog start
    float4 misc;        // x = fog end, y = half grid in cells, z = HDR camera, w = cloud steps
    float4 trees;       // x = half tree grid in slots, y = finest slot spacing, z = reach
    float4 map;         // x = texels per map edge, y = map levels, z = finest metres per texel
    float4 heights;     // x = lowest height, y = height range, metres
    float4 mapOrigin[kMaxMapLevels];    // xy = world texel index of each level's window corner
};

static float3 display(float3 col, bool hdr) { return hdr ? col * 0.45 : tonemap(col); }

// MARK: - Ground maps

// A level's window holds texels [origin, origin + edge) at its spacing; the texture is a
// torus, so a texel keeps its place as the window scrolls and sampling wraps for free.
// Colour holds lit radiance over four (sRGB) with water's share in alpha; height holds the
// mesh height and the sunlight (hill and cloud shadow) reaching the ground.

constexpr sampler mapSampler(address::repeat, filter::linear);

static float mapSpacing(constant TerrainParams &T, int level) { return T.map.z * exp2(float(level)); }

static float2 mapUV(constant TerrainParams &T, int level, float2 xz) {
    return xz / (mapSpacing(T, level) * T.map.x);
}

// Keeps xz inside the window, a texel in, so nothing beyond it reads the far side.
static float2 mapClamp(constant TerrainParams &T, int level, float2 xz) {
    float s = mapSpacing(T, level);
    return clamp(xz, (T.mapOrigin[level].xy + 1.0) * s, (T.mapOrigin[level].xy + T.map.x - 1.0) * s);
}

// The finest level whose window holds xz; blend rises toward the next level over the
// window's outer band so the change of resolution never draws a line.
static int mapLevelAt(constant TerrainParams &T, float2 xz, thread float &blend) {
    int levels = int(T.map.y);
    for (int k = 0; k < levels - 1; k++) {
        float2 rel = xz / mapSpacing(T, k) - T.mapOrigin[k].xy - T.map.x * 0.5;
        float edge = max(abs(rel.x), abs(rel.y)) / (T.map.x * 0.5);
        blend = smoothstep(0.84, 0.96, edge);
        if (blend < 1.0) return k;
    }
    blend = 0.0;
    return levels - 1;
}

// Mesh height (x) and ground sunlight (y) at a level.
static float2 heightAt(texture2d_array<float> heightMap, constant TerrainParams &T, int level, float2 xz) {
    float2 v = heightMap.sample(mapSampler, mapUV(T, level, mapClamp(T, level, xz)), level).xy;
    return float2(T.heights.x + v.x * T.heights.y, v.y);
}

static float4 colourAt(texture2d_array<float> groundMap, constant TerrainParams &T, float2 xz) {
    float blend;
    int k = mapLevelAt(T, xz, blend);
    float4 c = groundMap.sample(mapSampler, mapUV(T, k, xz), k);
    if (blend > 0.0) c = mix(c, groundMap.sample(mapSampler, mapUV(T, k + 1, xz), k + 1), blend);
    return c;
}

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

struct BakeParams {
    int4 origin;        // xy = world texel index of thread (0, 0), z = level, w = texels per edge
    float4 spacing;     // x = metres per texel, y = detail (fine noise fades as texels coarsen)
};

// One texel of a level: the lit ground as seen from above, and the mesh height. Water
// stores its lit body colour; the view-dependent reflection is added when drawn.
kernel void groundBake(texture2d_array<float, access::write> groundMap [[texture(0)]],
                       texture2d_array<float, access::write> heightMap [[texture(1)]],
                       constant TerrainParams &T [[buffer(0)]],
                       constant BakeParams &B [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 index = B.origin.xy + int2(gid);
    uint2 texel = uint2(index & (B.origin.w - 1));
    float spacing = B.spacing.x, detail = B.spacing.y;
    float2 xz = (float2(index) + 0.5) * spacing;
    float cavity;
    float ground = groundHeight(xz, 3, cavity);
    Surface s = coverAt(xz, ground, cavity, detail, false);
    float3 sun = T.sun.xyz;
    float light = cloudShadow(xz, max(ground, 0.0), sun) * hillShadow(float3(xz.x, max(ground, 0.0) + 8.0, xz.y), sun);
    float mesh = s.kind == Water ? 0.0 : (s.kind == Road && ground < 0.0) ? 1.5 : ground;
    float3 col;
    bool water = s.kind == Water;
    if (water) {
        float3 body = mix(float3(0.16, 0.17, 0.11), float3(0.02, 0.05, 0.06), smoothstep(0.0, 6.0, -ground));
        col = body * (0.6 + 1.2 * light);
    } else {
        float e = spacing;
        float3 n = normalize(float3(ground - groundOnly(xz + float2(e, 0.0), 3), e, ground - groundOnly(xz + float2(0.0, e), 3)));
        n = detailNormal(s, n, xz, detail);
        float shade = canopyShade(s, xz, detail);
        col = surfaceAlbedo(s, xz, 1.0 - n.y, detail) * surfaceLight(n, sun, light * shade, shade);
    }
    groundMap.write(float4(col * 0.25, water ? 1.0 : 0.0), texel, B.origin.z);
    heightMap.write(float4((mesh - T.heights.x) / T.heights.y, light, 0.0, 0.0), texel, B.origin.z);
}

// MARK: - Terrain

struct TerrainVertexIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];   // xz grid indices; y only sizes the culling box
};
struct TerrainVarying {
    float4 position [[position]];
    float3 world;
};

vertex TerrainVarying terrainVertex(TerrainVertexIn in [[stage_in]],
                                    constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                                    constant NodeBuffer &scn_node [[buffer(1)]],
                                    constant TerrainParams &T [[buffer(2)]],
                                    texture2d_array<float> heightMap [[texture(1)]]) {
    float2 g = in.position.xz;
    float spacing = scn_node.modelTransform[0][0];
    float2 origin = scn_node.modelTransform[3].xz;
    // CDLOD morph: over the outer band odd vertices slide onto their even neighbours, so
    // the rim is exactly the next coarser grid and no seam or T-junction remains. The
    // height morphs with them, from this ring's map level to the coarser ring's.
    float2 rel = abs(g) / T.misc.y;
    float morph = saturate((max(rel.x, rel.y) - 0.70) / 0.28);
    g -= fract(g * 0.5) * 2.0 * morph;
    float2 xz = origin + g * spacing;
    int levels = int(T.map.y);
    int k = clamp(int(round(log2(spacing / T.map.z))), 0, levels - 1);
    float h = mix(heightAt(heightMap, T, k, xz).x, heightAt(heightMap, T, min(k + 1, levels - 1), xz).x, morph);
    TerrainVarying out;
    out.world = float3(xz.x, h, xz.y);
    out.position = scn_frame.viewProjectionTransform * float4(out.world, 1.0);
    return out;
}

fragment half4 terrainFragment(TerrainVarying in [[stage_in]],
                               constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                               constant TerrainParams &T [[buffer(2)]],
                               texture2d_array<float> groundMap [[texture(0)]],
                               texture2d_array<float> heightMap [[texture(1)]]) {
    float3 sun = T.sun.xyz;
    float3 view = in.world - T.camera.xyz;
    float dist = length(view);
    float3 rd = view / dist;
    float2 xz = in.world.xz;
    float4 c = colourAt(groundMap, T, xz);
    float3 col = c.rgb * 4.0;
    if (c.a > 0.002) {
        // Water reflects the sky by Fresnel over its baked body colour, with sun glints.
        float blend;
        float light = heightAt(heightMap, T, mapLevelAt(T, xz, blend), xz).y;
        float3 n = normalize(float3(0.02 * noise(xz / 6.0), 1.0, 0.02 * noise(xz / 6.0 + 3.0)));
        float3 r = reflect(rd, n);
        float fres = 0.02 + 0.98 * pow(1.0 - max(-rd.y, 0.0), 5.0);
        float glint = pow(max(dot(r, sun), 0.0), 400.0) * 30.0 * light;
        col = mix(col, mix(col, skyColor(r, sun, false), fres) + glint, c.a);
    }
    col = display(col, T.misc.z > 0.5);
    // The level's fog end is the haze visibility; fog start applies only to SceneKit fog.
    col = aerial(col, dist, T.camera.xyz, rd, sun, T.fog.rgb, T.misc.x);
    return half4(half3(col), 1.0);
}

// MARK: - Trees

// Standing trees as small double pyramids on the flat ground (a top, three corners where
// the crown is widest and a bottom: a cone for conifers, a rounded crown on a trunk
// otherwise), from a grid of slots per ring like the terrain's: each ring doubles the
// slot spacing and leaves out the area its finer ring draws. Every slot lies on the
// finest lattice, and a tree's place, size and look come from that lattice cell alone,
// so a tree is the same tree whichever ring draws it. Trees thin out with distance by
// lattice rank (how coarse a lattice the cell belongs to), which every ring judges the
// same way, so none appears or vanishes as the rings move; a tree due at a distance
// grows in from nothing as the camera nears it, and they all grow a little to make up
// for the thinning.

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

// 0 for a cell of the finest lattice only, up to 3 for one of the coarsest ring's.
static int latticeRank(int2 cell) {
    uint bits = uint(cell.x | cell.y);
    return bits == 0u ? 3 : min(3, int(ctz(bits)));
}

vertex TreeVarying treeVertex(TreeVertexIn in [[stage_in]],
                              constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                              constant NodeBuffer &scn_node [[buffer(1)]],
                              constant TerrainParams &T [[buffer(2)]],
                              texture2d_array<float> heightMap [[texture(1)]]) {
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
    int2 cell = int2(round(slot / finest));
    int rank = latticeRank(cell);
    float2 jitter = cellHash(float2(cell)), dice = cellHash(float2(cell) + 8192.0), shape = cellHash(float2(cell) + 16384.0);
    // Coarser cells wander further, so the survivors at a distance show no lattice.
    float2 xz = (float2(cell) + (jitter - 0.5) * exp2(float(rank))) * finest;
    float dist = distance(xz, T.camera.xz);
    float near = halfSlots * finest * 0.5;
    // Beyond near, the rank a cell needs rises by one each time the distance doubles; a
    // cell of the rank just below fades out by its own dice over that doubling.
    float level = max(log2(dist / near), 0.0);
    float fade = 1.0 - smoothstep(0.8 * T.trees.z, T.trees.z, dist);
    // A tree grows from nothing over the last fifth of the distance to where it is due.
    float shown = saturate((float(rank) + dice.x - level) / 0.3) * fade;
    if (shown <= 0.0) return out;

    float blend;
    float2 groundLight = heightAt(heightMap, T, mapLevelAt(T, xz, blend), xz);
    float ground = groundLight.x;
    StandingTree tree = standingTree(xz, ground, 0.0, dice.y, shape.x);
    if (tree.height <= 0.0) return out;
    float grow = (1.0 + 0.5 * smoothstep(300.0, 2500.0, dist)) * shown;
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
        float a = shape.y * 2.0 * M_PI_F + float(corner) * 2.0943951;
        float2 dir = float2(cos(a), sin(a));
        p = base + float3(dir.x * tree.radius * grow, tree.widest * height + (tree.widest > 0.0 ? 1.5 : 0.0), dir.y * tree.radius * grow);
        out.normal = normalize(float3(dir.x, tree.widest > 0.0 ? 0.25 : 0.6, dir.y));
        out.up = tree.widest;
    }
    out.world = p;
    out.albedo = tree.albedo;
    out.sunlight = groundLight.y;
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
    float detail = 1.0 - smoothstep(1500.0, 3500.0, dist);
    float3 c = noised(in.world.xz / 1.8 + in.world.y * 0.7);
    float3 n = normalize(normalize(in.normal) + float3(c.y, 0.0, c.z) * 0.12 * detail);
    float occ = mix(0.3, 1.0, in.up) * mix(1.0, 0.8 + 0.25 * c.x, detail);
    float light = in.sunlight * occ;
    float3 col = in.albedo * surfaceLight(n, sun, light, occ);
    col = display(col, T.misc.z > 0.5);
    col = aerial(col, dist, T.camera.xyz, view / dist, sun, T.fog.rgb, T.misc.x);
    return half4(half3(col), 1.0);
}

// MARK: - Sky

struct SkyBakeParams {
    float4x4 inverseViewProjection;
};

// The sky and clouds for every texel of a screen-aligned texture a quarter of the
// drawable's size; clouds are soft, so the dome's upscale costs nothing visible.
kernel void skyBake(texture2d<half, access::write> sky [[texture(0)]],
                    constant TerrainParams &T [[buffer(0)]],
                    constant SkyBakeParams &S [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= sky.get_width() || gid.y >= sky.get_height()) return;
    float2 ndc = (float2(gid) + 0.5) / float2(sky.get_width(), sky.get_height()) * 2.0 - 1.0;
    float4 far = S.inverseViewProjection * float4(ndc.x, -ndc.y, 1.0, 1.0);
    float3 rd = normalize(far.xyz / far.w - T.camera.xyz);
    float3 sun = T.sun.xyz;
    // The sun's disc is drawn by the screen-space glare shader.
    float3 col = skyColor(rd, sun, false);
    float jitter = hash12(float2(gid));
    float4 clouds = marchClouds(T.camera.xyz, rd, sun, 1e6, jitter, int(T.misc.w), 4);
    sky.write(half4(half3(col * (1.0 - clouds.a) + clouds.rgb), 1.0h), gid);
}

constexpr sampler skySampler(address::clamp_to_edge, filter::linear);

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
                                  constant TerrainParams &T [[buffer(2)]],
                                  texture2d<half> skyMap [[texture(0)]]) {
    float3 rd = normalize(in.direction);
    float3 col = float3(skyMap.sample(skySampler, in.position.xy * scn_frame.inverseResolution).rgb);
    col = display(col, T.misc.z > 0.5);
    // Terrain at the fog limit must meet the sky: haze the dome into the fog colour.
    float haze = exp(-max(rd.y, 0.0) * 14.0);
    return half4(half3(mix(col, T.fog.rgb, haze)), 1.0);
}
