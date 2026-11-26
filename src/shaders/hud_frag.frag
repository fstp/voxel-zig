#version 460 core
uniform sampler2D u_font;
in vec2 v_uv;
in vec4 v_colour;
out vec4 f_colour;
void main() {
    // A real anti-aliased atlas, so keep the soft edge: a hard 0.5 cutoff
    // throws away exactly the pixels that make small text readable.
    float a = texture(u_font, v_uv).a;
    if (a < 0.02) discard;
    f_colour = vec4(v_colour.rgb, v_colour.a * a);
}
