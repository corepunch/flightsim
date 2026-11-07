// The post-process technique (Sources/Render/Post.m): what the frame goes through on its
// way from the scene to the screen. The scene is drawn display-ready into a texture, the
// bright sky and clouds are blurred into two bloom layers (a tight glow at a quarter of
// the drawable, a wide veil at a sixteenth) and the final pass adds them back and grades
// the result: lifted blacks, less saturation, a warm cast, a vignette and a trace of
// colour fringing at the edges. The look follows Ace Combat 7 (see POST-REFERENCES.md):
// its sky light bleeds into everything through bloom and haze, so dark ground never
// reaches black, and a per-mission colour filter warms and flattens the frame.
//
// The host prepends `constant float` definitions for the tuning values before compiling.

#include <metal_stdlib>
using namespace metal;

// Runtime Metal compilation cannot resolve SDK framework headers on devices.
enum { SCNVertexSemanticPosition = 0 };

// Prepended by the host:
//   constant float kBloom;        bloom intensity, the share of blurred light added back
//   constant float kBloomKnee;    display brightness where light starts to bloom
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
    float3 c = sum / 9.0;
    // A soft knee: light fades in over the stop below the knee instead of switching on.
    float l = luminance(c);
    float w = smoothstep(kBloomKnee * 0.5, kBloomKnee, l);
    return half4(half3(c * w), 1.0h);
}

// One direction of a Gaussian blur (sigma about 2.4 texels of the target being read).
constant float kBlurWeights[5] = { 0.2270, 0.1945, 0.1216, 0.0541, 0.0162 };
static float3 blur(texture2d<float> map, float2 uv, float2 dir) {
    constant float *weights = kBlurWeights;
    float2 px = dir / float2(map.get_width(), map.get_height());
    float3 c = map.sample(postSampler, uv).rgb * weights[0];
    for (int i = 1; i < 5; i++) {
        float2 o = px * (float(i) * 1.5);
        c += (map.sample(postSampler, uv + o).rgb + map.sample(postSampler, uv - o).rgb) * weights[i];
    }
    return c;
}

fragment half4 postBlurH(QuadVarying in [[stage_in]], texture2d<float> bloomMap [[texture(0)]]) {
    return half4(half3(blur(bloomMap, in.uv, float2(1.0, 0.0))), 1.0h);
}

fragment half4 postBlurV(QuadVarying in [[stage_in]], texture2d<float> bloomMap [[texture(0)]]) {
    return half4(half3(blur(bloomMap, in.uv, float2(0.0, 1.0))), 1.0h);
}

// MARK: - Final

fragment half4 postFinal(QuadVarying in [[stage_in]],
                         texture2d<float> sceneMap [[texture(0)]],
                         texture2d<float> glowMap [[texture(1)]],
                         texture2d<float> veilMap [[texture(2)]]) {
    float2 uv = in.uv;
    float aspect = float(sceneMap.get_width()) / float(sceneMap.get_height());
    float2 centred = (uv - 0.5) * float2(aspect, 1.0);
    float edge = dot(centred, centred);
    // Lateral colour: red and blue land a little further out than green toward the edges.
    float2 fringe = centred * 0.0018 * kGrade / float2(aspect, 1.0);
    float3 scene = float3(sceneMap.sample(postSampler, uv - fringe).r,
                          sceneMap.sample(postSampler, uv).g,
                          sceneMap.sample(postSampler, uv + fringe).b);
    float3 glow = glowMap.sample(postSampler, uv).rgb;
    float3 veil = veilMap.sample(postSampler, uv).rgb;
    float3 col = scene + (glow * 0.55 + veil * 0.45) * kBloom;

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
    return half4(half3(col), 1.0h);
}
