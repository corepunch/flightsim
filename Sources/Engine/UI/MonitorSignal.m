#import "MonitorSignal.h"
#import "UIMotion.h"

SKShader *UIMonitorSignalShader(BOOL preserveAlpha) {
    SKShader *shader = [SKShader shaderWithSource:
            @"float blockNoise(vec2 cell, float packet) {\n"
             "    return fract(sin(dot(cell, vec2(27.31, 53.17)) + packet * 11.53) * 437.23);\n"
             "}\n"
             "void main() {\n"
             "    vec2 uv = v_tex_coord;\n"
             "    float time = u_time * u_motion_rate;\n"
             "    vec2 pixel = uv * a_screen_size;\n"
             "    float packet = floor(time * 24.0);\n"
             // Short disruptions separated by long readable intervals.
             "    float phase = mod(time, 5.7);\n"
             "    float burst = (1.0 - step(0.23, phase)) + step(3.82, phase) * (1.0 - step(3.91, phase));\n"
             "    float band = floor(pixel.y / 7.0);\n"
             "    float tear = step(0.68, blockNoise(vec2(band, 2.0), packet)) * burst;\n"
             "    float offset = (blockNoise(vec2(band, 9.0), packet) - 0.5) * 26.0 * tear;\n"
             "    vec2 sampleUV = vec2(clamp(uv.x + offset / a_screen_size.x, 0.0, 1.0), uv.y);\n"
             "    vec4 signal = texture2D(u_texture, sampleUV);\n"
             "    float split = (0.45 + 2.5 * tear) / a_screen_size.x;\n"
             "    signal.r = texture2D(u_texture, clamp(sampleUV + vec2(split, 0.0), 0.0, 1.0)).r;\n"
             "    signal.b = texture2D(u_texture, clamp(sampleUV - vec2(split, 0.0), 0.0, 1.0)).b;\n"
             "    float grain = blockNoise(vec2(floor(pixel.x / 3.0), floor(pixel.y)), packet);\n"
             "    float scan = 0.97 + 0.03 * sin(pixel.y * 3.14159);\n"
             "    signal.rgb *= scan * (1.0 - tear * 0.18);\n"
             "    float snow = grain * (0.012 + burst * 0.11);\n"
             "    signal = vec4(vec3(0.38, 0.85, 0.78) * snow, snow) + signal * (1.0 - snow);\n"
             "    signal.rgb = min(signal.rgb, vec3(signal.a));\n"
             "    if (u_preserve_alpha > 0.5) signal *= texture2D(u_texture, sampleUV).a;\n"
             "    gl_FragColor = signal * v_color_mix;\n"
             "}"];
    shader.uniforms = @[[SKUniform uniformWithName:@"u_motion_rate" float:1 / UIMotionTimeScale()],
                        [SKUniform uniformWithName:@"u_preserve_alpha" float:preserveAlpha ? 1 : 0]];
    shader.attributes = @[[SKAttribute attributeWithName:@"a_screen_size" type:SKAttributeTypeVectorFloat2]];
    return shader;
}
