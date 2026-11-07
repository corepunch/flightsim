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
    float4 trees;       // x = metres before trees thin, y = finest slot spacing, z = reach in metres
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

// Standing trees on four rings of slots around the camera (Terrain.m): the near ring at
// the lattice spacing, the next at the same spacing but twice the slots, then each ring
// doubling the spacing, and each leaving out the area its finer ring draws. Every slot
// lies on the finest lattice, and a tree's place, size and look come from that lattice
// cell alone, so a tree is the same tree whichever ring draws it. Trees thin out with
// distance by lattice rank (how coarse a lattice the cell belongs to), which every ring
// judges the same way, so none appears or vanishes as the rings move; a tree due at a
// distance grows in from nothing as the camera nears it, and they all grow a little to
// make up for the thinning.
//
// Three levels of detail. On the far rings a tree is one triangle (three vertices a
// slot), stood up on its foot and turned to the camera, shaded as the cone or crown it
// stands for. On the near ring a slot is a bipyramid (a top, a ring of six, a bottom),
// which far off is the tree itself, a pyramid shaded as a smooth cone or a diamond as a
// crown; and up close, where a tree is more than a few pixels wide, it is a proxy and
// the fragment shader casts the view ray at the tree itself: a conifer is a spire of
// three overlapping cone tiers with ragged skirts on a short trunk, a broadleaf a rounded
// crown on a trunk, a volume from every angle for a few quadratics a pixel; the fragment
// writes the hit's depth so neighbours sort.

struct TreeVertexIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];   // xz slot indices; y corner: 0 top, 1-6 ring, 7 bottom; 16 top, 17-18 feet of a triangle
};
struct TreeVarying {
    float4 position [[position]];
    float3 world;                   // the proxy's surface point: the view ray goes through it
    float2 across;                  // triangles: x from -1 to 1 across, y 0 at the foot, 1 at the top
    float3 base [[flat]];           // the tree's foot in world space, sunk a little into the ground
    float4 shape [[flat]];          // x height, y crown radius, z look, w kind (TreeKind)
    float3 albedo [[flat]];
    float2 light [[flat]];          // x sunlight reaching the ground, y crowding (1 inside a forest)
};
struct TreeFragmentOut {
    half4 colour [[color(0)]];
    float depth [[depth(any)]];
};
// How a tree is drawn: ray cast inside its proxy up close, the proxy itself further off,
// one triangle on the far rings.
enum TreeKind { BroadleafCast = 0, ConiferCast = 1, ConiferPyramid = 2, BroadleafDiamond = 3, ConiferTriangle = 4, BroadleafTriangle = 5 };
// Cast trees nearer than this many crown radii: about where a tree is 20 pixels wide.
constant float kCastRadii = 75.0;

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
    out.world = 0.0; out.across = 0.0; out.base = 0.0; out.shape = 0.0; out.albedo = 0.0; out.light = 1.0;
    // The ring's node carries its slot spacing (x scale), the finer ring's spacing (y
    // scale) and the half extent of the hole that ring fills (y position; 0 for none).
    float spacing = scn_node.modelTransform[0][0];
    float finerSpacing = scn_node.modelTransform[1][1], hole = scn_node.modelTransform[3].y;
    float2 slot = scn_node.modelTransform[3].xz + in.position.xz * spacing;
    float finest = T.trees.y;
    if (hole > 0.0) {
        float2 rel = slot - floor(T.camera.xz / finerSpacing) * finerSpacing;
        if (all(rel >= -hole) && all(rel < hole)) return out;
    }
    int2 cell = int2(round(slot / finest));
    int rank = latticeRank(cell);
    float2 jitter = cellHash(float2(cell)), dice = cellHash(float2(cell) + 8192.0), shape = cellHash(float2(cell) + 16384.0);
    // Coarser cells wander further, so the survivors at a distance show no lattice.
    float2 xz = (float2(cell) + (jitter - 0.5) * exp2(float(rank))) * finest;
    float dist = distance(xz, T.camera.xz);
    // Beyond near (half the second ring's reach), the rank a cell needs rises by one each
    // time the distance doubles, as the rings' spacing does; a cell of the rank just
    // below fades out by its own dice over that doubling.
    float level = max(log2(dist / T.trees.x), 0.0);
    float fade = 1.0 - smoothstep(0.8 * T.trees.z, T.trees.z, dist);
    // A tree grows from nothing over the last fifth of the distance to where it is due.
    float shown = saturate((float(rank) + dice.x - level) / 0.3) * fade;
    if (shown <= 0.0) return out;

    float blend;
    float2 groundLight = heightAt(heightMap, T, mapLevelAt(T, xz, blend), xz);
    float ground = groundLight.x;
    StandingTree tree = standingTree(xz, ground, 0.0, dice.y, shape.x);
    if (tree.height <= 0.0) return out;
    float grow = (1.0 + 0.6 * smoothstep(300.0, 2000.0, dist)) * shown;
    // Sunk a little, so trees on coarse terrain triangles never float; the shape is that
    // much taller from its foot.
    const float sink = 1.5;
    float height = tree.height * grow + sink, radius = tree.radius * grow;
    float3 base = float3(xz.x, ground - sink, xz.y);
    int corner = int(in.position.y + 0.5);
    bool triangle = corner >= 16;
    if (triangle) corner -= 16;
    float3 p;
    int kind;
    if (triangle) {
        // One triangle, stood on its foot, its face turned to the camera and its top
        // leaning toward it so it never thins to a line when seen from above.
        float3 toCam = normalize(T.camera.xyz - base);
        float3 side = normalize(float3(toCam.z, 0.0, -toCam.x));      // the camera's right
        float3 up = float3(0.0, 1.0, 0.0) - toCam * toCam.y;
        up = length(up) > 0.05 ? normalize(up) : normalize(cross(side, toCam));
        kind = tree.conifer ? ConiferTriangle : BroadleafTriangle;
        if (corner == 0) { p = up * height; out.across = float2(0.0, 1.0); }
        else { float u = corner == 1 ? -1.0 : 1.0; p = side * (u * radius); out.across = float2(u, 0.0); }
    } else {
        // Far off the pyramid is the tree: a cone on the ground, or a diamond about a crown's
        // centre. Near, it is the proxy: a spire's ring sits on the ground a little wider than
        // its skirts; a crown's ring is at its centre, the top and bottom far enough out to
        // hold the sphere.
        bool cast = dist < kCastRadii * radius;
        float top, ringY, ringR, bottom;
        if (tree.conifer) {
            kind = cast ? ConiferCast : ConiferPyramid;
            top = height; ringY = 0.0; ringR = radius * (cast ? 1.16 : 1.0); bottom = -0.05;
        } else {
            float centre = 0.6 * height;
            kind = cast ? BroadleafCast : BroadleafDiamond;
            float reach = cast ? 1.4 * radius : radius;
            top = centre + reach; ringY = centre; ringR = radius * (cast ? 1.5 : 1.0); bottom = min(centre - reach, 0.0);
        }
        if (corner == 0) p = float3(0.0, top, 0.0);
        else if (corner == 7) p = float3(0.0, bottom, 0.0);
        else {
            float a = shape.y * 2.0 * M_PI_F + float(corner - 1) * (M_PI_F / 3.0);
            p = float3(cos(a) * ringR, ringY, sin(a) * ringR);
        }
    }
    out.world = base + p;
    out.base = base;
    out.shape = float4(height, radius, shape.y, float(kind));
    out.albedo = tree.albedo;
    out.light = float2(groundLight.y, tree.crowd);
    out.position = scn_frame.viewProjectionTransform * float4(out.world, 1.0);
    return out;
}

// A ray hit on a tree, in tree space (origin at the foot, y up).
struct TreeHit {
    float t;            // along the ray; negative for none
    float3 normal;
    float occlusion;    // how open to the sky the point is
    bool trunk;
};

static void treeNearer(thread TreeHit &hit, float t, float3 normal, float occlusion, bool trunk) {
    if (t <= 0.0 || (hit.t > 0.0 && t >= hit.t)) return;
    hit.t = t; hit.normal = normal; hit.occlusion = occlusion; hit.trunk = trunk;
}

// A vertical cylinder of radius r between y0 and y1: the trunk.
static void castTrunk(thread TreeHit &hit, float3 ro, float3 rd, float r, float y0, float y1) {
    float a = dot(rd.xz, rd.xz), b = 2.0 * dot(ro.xz, rd.xz), c = dot(ro.xz, ro.xz) - r * r;
    float disc = b * b - 4.0 * a * c;
    if (disc < 0.0 || a < 1e-6) return;
    float t = (-b - sqrt(disc)) / (2.0 * a);
    float y = ro.y + t * rd.y;
    if (y < y0 || y > y1) return;
    float3 p = ro + rd * t;
    treeNearer(hit, t, normalize(float3(p.x, 0.0, p.z)), 0.3, true);
}

// A sphere of radius r about (0, cy, 0): a broadleaf crown.
static void castCrown(thread TreeHit &hit, float3 ro, float3 rd, float cy, float r) {
    float3 o = ro - float3(0.0, cy, 0.0);
    float b = dot(o, rd), c = dot(o, o) - r * r;
    float disc = b * b - c;
    if (disc < 0.0) return;
    float t = -b - sqrt(disc);
    float3 n = normalize(o + rd * t);
    treeNearer(hit, t, n, mix(0.4, 1.0, 0.5 + 0.5 * n.y), false);
}

// One tier of a spire: a cone from its apex at ya down to a skirt of radius r at yb, with
// the skirt torn into branch tips by rag (0 to 1), and a dark disc closing it from below.
// The tier is darkest just under the skirt of the tier above it, which hides its top.
static void castTier(thread TreeHit &hit, float3 ro, float3 rd, float ya, float yb, float r, float rag, float look, float shade) {
    float k = r / (ya - yb);
    float3 o = ro - float3(0.0, ya, 0.0);
    float kk = k * k;
    float a = dot(rd.xz, rd.xz) - kk * rd.y * rd.y;
    float b = 2.0 * (dot(o.xz, rd.xz) - kk * o.y * rd.y);
    float c = dot(o.xz, o.xz) - kk * o.y * o.y;
    float disc = b * b - 4.0 * a * c;
    if (disc >= 0.0 && abs(a) > 1e-6) {
        float sq = sqrt(disc);
        for (int side = 0; side < 2; side++) {
            float t = (-b + (side == 0 ? -sq : sq)) / (2.0 * a);
            float3 p = o + rd * t;
            if (p.y > 0.0 || p.y < yb - ya) continue;
            float f = (p.y - (yb - ya)) / (ya - yb);     // 0 at the skirt, 1 at the apex
            float angle = atan2(p.z, p.x);
            // Branch tips: the skirt's edge rises and falls around the tier.
            float tear = 0.5 + 0.5 * noise(float2(angle * 2.2 + look * 41.0, ya * 0.7));
            if (f < rag * tear) continue;
            float2 radial = normalize(p.xz);
            float3 n = normalize(float3(radial.x, k, radial.y));
            treeNearer(hit, t, n, mix(1.0, shade, smoothstep(0.1, 0.5, f)), false);
        }
    }
    if (abs(rd.y) > 1e-5) {
        float t = (yb - ro.y) / rd.y;
        float2 q = ro.xz + rd.xz * t;
        if (dot(q, q) <= r * r * (1.0 - rag) * (1.0 - rag)) treeNearer(hit, t, float3(0.0, -1.0, 0.0), 0.25, false);
    }
}

fragment TreeFragmentOut treeFragment(TreeVarying in [[stage_in]],
                                      constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                                      constant TerrainParams &T [[buffer(2)]]) {
    float3 sun = T.sun.xyz;
    float3 cam = T.camera.xyz;
    float3 rd = normalize(in.world - cam);
    float3 ro = cam - in.base;
    float height = in.shape.x, radius = in.shape.y, look = in.shape.z;
    int kind = int(in.shape.w + 0.5);
    float proxyDist = distance(in.world, cam);
    // Torn skirts and needle relief only matter while a tree is more than a few pixels.
    float detail = 1.0 - smoothstep(400.0, 1800.0, proxyDist);
    TreeHit hit = { -1.0, float3(0.0, 1.0, 0.0), 1.0, false };
    if (kind == ConiferCast) {
        // Three tiers, each apex a quarter of the height below the last and each skirt
        // wider, overlapping so the silhouette steps down like a spruce.
        for (int k = 0; k < 3; k++) {
            float ya = height * (1.0 - 0.26 * float(k));
            float yb = max(ya - 0.48 * height, 0.06 * height);
            float r = radius * (0.48 + 0.26 * float(k));
            castTier(hit, ro, rd, ya, yb, r, 0.16 * detail, look + float(k), k == 0 ? 0.7 : 0.45);
        }
        castTrunk(hit, ro, rd, max(0.03 * height, 0.25), 0.0, 0.3 * height);
    } else if (kind == BroadleafCast) {
        float centre = 0.6 * height;
        castCrown(hit, ro, rd, centre, radius);
        castTrunk(hit, ro, rd, max(0.035 * height, 0.3), 0.0, centre);
    } else if (kind == ConiferPyramid || kind == BroadleafDiamond) {
        // The pyramid itself, with the normal of the cone or sphere it stands in for.
        float3 p = in.world - in.base;
        hit.t = proxyDist;
        if (kind == ConiferPyramid) {
            float2 radial = normalize(p.xz);
            hit.normal = normalize(float3(radial.x, radius / height, radial.y));
            hit.occlusion = mix(0.7, 1.0, saturate(p.y / height));
        } else {
            hit.normal = normalize(p - float3(0.0, 0.6 * height, 0.0));
            hit.occlusion = mix(0.4, 1.0, 0.5 + 0.5 * hit.normal.y);
        }
    } else {
        // The triangle, rounded by the normal of the cone or crown behind it.
        float3 toCam = normalize(cam - in.base);
        float3 side = normalize(float3(toCam.z, 0.0, -toCam.x)), facing = normalize(float3(toCam.x, 0.0, toCam.z));
        float u = in.across.x, v = in.across.y, bulge = sqrt(max(1.0 - u * u, 0.0));
        hit.t = proxyDist;
        if (kind == ConiferTriangle) {
            hit.normal = normalize(side * u + facing * bulge + float3(0.0, radius / height, 0.0));
            hit.occlusion = mix(0.7, 1.0, v);
        } else {
            hit.normal = normalize(side * u + facing * bulge + float3(0.0, 2.0 * v - 1.0, 0.0));
            hit.occlusion = mix(0.5, 1.0, v);
        }
    }
    if (hit.t <= 0.0) discard_fragment();
    float3 p = ro + rd * hit.t;
    float3 world = in.base + p;
    float dist = hit.t;
    float up = saturate(p.y / height);
    // Needle and leaf clumps break up the smooth surfaces up close; crowded trees shade
    // each other's lower halves, and every tree is darker toward its foot.
    float3 c = noised(p.xz * 0.9 + p.y * 0.55 + look * 10.0);
    float3 n = normalize(normalize(hit.normal) + float3(c.y, 0.3 * c.x, c.z) * 0.3 * detail);
    float occ = hit.occlusion * mix(0.45, 1.0, up) * mix(1.0, 0.85 + 0.2 * c.x, detail);
    float shadow = in.light.x * mix(1.0, mix(0.55, 1.0, up), in.light.y);
    float3 albedo = hit.trunk ? float3(0.05, 0.035, 0.025) : in.albedo;
    float3 col = albedo * surfaceLight(n, sun, shadow * (hit.trunk ? 0.5 : 1.0), occ);
    col = display(col, T.misc.z > 0.5);
    col = aerial(col, dist, cam, rd, sun, T.fog.rgb, T.misc.x);
    TreeFragmentOut out;
    out.colour = half4(half3(col), 1.0);
    if (kind == ConiferCast || kind == BroadleafCast) {
        float4 clip = scn_frame.viewProjectionTransform * float4(world, 1.0);
        out.depth = clip.z / clip.w;
    } else {
        out.depth = in.position.z;
    }
    return out;
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
