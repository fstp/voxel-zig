#version 460 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_rgba;
uniform vec2 u_screen;
out vec2 v_uv;
out vec4 v_colour;
void main() {
    v_uv = a_uv;
    v_colour = a_rgba;
    vec2 ndc = vec2(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
}
