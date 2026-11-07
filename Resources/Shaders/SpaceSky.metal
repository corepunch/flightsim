// Soft sky colours live on a small mesh. Stars and the planet are shaded at
// screen resolution; no cubemap or full-screen floating-point target is needed.
#include <metal_stdlib>
using namespace metal;

// Runtime Metal compilation cannot resolve SDK framework headers on devices.
// This is the public SceneKit frame-buffer layout through viewportSize.
enum { SCNVertexSemanticPosition = 0, SCNVertexSemanticColor = 3 };
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

struct SkyParams {
    float4 sunDir, galaxyNormal, galaxyCenter, planetDir, planetAxis;
    uint seed, vertexCount;
    uint2 pad;
};
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


static float4 nebula(float3 d, constant SkyParams &P) {
    // Large-scale envelope keeps the nebula to a few regions of the sky.
    float env = smoothstep(0.02, 0.32, fbm(d * 1.1, 3, P.seed + 500u) + 0.08);
    if (env < 0.001) {
        return float4(0, 0, 0, 1);
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
    return float4(col, T);
}

kernel void colourSkyMesh(device const float3 *directions [[buffer(0)]],
                          device half4 *colours [[buffer(1)]],
                          constant SkyParams &P [[buffer(2)]],
                          uint index [[thread_position_in_grid]]) {
    if (index >= P.vertexCount) return;
    float3 d = normalize(directions[index]);
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

    float4 nb = nebula(d, P);
    colours[index] = half4(half3(col * nb.a + nb.rgb), 1);
}

struct SkyVertex {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
    half4 colour [[attribute(SCNVertexSemanticColor)]];
};
struct SkyVarying {
    float4 position [[position]];
    float3 direction;
    half3 colour;
};
vertex SkyVarying skyVertex(SkyVertex in [[stage_in]],
                            constant SCNSceneBuffer &scn_frame [[buffer(0)]]) {
    SkyVarying out;
    // Ignore translation: the sky stays infinitely far away as the ship moves.
    float4 view = scn_frame.viewTransform * float4(in.position, 0);
    out.position = scn_frame.projectionTransform * view;
    out.position.z = out.position.w;
    out.direction = in.position;
    out.colour = in.colour.rgb;
    return out;
}

static float3 displaySky(float3 col) {
    // Keep the sky palette in the display range without camera postprocessing.
    col = max(col, 0.0);
    return col / (1.0 + col);
}

static float skyVignette(float2 pixel, constant SCNSceneBuffer &frame) {
    // Match the old camera's sky falloff without retaining its postprocess targets.
    float2 q = (pixel - frame.viewportSize.zw) / frame.viewportSize.xy * 2 - 1;
    return clamp(1.045 - dot(q * q, float2(0.852, 0.534)), 0.2, 1.0);
}

fragment half4 skyFragment(SkyVarying in [[stage_in]],
                           constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                           constant SkyParams &P [[buffer(2)]]) {
    float3 d = normalize(in.direction);
    float pix = max(length(dfdx(d)), length(dfdy(d)));
    float3 col = float3(in.colour);
    // The sun's disc and corona sit in the sky, so ships and the planet
    // occlude it like any other backdrop. sunDir.w is its angular radius.
    {
        float3 sd = P.sunDir.xyz;
        float sr = P.sunDir.w;
        float a = 2.0 * asin(min(length(d - sd) * 0.5, 1.0));    // angle from the sun's centre, precise near it
        float3 sunColour = float3(1.0, 0.93, 0.82);
        float disc = smoothstep(sr + pix, sr - pix, a);
        float limb = 0.55 + 0.45 * sqrt(saturate(1.0 - (a / sr) * (a / sr)));
        float outside = max(a - sr, 0.0);
        float corona = exp(-outside / (sr * 0.35)) * 1.6 + exp(-outside / (sr * 2.5)) * 0.25 + exp(-a / (sr * 14.0)) * 0.03;
        col += sunColour * (disc * limb * 60.0 + corona * (1.0 - disc));
    }

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

    // The HUD's glare shader adds the lens response on top of this disc.
    return half4(half3(displaySky(col * skyVignette(in.position.xy, scn_frame))), 1);
}

struct StarVertex {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
    float4 colour [[attribute(SCNVertexSemanticColor)]];
};
struct StarVarying {
    float4 position [[position]];
    float size [[point_size]];
    float scale;        // sprite size over a faint star's; bright stars get room for a halo
    half3 colour;
};
vertex StarVarying starVertex(StarVertex in [[stage_in]],
                              constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                              constant SkyParams &P [[buffer(2)]]) {
    StarVarying out;
    float4 view = scn_frame.viewTransform * float4(in.position, 0);
    out.position = scn_frame.projectionTransform * view;
    out.position.z = out.position.w;
    // Fixed angular radius keeps stars sharp independently of sky mesh density.
    float brightness = in.colour.a;
    out.scale = clamp(sqrt(brightness * 0.5), 1.0, 4.0);
    out.size = max(1.0, 0.00092 * 3.0 * scn_frame.projectionTransform[1][1] * scn_frame.viewportSize.y) * out.scale;
    if (dot(in.position, P.planetDir.xyz) > cos(P.planetDir.w)) brightness = 0;
    out.colour = half3(in.colour.rgb * brightness);
    return out;
}
fragment half4 starFragment(StarVarying in [[stage_in]], float2 uv [[point_coord]],
                            constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                            constant SkyParams &P [[buffer(2)]]) {
    // r is measured in a faint star's core widths, so every core stays sharp;
    // the extra sprite area of a bright star holds a soft halo and faint spikes.
    float2 r = (uv - 0.5) * 6 * in.scale;
    float extra = in.scale - 1.0;
    float halo = exp(-dot(r, r) / (2.0 * in.scale * in.scale)) * 0.06 * extra;
    float spikes = (exp(-abs(r.x) * 2.5) * exp(-abs(r.y) / in.scale) + exp(-abs(r.y) * 2.5) * exp(-abs(r.x) / in.scale)) * 0.04 * extra;
    float edge = 1.0 - smoothstep(0.7, 1.0, length(uv - 0.5) * 2.0);
    float glow = (exp(-dot(r, r) * 0.5) + (halo + spikes) * edge) * skyVignette(in.position.xy, scn_frame);
    return half4(half3(displaySky(float3(in.colour) * glow)), 1);
}
