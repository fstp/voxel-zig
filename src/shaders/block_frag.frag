#version 460 core
uniform sampler2DArray u_tex;
uniform float u_legacy;
uniform vec3 u_sun_dir;
uniform vec3 u_sun_colour;
uniform vec3 u_ambient_sky;
uniform vec3 u_ambient_ground;
in vec2 v_uv;
in float v_layer;
in vec3 v_normal;
out vec4 f_colour;
void main() {
    vec4 c = texture(u_tex, vec3(v_uv, v_layer));
    if (c.a < 0.5) discard; // alpha cutout (leaves), ADR 0002
    // Same model as the terrain (3.5, C22), without AO: a single block has no
    // neighbours to occlude it.
    float ndl = max(dot(v_normal, u_sun_dir), 0.0);
    vec3 hemi = mix(u_ambient_ground, u_ambient_sky, v_normal.y * 0.5 + 0.5);
    vec3 lit = hemi + u_sun_colour * ndl;
    vec3 unlit = vec3(1.0);
    f_colour = vec4(c.rgb * mix(lit, unlit, u_legacy), c.a);
}
