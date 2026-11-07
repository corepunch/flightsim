// Procedural landscape shared by the engine (Terrain.metal) and the preview raymarcher
// (Tools/TerrainPreview.metal). The host prepends this source to either, so there are no
// entry points here. Everything is evaluated from maths; there are no height or colour maps.
//
// Landform: value-noise fBm with analytic derivatives (Quilez) plus a gully erosion filter
// (Clay John / Fewes / Skovbo Johansen). Cover rules, in priority order:
//   water below 0 m, with a sand/mud shore and wet meadow (never crops) up to 9 m;
//   roads along every fourth line of a gently warped parcel grid, a valley road on one bank
//   of the river, both carried over water on causeways, none on hills;
//   villages of hard-edged houses lining the roads around some junctions;
//   farmland only in clusters of whole hedged parcels on low ground, drawn toward roads;
//   forest elsewhere where density allows, below a tree line, cleared along roads and in
//   villages; dry grass above the tree line and rock on steep ground.
// The ground stays flat under forest and is shaded as canopy seen from above; the trees
// that give it height and silhouette are drawn separately (standingTree, Terrain.metal).
#include <metal_stdlib>
using namespace metal;

constant float kScale = 7000.0;     // metres per noise unit for the landform
constant float kRelief = 1500.0;    // metres per unit of normalised height
constant float kPlain = 0.40;       // normalised height that becomes the lowland plain
constant float kParcel = 260.0;     // farm parcel size in metres
constant float kRoadCell = 1040.0;  // roads follow every fourth parcel line
constant float kRoadHalf = 3.5;     // metres from a road's centre line to its edge
constant float kLowland = 110.0;    // no roads or houses above this height
constant float kShore = 9.0;        // no crops below this height above water
constant float kCloudBase = 1900.0;
constant float kCloudTop = 2500.0;

enum Kind { Ground = 0, Tree = 1, Hedge = 2, Water = 3, Road = 4, House = 5 };

// MARK: - Noise

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// Value noise in [-1, 1] with its gradient in .yz.
static float3 noised(float2 x) {
    float2 p = floor(x), w = fract(x);
    float2 u = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * w * w * (w * (w - 2.0) + 1.0);
    float a = hash12(p), b = hash12(p + float2(1, 0));
    float c = hash12(p + float2(0, 1)), d = hash12(p + float2(1, 1));
    float k1 = b - a, k2 = c - a, k4 = a - b - c + d;
    return float3(-1.0 + 2.0 * (a + k1 * u.x + k2 * u.y + k4 * u.x * u.y),
                  2.0 * du * float2(k1 + k4 * u.y, k2 + k4 * u.x));
}

static float noise(float2 x) { return noised(x).x; }

constant float2x2 kRot = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));

static float fbm(float2 p, int octaves) {
    float a = 0.0, b = 0.5;
    for (int i = 0; i < octaves; i++) { a += b * noise(p); b *= 0.5; p = kRot * p * 2.03 + 17.1; }
    return a;
}

// MARK: - Landform

// Stripes aligned to the slope, blended over jittered cells; returns height and slope.
static float3 erosion(float2 p, float2 dir) {
    float2 ip = floor(p), fp = fract(p);
    float3 va = 0.0;
    float wt = 0.0;
    for (int i = -2; i <= 1; i++)
    for (int j = -2; j <= 1; j++) {
        float2 o = float2(i, j);
        float2 pp = fp + o - (hash22(ip - o) - 0.5) * 0.5;
        float w = exp(-dot(pp, pp) * 2.0);
        float mag = dot(pp, dir) * 2.0 * M_PI_F;
        va += float3(cos(mag), -sin(mag) * dir) * w;
        wt += w;
    }
    return va / wt;
}

// Normalised height (x) and an erosion term (y) used as cavity for shading.
static float2 landform(float2 uv, int erosionOctaves) {
    float3 n = 0.0;
    float nf = 1.0, na = 0.5;
    for (int i = 0; i < 3; i++) {
        n += noised(uv * 2.2 * nf + float2(3.1, 7.7) * i) * na * float3(1.0, nf, nf);
        na *= 0.35; nf *= 2.0;
    }
    n.x = n.x * 0.5 + 0.5;
    float2 dir = n.zy * float2(1.0, -1.0) * 0.9;
    float3 h = 0.0;
    float a = 0.5 * smoothstep(kPlain - 0.05, kPlain + 0.12, n.x), f = 1.0;
    for (int i = 0; i < erosionOctaves; i++) {
        h += erosion(uv * 7.0 * f, dir + h.zy * float2(1.0, -1.0) * 1.8) * a * float3(1.0, f, f);
        a *= 0.5; f *= 2.0;
    }
    return float2(n.x + (h.x - 0.5) * 0.11, h.x);
}

static float riverCentre(float z) {
    return 600.0 + 240.0 * sin(z / 900.0) + 700.0 * sin(z / 3300.0 + 1.3);
}

// Distance to the river's centre line, positive on the +x bank.
static float riverSigned(float2 xz) {
    float x0 = riverCentre(xz.y);
    float slope = riverCentre(xz.y + 1.0) - x0;
    return (xz.x - x0) / sqrt(1.0 + slope * slope);
}

static float softplus(float x, float k) { return k * log(1.0 + exp(x / k)); }

// Bare ground in metres above the water line: plain, hills, lake basins, river floodplain.
static float groundHeight(float2 xz, int erosionOctaves, thread float &cavity) {
    float2 e = landform(xz / kScale + float2(0.37, 0.61), erosionOctaves);
    cavity = e.y;
    float h = softplus(e.x - kPlain, 0.02) + 0.06 * (e.x - kPlain);
    float y = 22.0 + h * kRelief + 6.0 * fbm(xz / 900.0, 3);
    float lake = smoothstep(0.30, 0.55, noise(xz / 4200.0 + float2(21.7, 3.9)));
    y -= 48.0 * lake * (1.0 - smoothstep(50.0, 160.0, y));
    float d = abs(riverSigned(xz));
    // The floodplain is flat beside the river and rises with the valley floor away from it,
    // so the channel never cuts a gorge through high ground.
    float flood = 3.0 + 0.2 * y * smoothstep(60.0, 500.0, d);
    y = mix(flood, y, smoothstep(40.0, 1400.0, d));
    return mix(-4.0, y, smoothstep(24.0, 60.0, d));
}

static float groundOnly(float2 xz, int erosionOctaves) {
    float cavity;
    return groundHeight(xz, erosionOctaves, cavity);
}

// MARK: - Parcels and roads

// Parcels, roads and villages share one gently warped grid, so fields abut roads.
static float2 warped(float2 xz) {
    return xz + 60.0 * float2(fbm(xz / 700.0, 2), fbm(xz / 700.0 + 9.3, 2));
}

struct Parcel {
    float2 id;
    float edge;     // metres to the nearest parcel boundary
    float2 axis;    // furrow direction
    bool hedged;
};

// Jittered grid of parcels in warped space; some are split so the patchwork is not a grid.
static Parcel parcel(float2 w) {
    float2 g = w / kParcel;
    float2 ip = floor(g), fp = fract(g);
    float edge = min(0.5 - abs(fp.x - 0.5), 0.5 - abs(fp.y - 0.5));
    float2 id = ip;
    float split = hash12(ip + 5.1);
    if (split > 0.45) {
        float cut = 0.3 + 0.4 * hash12(ip + 2.7);
        float c = split > 0.72 ? fp.x : fp.y;
        id += c > cut ? float2(0.5, 0.25) : 0.0;
        edge = min(edge, abs(c - cut));
    }
    float angle = hash12(id + 3.3) * M_PI_F;
    Parcel p;
    p.id = id;
    p.edge = edge * kParcel;
    p.axis = float2(cos(angle), sin(angle));
    p.hedged = hash12(id + 7.7) < 0.7;
    return p;
}

struct Roads {
    float dist;         // metres to the nearest road centre line
    float2 junction;    // warped position of the nearest grid junction
    float village;      // radius of the village around that junction, 0 for none
};

// Whether the grid edge leaving a cell corner is a road: axis 0 runs along +x, 1 along +z.
static bool roadEdge(float2 corner, float axis) {
    return hash12(corner * 1.7 + float2(13.1, 4.2) + axis * 50.0) < 0.6;
}

static Roads roads(float2 w, float riverS) {
    float2 g = w / kRoadCell;
    float2 I = floor(g), f = fract(g);
    float d = 1e9;
    if (roadEdge(I, 0.0)) d = min(d, f.y);
    if (roadEdge(I + float2(0, 1), 0.0)) d = min(d, 1.0 - f.y);
    if (roadEdge(I, 1.0)) d = min(d, f.x);
    if (roadEdge(I + float2(1, 0), 1.0)) d = min(d, 1.0 - f.x);
    Roads r;
    r.dist = min(d * kRoadCell, abs(riverS - 240.0));
    float2 J = round(g);
    int edges = int(roadEdge(J, 0.0)) + int(roadEdge(J - float2(1, 0), 0.0))
              + int(roadEdge(J, 1.0)) + int(roadEdge(J - float2(0, 1), 1.0));
    r.junction = J * kRoadCell;
    r.village = edges >= 2 && hash12(J + 77.7) < 0.4 ? 120.0 + 100.0 * hash12(J + 31.3) : 0.0;
    return r;
}

static bool inVillage(float2 w, Roads r) {
    return r.village > 0.0 && distance(w, r.junction) < r.village;
}

// Village houses: hard-edged blocks on an 18 m grid, set back from the roads.
static float houses(float2 w, Roads r, thread float &id) {
    if (!inVillage(w, r) || r.dist < 8.0 || r.dist > 34.0) return 0.0;
    float2 cell = floor(w / 18.0), f = fract(w / 18.0);
    if (hash12(cell + 5.5) > 0.55) return 0.0;
    float2 extent = 0.22 + 0.12 * hash22(cell + 1.1);
    if (any(abs(f - 0.5) > extent)) return 0.0;
    id = hash12(cell + 9.9);
    return 5.0 + 3.0 * id;
}

// MARK: - Cover

// Farm clusters are decided per parcel, so a cluster always ends on a field boundary.
static bool isFarm(Parcel p, float y, float roadD) {
    float cluster = fbm(floor(p.id) * kParcel / 2600.0 + 41.0, 3) + 0.15 * (1.0 - smoothstep(100.0, 700.0, roadD));
    return cluster > 0.10 && y > kShore && y < 75.0;
}

static float treeLine(float2 xz) { return 430.0 + 80.0 * noise(xz / 1500.0); }

static float forestDensity(float2 xz, float y) {
    return fbm(xz / 1300.0 + 11.0, 3) + 0.35 * smoothstep(40.0, 260.0, y) - 0.06;
}

static float coniferShare(float y) { return 0.1 + 0.85 * smoothstep(140.0, 380.0, y); }

// Stand type at a point: whole part 1 for conifers, fraction a slowly varying tint.
static float standId(float2 xz, float y) {
    return (noise(xz / 900.0 + 7.0) * 0.3 + coniferShare(y) > 0.5 ? 1.0 : 0.0) + 0.5 + 0.5 * noise(xz / 120.0);
}

// Whether forest covers this point, with a ragged outline; id as standId.
static bool forest(float2 xz, float y, thread float &id) {
    id = 0.0;
    if (y < 2.5 || y > treeLine(xz)) return false;
    if (forestDensity(xz, y) + 0.012 * noise(xz / 14.0) <= 0.0) return false;
    id = standId(xz, y);
    return true;
}

struct Surface {
    float y;        // top surface: water line, canopy, roof, hedge or ground
    float ground;
    float cavity;
    float cover;
    float id;
    int kind;
    bool farm;
    bool village;
    Parcel parcel;
    float roadD;
    float riverD;
};

// Cover on known bare ground. mesh: only cover wide enough for clipmap vertices (forest),
// so thin hedges and houses never spike a single vertex, and canopy relief fades with detail.
static Surface coverAt(float2 xz, float ground, float cavity, float detail, bool mesh) {
    Surface s;
    s.ground = ground;
    s.cavity = cavity;
    s.cover = 0.0;
    s.id = 0.0;
    s.kind = Ground;
    s.farm = false;
    float riverS = riverSigned(xz);
    s.riverD = abs(riverS);
    float2 w = warped(xz);
    s.parcel = parcel(w);
    Roads r = roads(w, riverS);
    s.roadD = r.dist;
    bool lowland = ground < kLowland;
    s.village = lowland && inVillage(w, r);
    bool road = lowland && r.dist < kRoadHalf;
    if (ground < 0.0) {
        s.kind = road ? Road : Water;
        s.y = road ? 1.5 : 0.0;     // causeway deck
        return s;
    }
    s.y = ground;
    if (road) { s.kind = Road; return s; }
    float id;
    float h = lowland ? houses(w, r, id) : 0.0;
    if (h > 0.0) {
        s.kind = House;
        s.id = id;
        s.cover = mesh ? 0.0 : h;
        s.y += s.cover;
        return s;
    }
    Roads centre = roads((floor(s.parcel.id) + 0.5) * kParcel, riverS);
    s.farm = isFarm(s.parcel, ground, centre.dist);
    if (s.farm) {
        if (!mesh && s.parcel.hedged && s.parcel.edge < 2.4) {
            s.kind = Hedge;
            s.cover = (3.0 + 7.0 * smoothstep(0.35, 0.7, noise(xz / 7.0))) * max(detail, 0.3);
        }
    } else if (r.dist > 12.0 && !s.village && forest(xz, ground, id)) {
        s.kind = Tree;
        s.id = id;
    }
    s.y += s.cover;
    return s;
}

static Surface surface(float2 xz, int erosionOctaves, float detail, bool mesh) {
    float cavity;
    float ground = groundHeight(xz, erosionOctaves, cavity);
    return coverAt(xz, ground, cavity, detail, mesh);
}

// MARK: - Colour

static float3 cropColour(Parcel p, float2 xz, float detail) {
    float r = hash12(p.id * 1.37 + 0.2);
    // Mostly grass, so the farmland reads as green country with a few tilled fields.
    float3 crop = r < 0.25 ? float3(0.09, 0.17, 0.04)      // pasture
                : r < 0.42 ? float3(0.16, 0.22, 0.06)      // hay meadow
                : r < 0.60 ? float3(0.36, 0.33, 0.15)      // wheat
                : r < 0.78 ? float3(0.20, 0.15, 0.10)      // ploughed
                : r < 0.86 ? float3(0.11, 0.19, 0.05)      // young crop
                :            float3(0.26, 0.26, 0.13);     // fallow
    crop *= 0.7 + 0.25 * hash12(p.id + 0.9);
    crop *= 0.9 + 0.2 * fbm(xz / 40.0, 3) * detail;
    // Furrows fade before they are finer than a pixel, so they never alias into moire.
    float furrow = detail * detail;
    if (r >= 0.60 && r < 0.78) crop *= 0.90 + 0.14 * furrow * (0.5 + 0.5 * sin(dot(xz, p.axis) * 1.6));
    else if (r >= 0.42 && r < 0.60) crop *= 0.96 + 0.05 * furrow * sin(dot(xz, p.axis) * 0.5);
    return crop;
}

static float3 groundColour(Surface s, float2 xz, float slope, float detail) {
    float y = s.ground;
    float cavityShade = mix(0.75, 1.05, smoothstep(-0.3, 0.6, s.cavity + 0.4));
    if (s.farm) return cropColour(s.parcel, xz, detail) * cavityShade;

    float v = fbm(xz / 300.0, 4) * 0.5 + 0.5;
    float3 meadow = mix(float3(0.07, 0.13, 0.045), float3(0.13, 0.18, 0.07), v);
    meadow = mix(meadow, float3(0.24, 0.25, 0.11), smoothstep(0.15, 0.35, fbm(xz / 600.0 + 3.0, 3)) * 0.3);
    meadow = mix(meadow, float3(0.16, 0.19, 0.08), smoothstep(150.0, 400.0, y));  // upland heath
    // Clumps, bushes and worn patches keep large slopes from reading as felt.
    float3 col = meadow * (0.8 + 0.4 * (0.5 + 0.5 * fbm(xz / 45.0, 3)));

    // Villages stand on trampled yards and gardens; road verges are dusty.
    if (s.village) col = mix(col, float3(0.36, 0.33, 0.19), 0.6);
    if (y < kLowland) col = mix(float3(0.32, 0.30, 0.20), col, smoothstep(kRoadHalf, kRoadHalf + 2.5, s.roadD));

    // Shore: a narrow band of lusher wet meadow, then mud and sand right at the water.
    col = mix(float3(0.19, 0.28, 0.09), col, smoothstep(2.0, 4.5, y + 1.5 * noise(xz / 40.0)));
    col = mix(float3(0.44, 0.40, 0.30), col, step(1.6 + 0.8 * noise(xz / 15.0), y));
    col = mix(float3(0.36, 0.33, 0.25), col, step(66.0, s.riverD));

    // Above the tree line is dry grass with rock only where it is steep, so summits never
    // read as snow.
    col = mix(col, float3(0.22, 0.22, 0.11), smoothstep(0.0, 80.0, y - treeLine(xz)));
    float3 rock = mix(float3(0.17, 0.16, 0.14), float3(0.27, 0.25, 0.22), fbm(xz / 25.0, 3) * 0.5 + 0.5);
    float rocky = smoothstep(0.30, 0.38, slope + 0.12 * fbm(xz / 80.0, 3));
    col = mix(col, rock, saturate(rocky));
    return col * cavityShade;
}

// Foliage albedo for a stand id (standId).
static float3 foliage(float id) {
    float r = fract(id);
    return id >= 1.0 ? float3(0.025, 0.05, 0.035) * (0.8 + 0.4 * r)
                     : mix(float3(0.04, 0.08, 0.03), float3(0.07, 0.10, 0.04), r);
}

// Albedo of everything but water, which is view dependent (waterColour).
static float3 surfaceAlbedo(Surface s, float2 xz, float slope, float detail) {
    switch (s.kind) {
    case Tree:
        // Stands of lighter and darker trees; hashing the smooth id here would band.
        return foliage(s.id) * (0.8 + 0.4 * (0.5 + 0.5 * fbm(xz / 60.0, 2)));
    case Hedge:
        return float3(0.04, 0.09, 0.03);
    case Road: {
        // The valley road is metalled; the grid roads are chalk and dirt tracks.
        bool metalled = abs(s.riverD - 240.0) < kRoadHalf;
        float3 road = metalled ? float3(0.26, 0.26, 0.25) : float3(0.38, 0.35, 0.27);
        return road * (0.92 + 0.16 * noise(xz / 5.0) * detail);
    }
    case House: {
        float3 roof = s.id < 0.55 ? float3(0.42, 0.17, 0.10) : float3(0.24, 0.25, 0.28);
        return roof * (0.85 + 0.3 * fract(s.id * 7.0));
    }
    case Water:
        return float3(0.10, 0.12, 0.10);
    default:
        return groundColour(s, xz, slope, detail);
    }
}

// MARK: - Standing trees

struct StandingTree {
    float height;       // metres; 0 where no tree stands
    float radius;       // of the crown at its widest
    float widest;       // fraction of the height where the crown is widest
    float bottom;       // fraction of the height where the crown starts above its trunk
    float3 albedo;
};

// The tree standing at xz, for the tree layer in Terrain.metal. Forest stands thin out toward
// their edges and stray a little beyond them; hedged field boundaries carry hedgerow trees;
// meadows get the odd lone tree. pick and look are independent hashes in [0, 1).
static StandingTree standingTree(float2 xz, float ground, float cavity, float pick, float look) {
    StandingTree t = { 0.0, 0.0, 0.0, 0.0, 0.0 };
    if (ground < 1.0 || ground > treeLine(xz)) return t;
    Surface s = coverAt(xz, ground, cavity, 1.0, false);
    if (s.kind == Road || s.kind == House || s.kind == Water || s.village || s.roadD < 8.0) return t;
    float d = forestDensity(xz, ground);
    float chance = s.kind == Tree ? mix(0.5, 1.0, smoothstep(0.0, 0.03, d))
                 : s.farm ? (s.parcel.hedged && s.parcel.edge < 5.0 ? 0.45 : 0.0)
                 : d > -0.04 ? 0.35 * smoothstep(-0.04, 0.0, d)
                 : 0.012;
    if (pick >= chance) return t;
    float id = s.kind == Tree ? s.id : standId(xz, ground);
    bool conifer = id >= 1.0 && !s.farm;
    float stand = 1.0 + 0.25 * noise(xz / 70.0);
    t.height = stand * (conifer ? 12.0 + 10.0 * look : 9.0 + 7.0 * look);
    // Conifers are cones to the ground; broadleaf crowns are rounded and stand on trunks.
    t.radius = t.height * (conifer ? 0.27 : 0.42 + 0.1 * look);
    t.widest = conifer ? 0.0 : 0.5;
    t.bottom = conifer ? 0.0 : 0.22;
    t.albedo = foliage(conifer ? max(id, 1.0) : fract(id)) * (0.8 + 0.35 * look)
             * float3(1.0 + 0.3 * (look - 0.5), 1.0, 1.0 - 0.3 * (look - 0.5));
    return t;
}

// MARK: - Sky and clouds

static float3 skyColor(float3 rd, float3 sun, bool disc) {
    float s = max(dot(rd, sun), 0.0);
    float y = max(rd.y, 0.0);
    float3 col = mix(float3(0.70, 0.80, 0.90), float3(0.22, 0.42, 0.78), pow(y, 0.45));
    col += float3(1.0, 0.75, 0.45) * 0.35 * pow(s, 8.0);
    col += float3(1.0, 0.9, 0.7) * 0.25 * pow(s, 64.0);
    if (disc) col += float3(1.0, 0.95, 0.85) * 40.0 * smoothstep(0.9997, 0.99985, s);
    return col;
}

// Cumulus as a field of puffs. Coverage sets each column's radius; the column rises as a
// dome with a flat base and a soft rounded top whose height follows the radius, so puffs
// vary in thickness, and small noise erodes the rim so no edge is straight or square.
static float cloudCoverage(float2 xz, int octaves) {
    float2 p = xz / 3200.0;
    float c = fbm(p + 0.3 * float2(fbm(p * 2.0, 3), fbm(p * 2.0 + 5.0, 3)), octaves);
    return smoothstep(0.02, 0.45, c);
}

static float cloudDensity(float3 p, float coverage, int octaves) {
    float h = (p.y - kCloudBase) / (kCloudTop - kCloudBase);
    float top = 0.15 + 0.85 * coverage;
    float dome = saturate(h / 0.08) * saturate((top - h) / (0.5 * top));
    float den = coverage * dome;
    float rim = 0.5 + 0.5 * fbm(p.xz / 280.0 + h * 1.5, octaves);
    return saturate(den - 0.35 * rim * (1.0 - den));
}

// Sunlight reaching the ground through the cloud layer; penumbra-wide and skylight-filled.
static float cloudShadow(float2 xz, float y, float3 sun) {
    float2 at = xz + sun.xz / max(sun.y, 0.1) * (kCloudBase - y);
    return 1.0 - 0.65 * smoothstep(0.05, 0.6, cloudCoverage(at, 4));
}

// Lit cloud layer along a ray; colour (rgb) and coverage (a). Jitter hides step banding.
static float4 marchClouds(float3 ro, float3 rd, float3 sun, float maxT, float jitter, int steps, int octaves) {
    if (abs(rd.y) < 1e-3) return 0.0;
    float t0 = (kCloudBase - ro.y) / rd.y, t1 = (kCloudTop - ro.y) / rd.y;
    if (t0 > t1) { float tmp = t0; t0 = t1; t1 = tmp; }
    t0 = max(t0, 0.0); t1 = min(t1, maxT);
    if (t1 <= t0) return 0.0;
    float4 sum = 0.0;
    float dt = (t1 - t0) / float(steps);
    for (int i = 0; i < steps && sum.a < 0.98; i++) {
        float3 p = ro + rd * (t0 + dt * (float(i) + jitter));
        float coverage = cloudCoverage(p.xz, octaves);
        if (coverage <= 0.0) continue;
        float den = cloudDensity(p, coverage, 3);
        if (den <= 0.0) continue;
        float h = (p.y - kCloudBase) / (kCloudTop - kCloudBase);
        float toward = cloudCoverage(p.xz + sun.xz * 300.0, octaves);
        float lit = saturate(0.8 - 1.6 * (toward - coverage)) * (0.45 + 0.55 * saturate(h / (0.15 + 0.85 * coverage)));
        lit += 0.25 * (1.0 - den);      // thin rims glow
        float3 col = mix(float3(0.52, 0.58, 0.70), float3(1.08, 1.03, 0.98), saturate(lit));
        float alpha = 1.0 - exp(-den * dt * 0.012);
        sum.rgb += col * alpha * (1.0 - sum.a);
        sum.a += alpha * (1.0 - sum.a);
    }
    return sum * exp(-0.00004 * t0);
}

// MARK: - Lighting

// Sun, sky and ground bounce on a surface; shadow scales the sun, occ the sky and bounce.
static float3 surfaceLight(float3 n, float3 sun, float shadow, float occ) {
    float diff = max(dot(n, sun), 0.0) * shadow;
    float sky = (0.5 + 0.5 * n.y) * occ;
    float bounce = max(dot(n, normalize(float3(-sun.x, 0.0, -sun.z))), 0.0) * 0.2 * occ;
    return float3(1.0, 0.92, 0.80) * 3.2 * diff
         + float3(0.40, 0.55, 0.80) * 0.75 * sky
         + float3(0.45, 0.40, 0.30) * bounce;
}

static float3 waterColour(Surface s, float2 xz, float3 rd, float3 sun, float light) {
    float depth = -s.ground;
    float3 r = reflect(rd, normalize(float3(0.02 * noise(xz / 6.0), 1.0, 0.02 * noise(xz / 6.0 + 3.0))));
    float fres = 0.02 + 0.98 * pow(1.0 - max(-rd.y, 0.0), 5.0);
    float3 body = mix(float3(0.16, 0.17, 0.11), float3(0.02, 0.05, 0.06), smoothstep(0.0, 6.0, depth));
    float3 lit = body * (0.6 + 1.2 * light);
    float glint = pow(max(dot(r, sun), 0.0), 400.0) * 30.0 * light;
    return mix(lit, skyColor(r, sun, false), fres) + glint;
}

// Overlapping crowns on a jittered 6 m grid, each a dome of its own size. Returns the
// outward tilt of the topmost dome here (xy) and how open the spot is (z): 1 on a crown
// top, low where it sinks between crowns.
static float3 crown(float2 xz) {
    float2 g = xz / 6.0, ip = floor(g), fp = fract(g);
    float top = 0.0;
    float2 tilt = 0.0;
    for (int i = -1; i <= 1; i++)
    for (int j = -1; j <= 1; j++) {
        float2 cell = ip + float2(i, j);
        float2 jitter = hash22(cell);
        float2 d = float2(i, j) + 0.1 + 0.8 * jitter - fp;
        float radius = 0.45 + 0.55 * hash12(cell + 4.7);
        float q = length(d) / radius;
        if (q >= 1.0) continue;
        float h = sqrt(1.0 - q * q) * (0.5 + 0.5 * jitter.x) * (0.6 + 0.4 * radius);
        if (h > top) { top = h; tilt = -d / radius; }
    }
    return float3(tilt, smoothstep(0.0, 0.75, top));
}

// Light reaching a canopy point: gaps between crowns stay in shade; with distance this
// settles to the canopy's average.
static float canopyShade(Surface s, float2 xz, float detail) {
    if (s.kind != Tree) return 1.0;
    // Leaf clumps up close; clearings and stands of different height at every distance.
    float leaves = 0.8 + 0.4 * (0.5 + 0.5 * noise(xz / 1.4));
    float open = mix(0.7, mix(0.3, 1.0, crown(xz).z) * mix(1.0, leaves, detail), detail);
    return open * (0.75 + 0.5 * (0.5 + 0.5 * fbm(xz / 35.0, 2)));
}

// Tree crowns and roofs get per-pixel relief the mesh does not carry.
static float3 detailNormal(Surface s, float3 n, float2 xz, float detail) {
    if (s.kind == Tree) {
        float3 c = crown(xz);
        n += float3(c.x, 0.0, c.y) * 0.8 * detail;
    } else if (s.kind == House) {
        float2 f = fract(warped(xz) / 18.0) - 0.5;
        n += float3(abs(f.x) > abs(f.y) ? sign(f.x) : 0.0, 0.0, abs(f.y) >= abs(f.x) ? sign(f.y) : 0.0) * 0.6;
    }
    return normalize(n);
}

// Filmic curve and grade into display-linear range; the host adds gamma if its target is
// not sRGB. Graded toward the look of modern arcade flight games: exposed low so foliage
// sits near black, saturated greens, cool shadows and warm highlights.
static float3 tonemap(float3 x) {
    x *= 0.30;
    float3 c = saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = max(mix(float3(l), c, 1.15), 0.0);
    c *= mix(float3(0.88, 1.0, 1.06), float3(1.03, 1.0, 0.96), smoothstep(0.02, 0.4, l));
    return saturate(pow(c, 1.08));
}

// Aerial perspective in display space: exponential height fog with a scale height of
// 900 m, so valleys are hazier than ridges. visibility is the sea-level distance at which
// 95% of the view is haze; the haze brightens and warms toward the sun.
static float3 aerial(float3 col, float t, float3 ro, float3 rd, float3 sun, float3 haze, float visibility) {
    const float b = 1.0 / 900.0;
    float ry = abs(rd.y) < 1e-4 ? 1e-4 : rd.y;
    float optical = (1.6 / visibility) * exp(-ro.y * b) * (1.0 - exp(-t * ry * b)) / (ry * b);
    float s = pow(max(dot(rd, sun), 0.0), 6.0);
    float3 lit = mix(haze, saturate(haze * float3(1.15, 1.08, 0.95)), s);
    return mix(lit, col, exp(-optical));
}
