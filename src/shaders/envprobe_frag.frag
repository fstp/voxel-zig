#version 460 core
uniform mat4 u_inv_vp;
uniform vec3 u_zenith;
uniform vec3 u_horizon;
uniform vec3 u_sun_colour;
uniform vec3 u_sun_dir;
uniform float u_night; // 1 at night, for the star-free ambient floor
in vec2 v_uv;
out vec4 f_colour;
void main() {
    vec4 far = u_inv_vp * vec4(v_uv * 2.0 - 1.0, 1.0, 1.0);
    vec3 dir = normalize(far.xyz / far.w);
    float up = pow(max(dir.y, 0.0), 0.45);
    vec3 colour = mix(u_horizon, u_zenith, up);
    // Sun disc and glow, same constants as the sky pass (ADR 0009): this is
    // what puts a highlight in the reflection at water roughness.
    float d = dot(dir, u_sun_dir);
    colour += u_sun_colour * smoothstep(0.99985, 0.99995, d);
    colour += u_sun_colour * pow(max(d, 0.0), 220.0) * 0.55;
    // Below the horizon the probe is dark ground, not sky, or a metal face
    // pointing down would reflect daylight from the floor.
    colour *= mix(1.0, 0.18, smoothstep(0.0, -0.35, dir.y));
    f_colour = vec4(colour, 1.0);
}
