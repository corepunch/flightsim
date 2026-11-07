// Analytic optics: no stretched particle bitmap, animation noise or hard quad
// edges. All profiles reach zero before the sprite borders. Values are linear
// additive light. The glare profile supplies the sun core, halo and diffraction
// rays directly, without relying on HDR or a camera bloom pass.
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
        float core = gaussian(r, 0.046) * 3.0;
        float inner = gaussian(r, 0.11) * 0.85;
        float halo = gaussian(r, 0.23) * 0.18;
        // Thin aperture rays give glare a luminous shape instead of a foggy disc.
        float vertical = gaussian(p.x, 0.012) * gaussian(p.y, p.y > 0.0 ? 0.52 : 0.38);
        vec2 diagonal = vec2(p.x + p.y, p.x - p.y) * 0.70710678;
        float rays = vertical * 0.70
                   + gaussian(diagonal.x, 0.011) * gaussian(diagonal.y, 0.34) * 0.45
                   + gaussian(diagonal.y, 0.010) * gaussian(diagonal.x, 0.27) * 0.35;
        vec3 warm = vec3(1.0, 0.86, 0.65);
        vec3 coating = mix(warm, vec3(0.25, 0.48, 1.0), smoothstep(0.06, 0.30, r));
        light = warm * (core + inner) + coating * (halo + rays);
        light *= 1.0 - smoothstep(0.60, 0.95, r);
    } else {
        float r = length(p);
        // Soft coating reflections with modest dispersion, not solid discs
        // or sharply drawn rainbow rings.
        vec3 rim = vec3(gaussian(r - 0.61, 0.12), gaussian(r - 0.57, 0.12), gaussian(r - 0.53, 0.12));
        float crescent = 0.35 + 0.65 * smoothstep(-1.0, 1.0, p.x + p.y * 0.35);
        light = rim * vec3(0.45, 0.70, 1.0) * crescent + vec3(0.16, 0.23, 0.36) * exp(-r * r * 5.0);
        light *= 1.0 - smoothstep(0.72, 1.0, r);
    }
    // A transparent SKView must carry valid premultiplied coverage through
    // the system compositor. The SceneKit overlay can add zero-coverage light
    // directly to its destination. Coverage follows the light, never the quad.
    float coverage = clamp(max(max(light.r, light.g), light.b), 0.0, 1.0) * u_layerCoverage;
    gl_FragColor = vec4(light, coverage) * v_color_mix;
}
