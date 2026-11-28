#version 460 core
uniform mat4 u_inv_vp;
uniform vec3 u_eye;
uniform vec3 u_sun_dir;
uniform vec3 u_zenith;
uniform vec3 u_horizon;
uniform vec3 u_sun_colour;
uniform float u_stars; // 0 day, 1 night
uniform float u_clouds;        // 0 off, 1 on (3.11)
uniform float u_cloud_coverage;// 0..1, higher = fewer gaps
uniform vec3 u_cloud_shift;    // wind offset in cloud space
uniform int u_cloud_steps;     // march budget: the single biggest cost in this pass (ADR 0044)
uniform float u_cloud_bottom;
uniform float u_cloud_top;
uniform vec3 u_cloud_light;    // sun colour at cloud height
uniform float u_atmosphere;    // 0 off, 1 on: horizon haze + Mie glow (ADR 0021)
in vec2 v_ndc;
out vec4 f_colour;

float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

float hash31(vec3 p) {
    p = fract(p * 0.3183099 + vec3(0.11, 0.23, 0.37));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(hash31(i), hash31(i + vec3(1,0,0)), f.x),
            mix(hash31(i + vec3(0,1,0)), hash31(i + vec3(1,1,0)), f.x), f.y),
        mix(mix(hash31(i + vec3(0,0,1)), hash31(i + vec3(1,0,1)), f.x),
            mix(hash31(i + vec3(0,1,1)), hash31(i + vec3(1,1,1)), f.x), f.y),
        f.z);
}

float cloudDensity(vec3 p) {
    vec3 q = p * 0.0038 + u_cloud_shift;
    // Three octaves: the third is what breaks the edge into ragged detail
    // instead of a smooth blob. They share one shift on purpose: sliding the octaves relative
    // to each other decorrelates the cascade, and the deck loses its contrast (measured: it
    // turned the puffy cumulus into a solid overcast within ten seconds). Different cloud
    // speeds come from the separate high deck (`cirrus`), not from shearing these octaves.
    float n = vnoise(q) * 0.55 + vnoise(q * 2.6) * 0.29 + vnoise(q * 6.3) * 0.16;
    // Coverage is weather, not a constant: a low-frequency field puts clear
    // spells next to heavy patches, which is most of what makes a cloudscape
    // look unplanned.
    float weather = vnoise(q * 0.19 + 13.0);
    float cover = u_cloud_coverage + (weather - 0.5) * 0.34;
    // The base is uneven: offsetting the fade by the same weather field costs
    // nothing and stops the deck reading as a table top at the horizon.
    float base = u_cloud_bottom + (weather - 0.5) * 70.0;
    float vertical = smoothstep(base, base + 70.0, p.y)
                   * (1.0 - smoothstep(u_cloud_top - 70.0, u_cloud_top, p.y));
    float d = clamp((n - cover) / max(1.0 - cover, 0.05), 0.0, 1.0);
    // A linear ramp reads as fog; the curve gives the puffs a defined edge.
    return pow(d, 1.35) * 1.7 * vertical;
}

// Single scattering through one slab: 20 march steps, two light taps each.
// Hash noise instead of a 3D texture keeps it self-contained.
vec4 clouds(vec3 dir) {
    if (u_clouds < 0.5 || dir.y < 0.02) return vec4(0.0, 0.0, 0.0, 1.0);
    float t0 = max((u_cloud_bottom - u_eye.y) / dir.y, 0.0);
    // Stop the ray after a fixed distance. Seen edge-on the slab is thousands
    // of blocks deep, and marching that with a fixed step budget averages the
    // density into a flat band on the horizon; cutting the ray short and
    // fading what is left into haze is both cheaper and what the eye expects.
    const float MAX_TRAVEL = 3000.0;
    float t1 = min((u_cloud_top - u_eye.y) / dir.y, t0 + MAX_TRAVEL);
    if (t1 <= t0) return vec4(0.0, 0.0, 0.0, 1.0);

    int STEPS = max(u_cloud_steps, 4);
    float dt = (t1 - t0) / float(STEPS);
    float cos_angle = dot(dir, u_sun_dir);
    // Henyey-Greenstein, forward peaked: thin edges glow when backlit.
    float g = 0.55;
    float phase = (1.0 - g * g) / (4.0 * 3.14159 * pow(1.0 + g * g - 2.0 * g * cos_angle, 1.5));

    float transmittance = 1.0;
    vec3 scattered = vec3(0.0);
    // Per-pixel offset on the march: without it the fixed step shows as
    // banding rings near the horizon, which is the classic raymarch tell.
    float jitter = hash31(vec3(gl_FragCoord.xy, 7.0));
    for (int i = 0; i < STEPS; ++i) {
        vec3 p = u_eye + dir * (t0 + (float(i) + jitter) * dt);
        float distance = t0 + (float(i) + jitter) * dt;
        float density = cloudDensity(p);
        if (density > 0.002) {
            float shadow = cloudDensity(p + u_sun_dir * 45.0)
                         + cloudDensity(p + u_sun_dir * 110.0) * 0.6;
            float light = exp(-shadow * 2.2);
            // Extinction per block: the layer has to be thin enough to see through
            // at the edges and thick enough to read as cloud in the middle.
            float extinction = exp(-density * dt * 0.02);
            // Aerial perspective: air between the eye and a distant puff washes
            // it toward the sky, and it stops occluding at the same rate.
            float aerial = 1.0 - smoothstep(2200.0, MAX_TRAVEL, distance);
            vec3 lit = u_cloud_light * light * phase * 9.0 + u_zenith * 0.7;
            scattered += transmittance * (1.0 - extinction) * lit * aerial;
            transmittance *= mix(1.0, extinction, aerial);
        }
    }
    return vec4(scattered, transmittance);
}

void main() {
    // Unproject the far plane at this corner and take the direction from the eye.
    vec4 far_point = u_inv_vp * vec4(v_ndc, 1.0, 1.0);
    vec3 dir = normalize(far_point.xyz / far_point.w - u_eye);

    float h = clamp(dir.y, 0.0, 1.0);
    vec3 col = mix(u_horizon, u_zenith, pow(h, 0.45));

    float c = dot(dir, u_sun_dir);
    // 0.5 degree disc plus a wide glow, both in linear space (ADR 0008).
    float disc = smoothstep(0.99985, 0.99995, c);
    float glow = pow(max(c, 0.0), 220.0) * 0.55;
    col += u_sun_colour * (disc * 3.0 + glow);

    if (u_atmosphere > 0.5) {
        // Atmospheric depth without a second deck: a denser scattering layer toward the horizon,
        // tinted by the horizon colour, plus a Mie-like glow around the sun. Decima/Frostbite
        // shape; see ADR 0021.
        float haze = exp(-max(dir.y, 0.0) * 7.0);
        float mie = pow(max(c, 0.0), 8.0);
        vec3 haze_col = u_horizon * 1.06 + u_sun_colour * mie * 0.35;
        col = mix(col, haze_col, haze * 0.30);
    }

    // Clouds composite over the gradient and the disc: a cloud in front of the
    // sun dims it, which is the whole point of drawing them here.
    vec4 cloud = clouds(dir);
    col = col * cloud.a + cloud.rgb;

    if (u_stars > 0.01) {
        // Sparse point stars: one candidate per cell, drawn as a soft dot.
        vec3 scaled = dir * 320.0;
        vec3 cell = floor(scaled);
        if (hash13(cell) > 0.9955) {
            vec3 jitter = vec3(hash13(cell + 1.0), hash13(cell + 2.0), hash13(cell + 3.0));
            float d = length(scaled - (cell + 0.5 + (jitter - 0.5) * 0.6));
            float brightness = smoothstep(0.6, 0.0, d);
            // Fade stars out near the horizon, where the sky glow is.
            col += vec3(brightness * u_stars * smoothstep(0.02, 0.25, dir.y));
        }
    }
    f_colour = vec4(col, 1.0);
}
