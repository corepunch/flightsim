// Procedural space skybox, baked once at startup into a cubemap.
//
// Pass 1 (bakeNebula, low res): ray-marches a domain-warped fbm density field
//   through a spherical shell around the viewer, accumulating emission
//   (H-alpha / OIII style palette) and dust absorption. Output: rgb = emitted
//   light, a = transmittance (how much of what lies behind shows through).
// Pass 2 (composeSky, full res): per texel, combines a deep-space gradient,
//   a Milky Way band with dust lanes, three layers of cellular-hashed stars
//   (anti-aliased to the texel footprint, blackbody-ish colours), the nebula
//   from pass 1, a gas giant with atmospheric rim + halo, and an HDR sun.
//
// Directions follow the Metal/GL cube convention (+X,-X,+Y,-Y,+Z,-Z).

#include <metal_stdlib>
using namespace metal;

struct SkyParams {
    float4 sunDir;        // xyz toward sun, w = angular radius (rad)
    float4 galaxyNormal;  // xyz normal of the galactic plane
    float4 galaxyCenter;  // xyz toward galactic core
    float4 planetDir;     // xyz toward planet, w = angular radius (rad)
    float4 planetAxis;    // xyz planet spin axis
    uint faceSize;
    uint seed;
    uint face;
    uint pad;
};

// ---------------------------------------------------------------- hashing

static uint3 pcg3d(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

static float3 hash33(int3 c, uint seed) {
    uint3 h = pcg3d(as_type<uint3>(c) + uint3(seed, seed * 7u + 3u, seed * 13u + 5u));
    return float3(h) * (1.0 / 4294967295.0);
}

// Quintic gradient noise, roughly in [-0.8, 0.8].
static float gnoise(float3 p, uint seed) {
    int3 i = int3(floor(p));
    float3 f = p - floor(p);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    #define G(ox, oy, oz) dot(hash33(i + int3(ox, oy, oz), seed) * 2.0 - 1.0, f - float3(ox, oy, oz))
    float n000 = G(0, 0, 0), n100 = G(1, 0, 0), n010 = G(0, 1, 0), n110 = G(1, 1, 0);
    float n001 = G(0, 0, 1), n101 = G(1, 0, 1), n011 = G(0, 1, 1), n111 = G(1, 1, 1);
    #undef G
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

static float fbm(float3 p, int octaves, uint seed) {
    float sum = 0.0, amp = 0.5;
    for (int k = 0; k < octaves; k++) {
        sum += amp * gnoise(p, seed + uint(k) * 101u);
        p = p * 2.03 + float3(1.7, 9.2, 3.1);
        amp *= 0.5;
    }
    return sum;
}

// SceneKit samples a Metal cube texture with Z mirrored relative to its
// right-handed world space; content is evaluated in world space.
static float3 toWorld(float3 texDir) { return float3(texDir.x, texDir.y, -texDir.z); }

static float3 cubeDir(uint face, float2 uv) {
    switch (face) {
        case 0:  return normalize(float3( 1.0, -uv.y, -uv.x));
        case 1:  return normalize(float3(-1.0, -uv.y,  uv.x));
        case 2:  return normalize(float3( uv.x,  1.0,  uv.y));
        case 3:  return normalize(float3( uv.x, -1.0, -uv.y));
        case 4:  return normalize(float3( uv.x, -uv.y,  1.0));
        default: return normalize(float3(-uv.x, -uv.y, -1.0));
    }
}

// ---------------------------------------------------------------- nebula

kernel void bakeNebula(texturecube<half, access::write> out [[texture(0)]],
                       constant SkyParams &P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= P.faceSize || gid.y >= P.faceSize) return;
    float2 uv = (float2(gid) + 0.5) / float(P.faceSize) * 2.0 - 1.0;
    float3 d = toWorld(cubeDir(P.face, uv));

    // Large-scale envelope keeps the nebula to a few regions of the sky.
    float env = smoothstep(0.02, 0.32, fbm(d * 1.1, 3, P.seed + 500u) + 0.08);
    if (env < 0.001) {
        out.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid, P.face);
        return;
    }

    const int STEPS = 28;
    const float dt = 1.0 / float(STEPS);
    float3 col = 0.0;
    float T = 1.0;
    for (int i = 0; i < STEPS; i++) {
        float t = (float(i) + 0.5) * dt;
        float3 p = d * (1.0 + t * 1.6);
        // Domain warp (Inigo Quilez style): offset the lookup by another fbm.
        float3 q = float3(fbm(p * 1.4,              2, P.seed + 1u),
                          fbm(p * 1.4 + float3(5.2), 2, P.seed + 2u),
                          fbm(p * 1.4 + float3(9.7), 2, P.seed + 3u));
        float n = fbm(p * 2.6 + q * 2.2, 5, P.seed + 4u);
        float dens = max(n * 1.7 + 0.08, 0.0) * env;
        float dust = max(fbm(p * 5.0 + q * 1.5, 2, P.seed + 9u) + 0.05, 0.0) * env;

        float3 hAlpha = float3(0.95, 0.22, 0.42);
        float3 oIII   = float3(0.12, 0.58, 0.90);
        float3 warm   = float3(1.00, 0.62, 0.30);
        float3 em = mix(oIII, hAlpha, saturate(q.x * 1.8 + 0.5));
        em = mix(em, warm, saturate(q.z * 2.5 - 0.3));

        col += T * em * dens * dens * 2.4 * dt;
        T *= exp(-(dust * dust * 10.0 + dens * 0.6) * dt);
    }
    out.write(half4(half3(col), half(T)), gid, P.face);
}

// ---------------------------------------------------------------- stars

static float3 starColor(float t) {
    // cool red/orange -> sun-like white -> hot blue-white
    float3 cool = float3(1.00, 0.62, 0.38);
    float3 mid  = float3(1.00, 0.94, 0.88);
    float3 hot  = float3(0.66, 0.78, 1.00);
    return t < 0.55 ? mix(cool, mid, t / 0.55) : mix(mid, hot, (t - 0.55) / 0.45);
}

// One layer of stars: each cell of a 3D grid in a thin shell of radius `scale`
// may hold one star. Stars are splatted as Gaussians sized to the texel.
static float3 starLayer(float3 d, float scale, float density, float brightness,
                        float sigma, uint seed)
{
    float3 p = d * scale;
    int3 c0 = int3(floor(p));
    float3 acc = 0.0;
    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) {
        int3 c = c0 + int3(x, y, z);
        float3 h = hash33(c, seed);
        if (h.x > density) continue;
        float3 sp = float3(c) + 0.15 + 0.7 * hash33(c, seed + 7919u);
        float r = length(sp);
        if (abs(r - scale) > 0.5) continue;           // keep stars in a thin shell
        float3 sd = sp / r;
        float a = length(d - sd);                      // ~ angular distance
        float mag = pow(h.y, 14.0);                    // few bright, many faint
        float b = brightness * (0.015 + mag);
        acc += starColor(h.z) * b * exp(-a * a / (2.0 * sigma * sigma));
    }
    return acc;
}

// ---------------------------------------------------------------- compose

kernel void composeSky(texturecube<half, access::write> out [[texture(0)]],
                       texturecube<half> neb [[texture(1)]],
                       constant SkyParams &P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= P.faceSize || gid.y >= P.faceSize) return;
    float2 uv = (float2(gid) + 0.5) / float(P.faceSize) * 2.0 - 1.0;
    float3 texDir = cubeDir(P.face, uv);
    float3 d = toWorld(texDir);
    float pix = 1.5707963 / float(P.faceSize);        // texel angular size

    // Deep space base, slightly bluer away from the galactic plane.
    float lat = dot(d, P.galaxyNormal.xyz);
    float3 col = mix(float3(0.0020, 0.0022, 0.0035), float3(0.0010, 0.0016, 0.0040), abs(lat));

    // Milky Way: gaussian band + bulge, broken up by fbm, cut by dust lanes.
    float band  = exp(-lat * lat / (2.0 * 0.13 * 0.13));
    float bulge = exp(-(1.0 - dot(d, P.galaxyCenter.xyz)) * 3.5) * exp(-lat * lat / (2.0 * 0.22 * 0.22));
    float structure = saturate(0.55 + 0.9 * fbm(d * 6.0, 5, P.seed + 40u));
    float lane = smoothstep(-0.05, 0.25, fbm(d * 4.5 + float3(3.0), 4, P.seed + 41u))
               * exp(-lat * lat / (2.0 * 0.045 * 0.045));
    // Keep the warm core subdued so it doesn't wash out the nearby sun streak.
    float3 galaxy = (float3(0.50, 0.58, 0.78) * band * structure + float3(1.0, 0.78, 0.52) * bulge * 0.35) * 0.09;
    galaxy *= 1.0 - 0.9 * lane;
    col += galaxy;

    // Stars; the faint layers cluster toward the galactic plane.
    float sigma = pix * 0.6;
    float3 stars = starLayer(d, 45.0, 0.22, 7.0, sigma, P.seed + 100u)
                 + starLayer(d, 130.0, 0.20 * (0.5 + 1.5 * band), 1.6, sigma, P.seed + 200u)
                 + starLayer(d, 320.0, 0.14 * (0.3 + 2.0 * band), 0.6, sigma, P.seed + 300u);
    stars *= 1.0 - 0.8 * lane;

    // Nebula (absorbs what is behind it, emits on top).
    constexpr sampler cs(filter::linear, address::clamp_to_edge);
    float4 nb = float4(neb.sample(cs, texDir));
    col = (col + stars) * nb.a + nb.rgb;

    // Gas giant with atmosphere.
    float3 pc = P.planetDir.xyz;
    float pr = sin(P.planetDir.w);
    float b = dot(d, pc);
    float s = sqrt(max(1.0 - b * b, 0.0));             // sin of angle from planet centre
    if (b > 0.0) {
        float3 sun = P.sunDir.xyz;
        // Halo: scattering in the outer atmosphere, brighter toward the sun.
        float h = (s - pr) / pr;
        if (h > 0.0) {
            float3 hn = normalize(d * b - pc);
            float lit = saturate(dot(hn, sun) * 0.9 + 0.25);
            col += float3(0.35, 0.55, 1.0) * exp(-h * 22.0) * lit * 0.6;
        }
        float coverage = smoothstep(-pix, pix, pr - s);
        if (coverage > 0.0) {
            float disc = max(b * b - (1.0 - pr * pr), 0.0);
            float3 hit = d * (b - sqrt(disc));
            float3 N = normalize(hit - pc);
            float plat = dot(N, P.planetAxis.xyz);
            float warp = fbm(N * 3.0, 4, P.seed + 60u);
            float bands = fbm(float3(plat * 9.0 + warp * 0.9, warp * 0.5, 0.0), 4, P.seed + 61u);
            float3 surf = mix(float3(0.82, 0.70, 0.55), float3(0.48, 0.30, 0.20), smoothstep(-0.2, 0.25, bands));
            surf = mix(surf, float3(0.92, 0.88, 0.80), smoothstep(0.25, 0.45, fbm(N * 14.0, 3, P.seed + 62u)) * 0.3);
            float ndl = dot(N, sun);
            float diff = smoothstep(-0.08, 0.35, ndl) * saturate(ndl * 0.8 + 0.2);
            float rim = pow(1.0 - saturate(dot(N, -d)), 3.0);
            float3 atm = float3(0.35, 0.55, 1.0) * rim * saturate(ndl + 0.35) * 0.9;
            float3 planet = surf * diff * 0.55 + atm;
            col = mix(col, planet, coverage);
        }
    }

    // Keep the sky glow close to the HDR sun. The HUD draws the horizontal flare.
    float ca = clamp(dot(d, P.sunDir.xyz), -1.0, 1.0);
    float ang = acos(ca);
    float rs = P.sunDir.w;
    float3 sunCol = float3(1.0, 0.93, 0.82);
    col += sunCol * smoothstep(rs, rs * 0.75, ang) * 80.0;
    col += sunCol * exp(-ang / 0.02) * 2.5;

    out.write(half4(half3(col), 1.0h), gid, P.face);
}
