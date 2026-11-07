// Reference renderer for the procedural landscape in Resources/Shaders/TerrainCommon.metal,
// which Tools/TerrainPreview.m prepends: a raymarcher with soft shadows and volumetric
// clouds, for judging the rules and colours before the clipmap draws them in the game.

struct Params {
    float4 camPos;      // xyz, w = vertical fov in radians
    float4 camTarget;   // xyz
    float4 sunDir;      // xyz toward the sun
    uint4 size;         // width, height, row offset, samples per axis
};

static float detailAt(float t) { return 1.0 - smoothstep(1400.0, 3800.0, t); }

static float raymarch(float3 ro, float3 rd, float tmax) {
    float t = 1.0, tPrev = 1.0;
    for (int i = 0; i < 500 && t < tmax; i++) {
        float detail = detailAt(t);
        float h = ro.y + rd.y * t - surface((ro + rd * t).xz, 3, detail, false).y;
        // Cover edges are near-vertical, so a step can land inside; bisect back to the face.
        if (h < 0.0) {
            float a = tPrev, b = t;
            for (int k = 0; k < 10; k++) {
                float m = 0.5 * (a + b);
                float3 q = ro + rd * m;
                if (q.y > surface(q.xz, 3, detail, false).y) a = m; else b = m;
            }
            return b;
        }
        if (h < 0.001 * t + 0.02) return t;
        tPrev = t;
        t += min(0.45 * h, 4.0 + 0.5 * h + 0.02 * t);
    }
    return -1.0;
}

static float softShadow(float3 ro, float3 rd, float detail) {
    float res = 1.0, t = 0.5;
    for (int i = 0; i < 96 && t < 6000.0; i++) {
        float3 p = ro + rd * t;
        float h = p.y - surface(p.xz, 3, detail * (1.0 - smoothstep(60.0, 200.0, t)), false).y;
        res = min(res, 12.0 * h / t);
        if (res < 0.001) break;
        t += clamp(h, 0.8 + 0.03 * t, 300.0);
    }
    return smoothstep(0.0, 1.0, res);
}

static float3 coverNormal(float2 xz, float t, float detail) {
    float e = max(0.25, 0.001 * t);
    float hx = surface(xz + float2(e, 0), 5, detail, false).y - surface(xz - float2(e, 0), 5, detail, false).y;
    float hz = surface(xz + float2(0, e), 5, detail, false).y - surface(xz - float2(0, e), 5, detail, false).y;
    return normalize(float3(-hx, 2.0 * e, -hz));
}

static float3 groundNormal(float2 xz, float t) {
    float e = max(1.0, 0.002 * t);
    float hx = groundOnly(xz + float2(e, 0), 4) - groundOnly(xz - float2(e, 0), 4);
    float hz = groundOnly(xz + float2(0, e), 4) - groundOnly(xz - float2(0, e), 4);
    return normalize(float3(-hx, 2.0 * e, -hz));
}

// Darkens ground and lower crowns that sit below neighbouring cover.
static float coverOcclusion(float2 xz, float y, float detail) {
    float occ = 0.0;
    for (int i = 0; i < 6; i++) {
        float a = i * 1.0472;
        float2 o = float2(cos(a), sin(a)) * 7.0;
        occ += saturate((surface(xz + o, 3, detail, false).y - y) / 14.0);
    }
    return 1.0 - 0.65 * occ / 6.0;
}

// Haze as Games/DawnPatrol/Levels/01-morning-patrol.json declares it, display-linear.
constant float3 kHaze = float3(0.406, 0.539, 0.624);
constant float kVisibility = 12000.0;

static float3 shade(float3 ro, float3 rd, float t, float3 sun) {
    float3 p = ro + rd * t;
    float detail = detailAt(t);
    Surface s = surface(p.xz, 5, detail, false);
    p.y = s.y;
    float3 n = coverNormal(p.xz, t, detail);
    float3 gn = groundNormal(p.xz, t);

    // Shadow rays march the cheaper landform, so start them above it, not inside it.
    float lodBias = max(0.0, surface(p.xz, 3, detail, false).y - p.y);
    float sunShadow = softShadow(p + float3(0, lodBias, 0) + n * 0.3, sun, detail);
    float light = sunShadow * cloudShadow(p.xz, p.y, sun);
    if (s.kind == Water) return waterColour(s, p.xz, rd, sun, light);
    float occ = detail > 0.0 ? mix(1.0, coverOcclusion(p.xz, p.y, detail), detail) : 1.0;
    float shade = canopyShade(s, p.xz, detail);
    n = detailNormal(s, n, p.xz, detail);
    float3 albedo = surfaceAlbedo(s, p.xz, 1.0 - gn.y, detail);
    return albedo * surfaceLight(n, sun, light * shade, occ * shade);
}

// Display-linear colour, hazed and composited as the game does it.
static float3 renderRay(float3 ro, float3 rd, float3 sun, float jitter) {
    const float tmax = 40000.0;
    float t = raymarch(ro, rd, tmax);
    if (t > 0.0) {
        float3 col = aerial(tonemap(shade(ro, rd, t, sun)), t, ro, rd, sun, kHaze, kVisibility);
        float4 c = marchClouds(ro, rd, sun, t, jitter, 40, 6);
        return col * (1.0 - c.a) + tonemap(c.rgb / max(c.a, 1e-4)) * c.a;
    }
    float4 c = marchClouds(ro, rd, sun, tmax, jitter, 40, 6);
    float3 col = tonemap(skyColor(rd, sun, true) * (1.0 - c.a) + c.rgb);
    return mix(col, kHaze, exp(-max(rd.y, 0.0) * 14.0));
}

kernel void renderTerrain(texture2d<float, access::write> out [[texture(0)]],
                          constant Params &P [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint2 px = uint2(gid.x, gid.y + P.size.z);
    if (px.x >= P.size.x || px.y >= P.size.y) return;
    float3 ro = P.camPos.xyz;
    float3 fwd = normalize(P.camTarget.xyz - ro);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float tanHalf = tan(P.camPos.w * 0.5);
    float aspect = float(P.size.x) / float(P.size.y);
    float3 sun = normalize(P.sunDir.xyz);
    uint ss = max(P.size.w, 1u);
    float3 acc = 0.0;
    for (uint sy = 0; sy < ss; sy++)
    for (uint sx = 0; sx < ss; sx++) {
        float2 o = (float2(sx, sy) + 0.5) / float(ss);
        float2 ndc = (float2(px) + o) / float2(P.size.xy) * 2.0 - 1.0;
        float3 rd = normalize(fwd + right * ndc.x * tanHalf * aspect - up * ndc.y * tanHalf);
        // The output texture is not sRGB, so encode gamma here.
        acc += pow(saturate(renderRay(ro, rd, sun, hash12(float2(px) * 1.7 + o * 31.0))), 1.0 / 2.2);
    }
    out.write(float4(acc / float(ss * ss), 1.0), px);
}
