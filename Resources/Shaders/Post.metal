// The post-process technique (Sources/Render/Post.m): what the frame goes through on its
// way from the scene to the screen. The scene is drawn into a texture, its bright parts
// are blurred into two bloom layers (a tight glow at a quarter of the drawable, a wide
// veil at a sixteenth) and the final pass adds them back.
//
// Landscapes draw a display-ready frame, and the final pass grades it: lifted blacks,
// less saturation, a warm cast, a vignette and a trace of colour fringing at the edges.
// The look follows Ace Combat 7 (see POST-REFERENCES.md): its sky light bleeds into
// everything through bloom and haze, so dark ground never reaches black, and a
// per-mission colour filter warms and flattens the frame.
//
// Space draws scene-linear light into a half-float texture (kHDR): the sun, the bright
// stars, engine cores, bolts and fire are many times brighter than white, so what they
// bloom is in proportion to what they emit, and the final pass rolls the sum off into
// the display range, with a faint sideways streak through the brightest lights. A light
// that goes behind a hull stops blooming with no depth read: the bloom is made from
// what the frame shows of it.
//
// The host prepends `constant` definitions for the tuning values before compiling.

#include <metal_stdlib>
using namespace metal;

// Runtime Metal compilation cannot resolve SDK framework headers on devices.
enum { SCNVertexSemanticPosition = 0 };

// Prepended by the host:
//   constant bool kHDR;           the scene holds scene-linear light above white
//   constant float kBloom;        bloom intensity, the share of blurred light added back
//   constant float kBloomKnee;    brightness where light starts to bloom
//   constant float kVignette;     darkening at the corners, 0 to 1
//   constant float kGrade;        strength of the colour filter, 0 to 1

struct QuadVertexIn {
    float4 position [[attribute(SCNVertexSemanticPosition)]];
};
struct QuadVarying {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler postSampler(address::clamp_to_edge, filter::linear);

vertex QuadVarying postQuadVertex(QuadVertexIn in [[stage_in]]) {
    QuadVarying out;
    out.position = float4(in.position.xy, 0.0, 1.0);
    out.uv = float2(in.position.x, -in.position.y) * 0.5 + 0.5;
    return out;
}

static float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static float peak(float3 c) { return max(c.r, max(c.g, c.b)); }

// MARK: - Bloom

// Light above the knee, from a 3x3 box of the scene (the target is a quarter size, so
// this reads a 4x4 block through the bilinear filter) so nothing flickers at the edges.
fragment half4 postBright(QuadVarying in [[stage_in]],
                          texture2d<float> sceneMap [[texture(0)]]) {
    float2 px = 1.0 / float2(sceneMap.get_width(), sceneMap.get_height());
    float3 sum = 0.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            sum += sceneMap.sample(postSampler, in.uv + float2(x, y) * 2.0 * px).rgb;
    float3 c = max(sum / 9.0, 0.0);
    if (kHDR) {
        // What exceeds the knee blooms, by its strongest channel so a saturated bolt
        // glows as readily as white fire. The ceiling keeps one runaway pixel from
        // flooding the frame, and a half-float target from overflowing.
        float m = peak(c);
        float over = max(m - kBloomKnee, 0.0);
        c *= over / max(m, 1e-4);
        return half4(half3(min(c, 64.0)), 1.0h);
    }
    // A soft knee: light fades in over the stop below the knee instead of switching on.
    float l = luminance(c);
    float w = smoothstep(kBloomKnee * 0.5, kBloomKnee, l);
    return half4(half3(c * w), 1.0h);
}

// One direction of a Gaussian blur: nine reads `step` texels of the map apart, for a
// sigma of about 1.6 steps.
constant float kBlurWeights[5] = { 0.2270, 0.1945, 0.1216, 0.0541, 0.0162 };
static float3 blur(texture2d<float> map, float2 uv, float2 step) {
    constant float *weights = kBlurWeights;
    float2 px = step / float2(map.get_width(), map.get_height());
    float3 c = map.sample(postSampler, uv).rgb * weights[0];
    for (int i = 1; i < 5; i++) {
        float2 o = px * float(i);
        c += (map.sample(postSampler, uv + o).rgb + map.sample(postSampler, uv - o).rgb) * weights[i];
    }
    return c;
}

fragment half4 postBlurH(QuadVarying in [[stage_in]], texture2d<float> bloomMap [[texture(0)]]) {
    return half4(half3(blur(bloomMap, in.uv, float2(1.5, 0.0))), 1.0h);
}

fragment half4 postBlurV(QuadVarying in [[stage_in]], texture2d<float> bloomMap [[texture(0)]]) {
    return half4(half3(blur(bloomMap, in.uv, float2(0.0, 1.5))), 1.0h);
}

// The veil's first pass in space reads the glow, four times its own size, so its steps
// are four times as long: the veil comes out as wide as it is tall. (The landscape
// veil takes the short steps of postBlurH here and stands taller than wide, which its
// look was tuned with.)
fragment half4 postVeilH(QuadVarying in [[stage_in]], texture2d<float> bloomMap [[texture(0)]]) {
    return half4(half3(blur(bloomMap, in.uv, float2(6.0, 0.0))), 1.0h);
}

// The streak: the veil smeared sideways again, three times as far, the way an
// anamorphic lens draws a bright light out into a line.
fragment half4 postStreak(QuadVarying in [[stage_in]], texture2d<float> bloomMap [[texture(0)]]) {
    return half4(half3(blur(bloomMap, in.uv, float2(4.5, 0.0))), 1.0h);
}

// MARK: - Final

// Scene-linear light to the display. Up to the shoulder nothing changes, so lit hulls
// look as they would drawn straight to the screen; above it each channel rolls off
// toward white, which is what turns a fire's saturated heart white with a coloured rim.
static float3 display(float3 c) {
    const float shoulder = 0.8;
    float3 over = max(c - shoulder, 0.0);
    return min(c, shoulder) + (1.0 - shoulder) * over / (over + (1.0 - shoulder));
}

// The streak is cool and faint beside the bloom it runs through.
constant float3 kStreakTint = float3(0.35, 0.55, 1.0) * 0.6;

fragment half4 postFinal(QuadVarying in [[stage_in]],
                         texture2d<float> sceneMap [[texture(0)]],
                         texture2d<float> glowMap [[texture(1)]],
                         texture2d<float> veilMap [[texture(2)]],
                         texture2d<float> streakMap [[texture(3)]]) {
    float2 uv = in.uv;
    float aspect = float(sceneMap.get_width()) / float(sceneMap.get_height());
    float2 centred = (uv - 0.5) * float2(aspect, 1.0);
    float edge = dot(centred, centred);
    float3 scene;
    if (kGrade > 0.0) {
        // Lateral colour: red and blue land a little further out than green toward the edges.
        float2 fringe = centred * 0.0018 * kGrade / float2(aspect, 1.0);
        scene = float3(sceneMap.sample(postSampler, uv - fringe).r,
                       sceneMap.sample(postSampler, uv).g,
                       sceneMap.sample(postSampler, uv + fringe).b);
    } else {
        scene = sceneMap.sample(postSampler, uv).rgb;
    }
    float3 glow = glowMap.sample(postSampler, uv).rgb;
    float3 veil = veilMap.sample(postSampler, uv).rgb;
    float3 col = max(scene, 0.0) + (glow * 0.55 + veil * 0.45) * kBloom;
    if (kHDR) {
        col += streakMap.sample(postSampler, uv).rgb * kStreakTint * kBloom;
        col = display(col);
    }

    if (kGrade > 0.0 || kVignette > 0.0) {
        // The colour filter, in a perceptual domain: blacks lifted toward the haze, the
        // saturation eased, highlights warmed and shadows cooled, contrast flattened a touch.
        float3 g = pow(max(col, 0.0), 1.0 / 2.2);
        float l = luminance(g);
        float3 graded = mix(float3(l), g, 0.88);
        graded = graded * 0.94 + 0.05 * float3(0.96, 1.0, 1.02);
        graded *= mix(float3(0.98, 1.0, 1.02), float3(1.04, 1.0, 0.94), smoothstep(0.1, 0.8, l));
        graded = mix(graded, 0.5 + (graded - 0.5) * 0.92, 0.5);
        g = mix(g, graded, kGrade);
        g *= 1.0 - kVignette * smoothstep(0.25, 1.1, edge);
        col = pow(saturate(g), 2.2);
    }
    return half4(half3(col), 1.0h);
}
