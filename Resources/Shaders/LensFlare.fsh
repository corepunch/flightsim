// Analytic optics: no stretched particle bitmap, animation noise or hard quad
// edges. All profiles reach zero before the sprite borders. Values are linear
// additive light; the sky/camera already provide the sun disc and HDR bloom.
float gaussian(float x, float width) {
    float q = x / width;
    return exp(-q * q);
}

void main() {
    vec2 p = v_tex_coord * 2.0 - 1.0;
    vec3 light;
    if (u_profile < 0.5) {
        float x = abs(p.x);
        float ends = 1.0 - smoothstep(0.65, 1.0, x);
        float envelope = exp(-x * 3.5) * ends;
        // A fine filament embedded in a wider, softer optical smear. Small
        // stationary lobes break up the ruler-straight appearance of a bar.
        float filament = gaussian(p.y, 0.035) * 0.66;
        float lobes = 0.82 + 0.12 * cos(p.x * 31.0) + 0.06 * cos(p.x * 67.0);
        float smear = gaussian(p.y, 0.20) * 0.24 * lobes;
        float hot = gaussian(p.x, 0.075);
        vec3 coating = mix(vec3(0.22, 0.48, 1.0), vec3(1.0, 0.88, 0.66), hot);
        light = coating * (filament + smear) * envelope;
        light += vec3(0.20, 0.36, 0.85) * gaussian(p.y - 0.11, 0.075) * gaussian(p.x, 0.42) * 0.07;
        light *= ends * (1.0 - smoothstep(0.65, 1.0, abs(p.y)));
    } else if (u_profile < 1.5) {
        float r = length(p);
        float core = exp(-r * r * 38.0);
        float veil = exp(-r * r * 6.5) * 0.21;
        light = vec3(1.0, 0.80, 0.51) * core + vec3(0.25, 0.42, 0.85) * veil;
        light *= 1.0 - smoothstep(0.65, 1.0, r);
    } else {
        float r = length(p);
        // Soft coating reflections with modest dispersion, not solid discs
        // or sharply drawn rainbow rings.
        vec3 rim = vec3(gaussian(r - 0.61, 0.12), gaussian(r - 0.57, 0.12), gaussian(r - 0.53, 0.12));
        float crescent = 0.35 + 0.65 * smoothstep(-1.0, 1.0, p.x + p.y * 0.35);
        light = rim * vec3(0.45, 0.70, 1.0) * crescent + vec3(0.16, 0.23, 0.36) * exp(-r * r * 5.0);
        light *= 1.0 - smoothstep(0.72, 1.0, r);
    }
    // Emissive light has zero coverage. SpriteKit first flattens the HUD;
    // SceneKit then composites it over the world. Nonzero coverage here would
    // attenuate the world a second time, even with additive sprite blending.
    // Parent opacity still scales the emitted RGB through v_color_mix.
    gl_FragColor = vec4(light, 0.0) * v_color_mix;
}
