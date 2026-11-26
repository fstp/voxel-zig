#version 460 core
uniform sampler2D u_source;
uniform vec2 u_texel;
in vec2 v_uv;
out vec4 f_colour;
void main() {
    float sum = 0.0;
    for (int y = -2; y < 2; ++y) {
        for (int x = -2; x < 2; ++x) {
            sum += texture(u_source, v_uv + vec2(float(x), float(y)) * u_texel).r;
        }
    }
    f_colour = vec4(vec3(sum / 16.0), 1.0);
}
