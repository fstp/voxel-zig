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
uniform float u_cloud_bottom;
uniform float u_cloud_top;
uniform vec3 u_cloud_light;    // sun colour at cloud height
uniform float u_cirrus;        // 0 off, 1 on: thin high deck with its own wind
uniform vec3 u_cirrus_shift;   // cirrus wind offset, in the same cloud-space units
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

    const int STEPS = 22;
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

// A thin high cirrus deck: a veil stretched along the wind on a plane at 1800 blocks. It is
// optically thin, so two noise octaves and an alpha composite replace a raymarch - a fraction
// of the cumulus cost, and a second wind for the eye to read against the lower deck.
vec4 cirrus(vec3 dir) {
    if (u_cirrus < 0.5 || dir.y < 0.015) return vec4(0.0, 0.0, 0.0, 1.0);
    float t = (1800.0 - u_eye.y) / dir.y;
    vec3 p = u_eye + dir * t;
    // Same world scale as the cumulus base, so one shift unit is the same distance per second.
    vec2 q = p.xz * 0.0038 + u_cirrus_shift.xz;
    // Bend the fibre field with a slow warp so the filaments curve and cross instead of
    // running as parallel bands across the whole sky.
    vec2 warp = vec2(vnoise(vec3(q * 0.31, 3.0)), vnoise(vec3(q * 0.31, 9.0))) - 0.5;
    vec2 r = q + warp * 1.1;
    // Two fibre layers at a slight angle to each other: the first sets the long filaments,
    // the second breaks them into wisps. Moderate stretch (about 2.5x), not the 5x that read
    // as regular stripes.
    const float ca = 0.94;
    const float sa = 0.34;
    vec2 r2 = vec2(r.x * ca - r.y * sa, r.x * sa + r.y * ca);
    float n = vnoise(vec3(r.x * 0.55, r.y * 1.4, 21.0)) * 0.58
            + vnoise(vec3(r2.x * 1.3, r2.y * 3.2, 37.0)) * 0.42;
    // Patchy coverage: a slow weather field leaves clear gaps, so the veil reads as separate
    // sheets of cirrus rather than one continuous brushed texture.
    float weather = vnoise(vec3(q * 0.16, 51.0));
    float cover = 0.58 + (weather - 0.5) * 0.18;
    float d = smoothstep(cover - 0.05, cover + 0.13, n);
    float fade = smoothstep(0.015, 0.14, dir.y);
    // Thin ice cloud is mostly skylight; a little direct sun warms the wisps.
    vec3 lit = u_zenith * 0.95 + u_cloud_light * 0.30;
    float alpha = d * fade * 0.32;
    return vec4(lit * alpha, 1.0 - alpha);
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

    // Far deck first, then the near one: the cumulus correctly occludes the cirrus.
    vec4 high = cirrus(dir);
    col = col * high.a + high.rgb;

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
