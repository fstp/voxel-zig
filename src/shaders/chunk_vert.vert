#version 460 core
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in float a_layer;
layout(location = 3) in float a_ao;
layout(location = 4) in float a_face;
uniform mat4 u_vp;
uniform mat4 u_model;
uniform float u_time;
uniform float u_water_layer;
uniform float u_wave_amp;
uniform float u_waves;
out float v_wave;
out vec2 v_uv;
out float v_layer;
out float v_ao;
out float v_face;
out vec3 v_normal;
out vec3 v_world;
// Face id -> outward normal (3.3). Same order as block.faceNormal().
vec3 normalFromFace(float id) {
    if (id < 0.5) return vec3(1.0, 0.0, 0.0);
    if (id < 1.5) return vec3(-1.0, 0.0, 0.0);
    if (id < 2.5) return vec3(0.0, 1.0, 0.0);
    if (id < 3.5) return vec3(0.0, -1.0, 0.0);
    if (id < 4.5) return vec3(0.0, 0.0, 1.0);
    return vec3(0.0, 0.0, -1.0);
}
// Two crossing swells plus a ripple, sampled in WORLD space: neighbouring water
// quads share their corner positions, so a position-only function keeps the
// surface watertight however many chunks meet at that corner.
float waveHeight(vec2 p, float t) {
    return sin(p.x * 0.19 + t * 1.15) * 0.55
         + sin(p.y * 0.24 - t * 0.95) * 0.35
         + sin((p.x + p.y) * 0.43 + t * 1.8) * 0.15;
}

void main() {
    v_uv = a_uv;
    v_layer = a_layer;
    v_ao = a_ao;
    v_face = a_face;
    v_normal = normalFromFace(a_face);
    vec3 world = (u_model * vec4(a_pos, 1.0)).xyz;
    float height = 0.0;
    // Upward faces only: a displaced side face stretches into a long sliver, and
    // those slivers were the white lines lying across the sea.
    if (u_waves > 0.5 && abs(a_layer - u_water_layer) < 0.5 && a_face > 1.5 && a_face < 2.5) {
        height = waveHeight(world.xz, u_time) * u_wave_amp;
        world.y += height;
    }
    v_wave = height;
    v_world = world;
    gl_Position = u_vp * vec4(world, 1.0);
}
