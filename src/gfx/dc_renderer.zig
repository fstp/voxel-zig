//! Terrain renderer for the DC world: the procedural material shader, vertex upload and the draw
//! call with the atmosphere/fog uniforms (ADR 0022).

const gl = @import("gl");
const Shader = @import("shader.zig").Shader;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec.zig").Vec3;
const Vertex = @import("../world/dc_world.zig").Vertex;
const ShadowRenderer = @import("shadow_renderer.zig").ShadowRenderer;
const stb = @import("stb.zig");

const ground_jpg = @embedFile("../assets/textures/ground_grass.jpg");
const ground_patch_jpg = @embedFile("../assets/textures/ground_patch.jpg");
const ground_moss_jpg = @embedFile("../assets/textures/ground_moss.jpg");
const snow_grass_jpg = @embedFile("../assets/textures/snow_grass.jpg");
const snow_clean_jpg = @embedFile("../assets/textures/snow_clean.jpg");
const snow_patch_jpg = @embedFile("../assets/textures/snow_patch.jpg");
const shore_dirt_jpg = @embedFile("../assets/textures/shore_dirt.jpg");
const shore_sand_jpg = @embedFile("../assets/textures/shore_sand.jpg");
const shore_mud_jpg = @embedFile("../assets/textures/shore_mud.jpg");
const rock_rough_jpg = @embedFile("../assets/textures/rock_rough.jpg");
const rock_granite_jpg = @embedFile("../assets/textures/rock_granite.jpg");
const rock_stone_jpg = @embedFile("../assets/textures/rock_stone.jpg");

const depth_vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\uniform mat4 u_mvp;
    \\void main() { gl_Position = u_mvp * vec4(a_pos, 1.0); }
;
const depth_fragment_src: [:0]const u8 =
    \\#version 330 core
    \\void main() {}
;

const vertex_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec3 a_pos;
    \\layout(location = 1) in vec3 a_nrm;
    \\layout(location = 2) in vec3 a_col;
    \\layout(location = 3) in float a_mat;
    \\uniform mat4 u_view_proj;
    \\out vec3 v_nrm;
    \\out vec3 v_pos;
    \\out vec3 v_col;
    \\out float v_mat;
    \\void main() {
    \\    v_nrm = a_nrm;
    \\    v_pos = a_pos;
    \\    v_col = a_col;
    \\    v_mat = a_mat;
    \\    gl_Position = u_view_proj * vec4(a_pos, 1.0);
    \\}
;

const fragment_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 v_nrm;
    \\in vec3 v_pos;
    \\in vec3 v_col;
    \\in float v_mat;
    \\uniform vec3 u_eye;
    \\uniform vec3 u_sun_dir;
    \\uniform vec3 u_sun_colour;
    \\uniform vec3 u_ambient_ground;
    \\uniform vec3 u_sh[9];        // sky irradiance SH9 (ADR 0027), convolution folded in
    \\uniform mat4 u_light_vp[2];
    \\uniform sampler2D u_shadow0;
    \\uniform sampler2D u_shadow1;
    \\uniform float u_shadow_enabled;
    \\uniform sampler2D u_ao_tex;
    \\uniform vec2 u_ao_origin;
    \\uniform float u_ao_size;
    \\uniform float u_ao_enabled;
    \\uniform vec3 u_fog_colour;   // display-space horizon scattering colour
    \\uniform vec3 u_fog_sun;      // display-space sun tint for the forward-scatter term
    \\uniform float u_fog_density; // density at u_fog_base, per block
    \\uniform float u_fog_height;  // exponential scale height
    \\uniform float u_fog_base;    // world y where the density equals u_fog_density
    \\uniform float u_atmosphere;  // 0 off, 1 on
    \\uniform float u_detail;      // 0 = flat A/B path, 1 = procedural detail + bump
    \\uniform sampler2D u_ground_tex0; // dense grass ground
    \\uniform sampler2D u_ground_tex1; // sparse dirt/grass patch
    \\uniform sampler2D u_ground_tex2; // mossy ground
    \\uniform float u_ground_enabled;
    \\uniform sampler2D u_snow_tex0; // snow with grass stalks / edge
    \\uniform sampler2D u_snow_tex1; // clean deep snow
    \\uniform sampler2D u_snow_tex2; // patchy snow and grass
    \\uniform float u_snow_enabled;
    \\uniform sampler2D u_shore_tex0; // dry dirt
    \\uniform sampler2D u_shore_tex1; // rippled sand
    \\uniform sampler2D u_shore_tex2; // cracked wet mud
    \\uniform float u_shore_enabled;
    \\uniform sampler2D u_rock_tex0; // rough lichen rock
    \\uniform sampler2D u_rock_tex1; // grey granite
    \\uniform sampler2D u_rock_tex2; // dark fractured stone
    \\uniform float u_rock_enabled;
    \\uniform float u_surfaces;    // 0 = flat A/B path, 1 = snow/mud/wetness rules
    \\uniform float u_sea_level;   // world y of the sea surface (55 m in this world)
    \\uniform float u_snow_line;   // altitude where snow starts, before the noise warp
    \\uniform float u_mud_band;    // half-width of the shore mud band, in metres

    \\float hash13(vec3 p) {
    \\    p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
    \\    p *= 17.0;
    \\    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    \\}

    \\// Inigo Quilez's value noise with analytic derivatives (articles/morenoise): the trilinear
    \\// interpolation is expanded into the k0..k7 polynomial and differentiated, so the value and its
    \\// gradient come out of ONE evaluation. Quintic interpolation is mandatory - with the cubic
    \\// the second derivative breaks and the analytic normal shows facets.
    \\vec4 noised(vec3 x) {
    \\    vec3 p = floor(x);
    \\    vec3 w = fract(x);
    \\    vec3 u = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);
    \\    vec3 du = 30.0 * w * w * (w * (w - 2.0) + 1.0);
    \\    float a = hash13(p + vec3(0, 0, 0));
    \\    float b = hash13(p + vec3(1, 0, 0));
    \\    float c = hash13(p + vec3(0, 1, 0));
    \\    float d = hash13(p + vec3(1, 1, 0));
    \\    float e = hash13(p + vec3(0, 0, 1));
    \\    float f = hash13(p + vec3(1, 0, 1));
    \\    float g = hash13(p + vec3(0, 1, 1));
    \\    float h = hash13(p + vec3(1, 1, 1));
    \\    float k0 = a;
    \\    float k1 = b - a;
    \\    float k2 = c - a;
    \\    float k3 = e - a;
    \\    float k4 = a - b - c + d;
    \\    float k5 = a - c - e + g;
    \\    float k6 = a - b - e + f;
    \\    float k7 = -a + b + c - d + e - f - g + h;
    \\    float v = k0 + k1*u.x + k2*u.y + k3*u.z + k4*u.x*u.y + k5*u.y*u.z + k6*u.z*u.x + k7*u.x*u.y*u.z;
    \\    vec3 gr = du * vec3(k1 + k4*u.y + k6*u.z + k7*u.y*u.z,
    \\                        k2 + k5*u.z + k4*u.x + k7*u.z*u.x,
    \\                        k3 + k6*u.x + k5*u.y + k7*u.x*u.y);
    \\    return vec4(v, gr);
    \\}
    \\mat2 rot2(float a) {
    \\    float c = cos(a);
    \\    float s = sin(a);
    \\    return mat2(c, -s, s, c);
    \\}
    \\vec3 groundTexture(vec2 p, float mott) {
    \\    // Three rotated, incommensurate scales plus a noise-warped offset. Each layer alone
    \\    // repeats every few metres; their blend has no single visible tile boundary.
    \\    vec2 warp = vec2(noised(vec3(p * 0.037, 3.1)).x,
    \\                     noised(vec3(p * 0.043, 8.7)).x) - 0.5;
    \\    vec2 uv1 = rot2(0.31) * (p * 0.145 + warp * 0.09);
    \\    vec2 uv2 = rot2(1.73) * (p * 0.227 - warp * 0.07);
    \\    vec2 uv3 = rot2(3.17) * (p * 0.391 + warp * 0.05);
    \\    vec3 a = texture(u_ground_tex0, uv1).rgb;
    \\    vec3 b = texture(u_ground_tex1, uv2).rgb * 0.62; // the dirt photo is much lighter
    \\    vec3 c = texture(u_ground_tex2, uv3).rgb * 0.82;

    \\    float b1 = noised(vec3(p * 0.019 + vec2(4.1, 1.3), 1.0)).x;
    \\    float b2 = noised(vec3(p * 0.031 + vec2(9.7, 6.2), 5.0)).x;
    \\    // Dense grass is the base; the sparse dirt patch breaks it up in dry islands, and
    \\    // the moss texture appears in the damper, low-frequency patches.
    \\    float dry = smoothstep(0.48, 0.78, noised(vec3(p * 0.026 + vec2(2.3, 8.1), 4.0)).x);
    \\    float mossy = smoothstep(0.52, 0.82, noised(vec3(p * 0.033 + vec2(7.4, 1.9), 9.0)).x);
    \\    vec3 mixed = mix(a, b, dry * 0.45);
    \\    mixed = mix(mixed, c, mossy * 0.40);
    \\    return mixed * (0.82 + 0.36 * mott);
    \\}
    \\vec3 snowTexture(vec2 p, float mott, float snow) {
    \\    vec2 warp = vec2(noised(vec3(p * 0.041, 1.3)).x,
    \\                     noised(vec3(p * 0.047, 6.4)).x) - 0.5;
    \\    vec2 uv0 = rot2(0.61) * (p * 0.155 + warp * 0.08);
    \\    vec2 uv1 = rot2(2.23) * (p * 0.263 - warp * 0.06);
    \\    vec2 uv2 = rot2(4.41) * (p * 0.407 + warp * 0.05);
    \\    vec3 edge = texture(u_snow_tex0, uv0).rgb;
    \\    vec3 clean = texture(u_snow_tex1, uv1).rgb;
    \\    vec3 patch = texture(u_snow_tex2, uv2).rgb;
    \\    // Clean snow dominates where coverage is complete; patchy and grass-edge layers
    \\    // appear around the fringes so the cap does not look like a white blanket.
    \\    float edge_amt = 1.0 - smoothstep(0.18, 0.80, snow);
    \\    vec3 mixed = mix(clean, patch, 0.22 + 0.45 * edge_amt);
    \\    mixed = mix(mixed, edge, edge_amt * 0.42);
    \\    return mixed * (0.86 + 0.22 * mott);
    \\}
    \\vec3 shoreTexture(vec2 p, float mott, float wet) {
    \\    vec2 warp = vec2(noised(vec3(p * 0.053, 2.7)).x,
    \\                     noised(vec3(p * 0.049, 7.2)).x) - 0.5;
    \\    vec2 uv0 = rot2(1.07) * (p * 0.19 + warp * 0.07);
    \\    vec2 uv1 = rot2(2.71) * (p * 0.31 - warp * 0.05);
    \\    vec2 uv2 = rot2(5.19) * (p * 0.47 + warp * 0.04);
    \\    vec3 dirt = texture(u_shore_tex0, uv0).rgb;
    \\    vec3 sand = texture(u_shore_tex1, uv1).rgb;
    \\    vec3 mud = texture(u_shore_tex2, uv2).rgb;
    \\    vec3 mixed = mix(dirt, sand, 0.30 + 0.25 * wet);
    \\    mixed = mix(mixed, mud, wet * 0.55);
    \\    return mixed * (0.78 + 0.22 * mott);
    \\}
    \\vec3 rockTexture(vec2 p, float mott) {
    \\    vec2 warp = vec2(noised(vec3(p * 0.047, 5.1)).x,
    \\                     noised(vec3(p * 0.039, 2.9)).x) - 0.5;
    \\    vec2 uv0 = rot2(0.87) * (p * 0.13 + warp * 0.05);
    \\    vec2 uv1 = rot2(2.39) * (p * 0.23 - warp * 0.04);
    \\    vec2 uv2 = rot2(4.77) * (p * 0.37 + warp * 0.03);
    \\    vec3 rough = texture(u_rock_tex0, uv0).rgb;
    \\    vec3 granite = texture(u_rock_tex1, uv1).rgb;
    \\    vec3 stone = texture(u_rock_tex2, uv2).rgb;
    \\    float lichen = smoothstep(0.48, 0.78, noised(vec3(p * 0.057 + vec2(3.7, 6.1), 3.0)).x);
    \\    vec3 mixed = mix(granite, rough, 0.35 + 0.35 * lichen);
    \\    mixed = mix(mixed, stone, 0.22 + 0.30 * (1.0 - lichen));
    \\    return mixed * (0.78 + 0.30 * mott);
    \\}
    \\vec3 shIrradiance(vec3 n) {
    \\    float x = n.x, y = n.y, z = n.z;
    \\    return u_sh[0] * 0.282095
    \\         + u_sh[1] * (0.488603 * y)
    \\         + u_sh[2] * (0.488603 * z)
    \\         + u_sh[3] * (0.488603 * x)
    \\         + u_sh[4] * (1.092548 * x * y)
    \\         + u_sh[5] * (1.092548 * y * z)
    \\         + u_sh[6] * (0.315392 * (3.0 * z * z - 1.0))
    \\         + u_sh[7] * (1.092548 * x * z)
    \\         + u_sh[8] * (0.546274 * (x * x - y * y));
    \\}
    \\float shadowCascade(mat4 lvp, sampler2D map, vec3 world, vec3 n) {
    \\    vec4 lp = lvp * vec4(world + n * 0.10, 1.0);
    \\    vec3 p = lp.xyz / max(lp.w, 1e-5) * 0.5 + 0.5;
    \\    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;
    \\    float bias = 0.0015;
    \\    float texel = 1.0 / 2048.0;
    \\    float blocker = 0.0;
    \\    int blocker_count = 0;
    \\    for (int i = 0; i < 8; ++i) {
    \\        float a = float(i) * 0.785398;
    \\        float d = texture(map, p.xy + vec2(cos(a), sin(a)) * texel * 4.0).r;
    \\        if (d < p.z - bias) {
    \\            blocker += d;
    \\            blocker_count += 1;
    \\        }
    \\    }
    \\    if (blocker_count == 0) return 1.0;
    \\    float avg = blocker / float(blocker_count);
    \\    float radius = clamp((p.z - avg) * 120.0, 0.75, 6.0);
    \\    float sum = 0.0;
    \\    for (int y = -2; y <= 2; ++y) {
    \\        for (int x = -2; x <= 2; ++x) {
    \\            float d = texture(map, p.xy + vec2(x, y) * texel * radius * 0.5).r;
    \\            sum += (p.z - bias <= d) ? 1.0 : 0.0;
    \\        }
    \\    }
    \\    return sum / 25.0;
    \\}
    \\float sunShadow(vec3 world, vec3 n) {
    \\    if (u_shadow_enabled < 0.5) return 1.0;
    \\    float d = length(world - u_eye);
    \\    float s0 = shadowCascade(u_light_vp[0], u_shadow0, world, n);
    \\    float s1 = shadowCascade(u_light_vp[1], u_shadow1, world, n);
    \\    return mix(s0, s1, smoothstep(55.0, 75.0, d));
    \\}
    \\out vec4 frag;
    \\void main() {
    \\    // Two octaves of value noise in WORLD space: world-space means the pattern is continuous
    \\    // across every chunk border and stable through LOD, which blocky textures never were.
    \\    // u_detail = 0 skips the noise entirely (a coherent uniform branch) so the A/B measures
    \\    // the real cost and shows the surface before procedural materials.
    \\    float detail = 0.5;
    \\    vec3 grad = vec3(0.0);
    \\    // Fine grain aliases once it is smaller than a pixel; fade it out with distance and keep
    \\    // the broad patch term, the same rule the engine's water normal detail uses.
    \\    float view_dist = length(v_pos - u_eye);
    \\    float fine_fade = 1.0 - smoothstep(20.0, 70.0, view_dist);
    \\    if (u_detail > 0.5) {
    \\        vec4 o1 = noised(v_pos * 2.20);              // ~0.45 m grain
    \\        vec4 o2 = noised(v_pos * 0.35 + 11.0);       // ~2.9 m patches
    \\        float w1 = 0.55 * fine_fade;
    \\        float w2 = 0.45;
    \\        detail = (o1.x * w1 + o2.x * w2) / (w1 + w2);
    \\        grad = o1.yzw * (w1 * 2.20) + o2.yzw * (w2 * 0.35);
    \\    }
    \\
    \\    // Bump without a normal map: surface normal plus a scaled noise gradient, IQ's form.
    \\    // bump is per material - rock is rougher than ground, scree roughest.
    \\    float bump = v_mat < 0.5 ? 0.18 : (v_mat < 1.5 ? 0.35 : 0.55);
    \\    vec3 n = normalize(v_nrm + grad * bump);
    \\    vec3 l = normalize(u_sun_dir);
    \\    // Surface rules (10.8): altitude gives snow, proximity to the sea gives mud and a wet rim.
    \\    // The masks are noise-warped so their edges do not follow a height contour, and both are
    \\    // gated on the geometric normal so cliffs stay bare. mott doubles as colour variation.
    \\    float mott = 0.5;
    \\    float snow = 0.0;
    \\    float mud = 0.0;
    \\    float wet = 0.0;
    \\    if (u_surfaces > 0.5) {
    \\        vec4 m = noised(v_pos * 0.055 + vec3(7.1, 2.3, 4.9));
    \\        mott = m.x;
    \\        float warp = m.x - 0.5;
    \\        float up = normalize(v_nrm).y;
    \\        float snow_h = u_snow_line + warp * 2.0;
    \\        snow = smoothstep(snow_h, snow_h + 3.0, v_pos.y)
    \\             * smoothstep(0.65, 0.85, up);
    \\        // Break the cap with bare rock patches and give the snow surface a drift normal:
    \\        // without this the plateau reads as one flat white slab.
    \\        vec4 d = noised(v_pos * 0.45 + vec3(13.0, 2.0, 7.0));
    \\        snow *= 1.0 - 0.55 * smoothstep(0.35, 0.60, d.x);
    \\        n = normalize(n + (d.yzw * 0.9 + m.yzw * 0.3) * snow);
    \\        float shore = abs(v_pos.y - u_sea_level) + warp * 1.5;
    \\        mud = (1.0 - smoothstep(0.0, u_mud_band, shore))
    \\            * smoothstep(0.60, 0.82, up);
    \\        wet = (1.0 - smoothstep(0.0, 0.9, max(v_pos.y - u_sea_level, 0.0)))
    \\            * step(u_sea_level - 0.05, v_pos.y);
    \\    }
    \\    // Snow fills crevices, so flatten the normal toward up where it lies.
    \\    n = normalize(mix(n, vec3(0.0, 1.0, 0.0), snow * 0.10));
    \\    float ndl = max(dot(n, l), 0.0);
    \\    float shadow = sunShadow(v_pos, n);
    \\    // Sky irradiance from SH9 replaces the old constant hemisphere (ADR 0027). The ground
    \\    // bounce is a small downward term; the sun stays a separate directional light.
    \\    vec3 amb = max(shIrradiance(n), vec3(0.0)) + u_ambient_ground * max(-n.y, 0.0) * 0.35;
    \\    float ao = 1.0;
    \\    if (u_ao_enabled > 0.5) {
    \\        vec2 auv = (v_pos.xz - u_ao_origin) / max(u_ao_size, 1.0);
    \\        if (auv.x >= 0.0 && auv.x <= 1.0 && auv.y >= 0.0 && auv.y <= 1.0) {
    \\            ao = texture(u_ao_tex, auv).r;
    \\        }
    \\    }
    \\    amb *= ao;
    \\    amb *= mix(0.58, 1.0, shadow);
    \\    vec3 albedo = v_col * (0.72 + 0.56 * detail);
    \\    if (u_ground_enabled > 0.5) {
    \\        // Ground only: keep the fine grass photo off rock/scree, snow, mud and steep faces.
    \\        float flatness = smoothstep(0.55, 0.85, normalize(v_nrm).y);
    \\        float ground_mask = (1.0 - smoothstep(0.45, 0.55, v_mat)) * flatness
    \\                          * (1.0 - snow) * (1.0 - mud);
    \\        vec3 ground = groundTexture(v_pos.xz, mott) * 1.10;
    \\        albedo = mix(albedo, ground, ground_mask * 0.85);
    \\    }
    \\    if (u_rock_enabled > 0.5) {
    \\        vec3 an = abs(normalize(v_nrm));
    \\        vec2 rock_uv = v_pos.xz;
    \\        if (an.y <= max(an.x, an.z)) rock_uv = an.x > an.z ? v_pos.zy : v_pos.xy;
    \\        float rock_mask = smoothstep(0.45, 0.55, v_mat) * (1.0 - snow) * (1.0 - mud);
    \\        vec3 rock = rockTexture(rock_uv, mott);
    \\        albedo = mix(albedo, rock, rock_mask * 0.82);
    \\    }
    \\    // Lighting is deliberately shy of 1.0: albedo arrives already close to mid grey, and
    \\    // multiplying it by ~1.8 and then gamma-encoding clips the whole surface to white.
    \\    // Exposure + ACES (Narkowicz), the same curve the engine's post pass applies (ADR 0011).
    \\    // Without it, linear radiance above 1.0 clips to white once the sRGB framebuffer encodes,
    \\    // which is what turned the surface into a pale sheet the moment FRAMEBUFFER_SRGB went on.
    \\    vec3 surf = albedo;
    \\    if (mud > 0.001 && u_shore_enabled > 0.5) {
    \\        vec3 shore = shoreTexture(v_pos.xz, mott, wet);
    \\        surf = mix(surf, shore, mud * (1.0 - snow) * 0.90);
    \\    } else {
    \\        surf = mix(surf, vec3(0.34, 0.27, 0.20), mud * (1.0 - snow));
    \\        surf = mix(surf, vec3(0.16, 0.13, 0.10), mud * wet * 0.55 * (1.0 - snow));
    \\    }
    \\    if (snow > 0.001 && u_snow_enabled > 0.5) {
    \\        vec3 snow_col = snowTexture(v_pos.xz, mott, snow);
    \\        surf = mix(surf, snow_col, snow * 0.92);
    \\    } else {
    \\        surf = mix(surf, vec3(0.84, 0.88, 0.95) * (0.90 + 0.12 * mott), snow);
    \\    }
    \\    // Snow is a bright diffuse surface; wet mud needs a specular rim to read as wet.
    \\    float exposure = mix(0.16, 0.34, snow);
    \\    exposure *= mix(1.0, 0.92, mud * (1.0 - snow));
    \\    vec3 c = surf * (amb + u_sun_colour * ndl * 1.15 * shadow * mix(0.72, 1.0, ao)) * exposure;
    \\    vec3 view = normalize(u_eye - v_pos);
    \\    vec3 hv = normalize(l + view);
    \\    float spec = pow(max(dot(n, hv), 0.0), 42.0);
    \\    c += u_sun_colour * vec3(spec * shadow * (mud * wet * 0.30 + snow * 0.05));
    \\    c = clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 0.0, 1.0);
    \\    vec3 outc = pow(c, vec3(0.4545));
    \\    if (u_atmosphere > 0.5) {
    \\        // Aerial perspective: integrate an exponential height density along the view ray.
    \\        // tau = d0 * exp(-(eye.y - base)/H) * dist * (1 - exp(-dy/H)) / (dy/H), the closed form
    \\        // of a single-scale-height medium (Decima's analytic height fog; ADR 0021). The colour
    \\        // is the horizon scattering colour plus a forward-scatter tint toward the sun. Blended
    \\        // in the terrain shader's display space, the same space the rest of this surface uses.
    \\        vec3 ray = v_pos - u_eye;
    \\        float dist = length(ray);
    \\        float H = max(u_fog_height, 1.0);
    \\        float k = ray.y / H;
    \\        float d0 = u_fog_density * exp(-(u_eye.y - u_fog_base) / H);
    \\        float tau = abs(k) > 1e-4 ? d0 * dist * (1.0 - exp(-k)) / k : d0 * dist;
    \\        tau = max(tau, 0.0);
    \\        float fog = 1.0 - exp(-tau);
    \\        float sun_amt = pow(max(dot(normalize(ray), u_sun_dir), 0.0), 6.0);
    \\        vec3 fogc = mix(u_fog_colour, u_fog_sun, 0.15 + 0.55 * sun_amt);
    \\        outc = mix(outc, fogc, fog);
    \\    }
    \\    frag = vec4(outc, 1.0);
    \\}
;

/// Owns the terrain program and its VAO/VBO/EBO. One instance per window.
pub const DcRenderer = struct {
    shader: Shader,
    depth_shader: Shader,
    vao: u32 = 0,
    vbo: u32 = 0,
    ebo: u32 = 0,
    ao_tex: u32 = 0,
    ao_min_x: f32 = 0,
    ao_min_z: f32 = 0,
    ao_size: f32 = 256,
    ao_enabled: bool = true,
    ground_tex: [3]u32 = .{ 0, 0, 0 },
    snow_tex: [3]u32 = .{ 0, 0, 0 },
    shore_tex: [3]u32 = .{ 0, 0, 0 },
    rock_tex: [3]u32 = .{ 0, 0, 0 },

    pub fn init() !DcRenderer {
        var shader = try Shader.init(vertex_src, fragment_src);
        errdefer shader.deinit();
        var depth_shader = try Shader.init(depth_vertex_src, depth_fragment_src);
        errdefer depth_shader.deinit();
        var ao_tex: u32 = 0;
        gl.GenTextures(1, @ptrCast(&ao_tex));
        gl.BindTexture(gl.TEXTURE_2D, ao_tex);
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, 64, 64, 0, gl.RED, gl.UNSIGNED_BYTE, null);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.BindTexture(gl.TEXTURE_2D, 0);

        // Three small ground photos, embedded so the binary still runs from any working
        // directory. Mipmaps and repeat wrapping are essential at 4K.
        stb.stbi_set_flip_vertically_on_load(0);
        const ground_jpgs = [_][]const u8{ ground_jpg, ground_patch_jpg, ground_moss_jpg };
        var ground_tex: [3]u32 = .{ 0, 0, 0 };
        for (ground_jpgs, 0..) |jpg, i| {
            var gw: c_int = 0;
            var gh: c_int = 0;
            var gch: c_int = 0;
            const pixels = stb.stbi_load_from_memory(jpg.ptr, @intCast(jpg.len), &gw, &gh, &gch, 4) orelse
                return error.GroundTextureLoad;
            defer stb.stbi_image_free(pixels);
            gl.GenTextures(1, @ptrCast(&ground_tex[i]));
            gl.BindTexture(gl.TEXTURE_2D, ground_tex[i]);
            gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, gw, gh, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
            gl.GenerateMipmap(gl.TEXTURE_2D);
        }
        gl.BindTexture(gl.TEXTURE_2D, 0);

        const snow_jpgs = [_][]const u8{ snow_grass_jpg, snow_clean_jpg, snow_patch_jpg };
        var snow_tex: [3]u32 = .{ 0, 0, 0 };
        for (snow_jpgs, 0..) |jpg, i| {
            var sw: c_int = 0;
            var sh: c_int = 0;
            var sch: c_int = 0;
            const pixels = stb.stbi_load_from_memory(jpg.ptr, @intCast(jpg.len), &sw, &sh, &sch, 4) orelse
                return error.SnowTextureLoad;
            defer stb.stbi_image_free(pixels);
            gl.GenTextures(1, @ptrCast(&snow_tex[i]));
            gl.BindTexture(gl.TEXTURE_2D, snow_tex[i]);
            gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, sw, sh, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
            gl.GenerateMipmap(gl.TEXTURE_2D);
        }
        gl.BindTexture(gl.TEXTURE_2D, 0);

        const shore_jpgs = [_][]const u8{ shore_dirt_jpg, shore_sand_jpg, shore_mud_jpg };
        var shore_tex: [3]u32 = .{ 0, 0, 0 };
        for (shore_jpgs, 0..) |jpg, i| {
            var sw: c_int = 0;
            var sh: c_int = 0;
            var sch: c_int = 0;
            const pixels = stb.stbi_load_from_memory(jpg.ptr, @intCast(jpg.len), &sw, &sh, &sch, 4) orelse
                return error.ShoreTextureLoad;
            defer stb.stbi_image_free(pixels);
            gl.GenTextures(1, @ptrCast(&shore_tex[i]));
            gl.BindTexture(gl.TEXTURE_2D, shore_tex[i]);
            gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, sw, sh, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
            gl.GenerateMipmap(gl.TEXTURE_2D);
        }
        gl.BindTexture(gl.TEXTURE_2D, 0);

        const rock_jpgs = [_][]const u8{ rock_rough_jpg, rock_granite_jpg, rock_stone_jpg };
        var rock_tex: [3]u32 = .{ 0, 0, 0 };
        for (rock_jpgs, 0..) |jpg, i| {
            var rw: c_int = 0;
            var rh: c_int = 0;
            var rch: c_int = 0;
            const pixels = stb.stbi_load_from_memory(jpg.ptr, @intCast(jpg.len), &rw, &rh, &rch, 4) orelse
                return error.RockTextureLoad;
            defer stb.stbi_image_free(pixels);
            gl.GenTextures(1, @ptrCast(&rock_tex[i]));
            gl.BindTexture(gl.TEXTURE_2D, rock_tex[i]);
            gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, rw, rh, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
            gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
            gl.GenerateMipmap(gl.TEXTURE_2D);
        }
        gl.BindTexture(gl.TEXTURE_2D, 0);

        return .{ .shader = shader, .depth_shader = depth_shader, .ao_tex = ao_tex, .ground_tex = ground_tex, .snow_tex = snow_tex, .shore_tex = shore_tex, .rock_tex = rock_tex };
    }

    pub fn deinit(self: *DcRenderer) void {
        if (self.vao != 0) {
            gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
            gl.DeleteBuffers(1, @ptrCast(&self.vbo));
            gl.DeleteBuffers(1, @ptrCast(&self.ebo));
        }
        if (self.ao_tex != 0) gl.DeleteTextures(1, @ptrCast(&self.ao_tex));
        for (0..3) |i| {
            if (self.ground_tex[i] != 0) gl.DeleteTextures(1, @ptrCast(&self.ground_tex[i]));
            if (self.snow_tex[i] != 0) gl.DeleteTextures(1, @ptrCast(&self.snow_tex[i]));
            if (self.shore_tex[i] != 0) gl.DeleteTextures(1, @ptrCast(&self.shore_tex[i]));
            if (self.rock_tex[i] != 0) gl.DeleteTextures(1, @ptrCast(&self.rock_tex[i]));
        }
        self.depth_shader.deinit();
        self.shader.deinit();
    }

    /// Uploads the 64x64 heightfield AO map and the patch origin it covers.
    pub fn uploadAo(self: *DcRenderer, data: []const u8, min_x: f32, min_z: f32, size: f32) void {
        if (data.len != 64 * 64) return;
        self.ao_min_x = min_x;
        self.ao_min_z = min_z;
        self.ao_size = size;
        gl.BindTexture(gl.TEXTURE_2D, self.ao_tex);
        gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 64, 64, gl.RED, gl.UNSIGNED_BYTE, data.ptr);
        gl.BindTexture(gl.TEXTURE_2D, 0);
    }

    pub fn setAoEnabled(self: *DcRenderer, enabled: bool) void {
        self.ao_enabled = enabled;
    }

    /// Depth-only pass into a sun shadow cascade. The caller has already bound the FBO and set
    /// the light matrix on `depth_shader`.
    pub fn drawDepth(self: *DcRenderer, view_projection: Mat4, index_count: usize) void {
        self.depth_shader.use();
        self.depth_shader.setMat4("u_mvp", view_projection.m);
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        gl.BindVertexArray(self.vao);
        gl.DrawElements(gl.TRIANGLES, @intCast(index_count), gl.UNSIGNED_INT, 0);
    }

    pub fn upload(self: *DcRenderer, verts: []const Vertex, idx: []const u32) void {
        if (self.vao == 0) {
            gl.GenVertexArrays(1, @ptrCast(&self.vao));
            gl.GenBuffers(1, @ptrCast(&self.vbo));
            gl.GenBuffers(1, @ptrCast(&self.ebo));
        }
        gl.BindVertexArray(self.vao);
        gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(verts.len * @sizeOf(Vertex)), verts.ptr, gl.STATIC_DRAW);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.ebo);
        gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(idx.len * @sizeOf(u32)), idx.ptr, gl.STATIC_DRAW);
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), 0);
        gl.EnableVertexAttribArray(1);
        gl.VertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32));
        gl.EnableVertexAttribArray(2);
        gl.VertexAttribPointer(2, 3, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32) * 2);
        gl.EnableVertexAttribArray(3);
        gl.VertexAttribPointer(3, 1, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @sizeOf([3]f32) * 3);
        gl.BindVertexArray(0);
    }

    /// Draws the terrain. The app owns clear/viewport; this owns the depth/blend/cull state the
    /// HUD leaves behind and the fog uniforms.
    pub fn draw(
        self: *DcRenderer,
        view_projection: Mat4,
        eye: Vec3,
        sun_dir: Vec3,
        sun_colour: Vec3,
        ambient_ground: Vec3,
        sh: [9]Vec3,
        fog_colour: Vec3,
        fog_sun: Vec3,
        fog_density: f32,
        fog_height: f32,
        fog_base: f32,
        atmosphere: bool,
        detail: f32,
        surfaces: f32,
        sea_level: f32,
        snow_line: f32,
        mud_band: f32,
        shadow: *ShadowRenderer,
        index_count: usize,
    ) void {
        gl.Enable(gl.DEPTH_TEST);
        gl.DepthMask(gl.TRUE);
        gl.Disable(gl.BLEND);
        gl.Disable(gl.CULL_FACE);
        self.shader.use();
        self.shader.setMat4("u_view_proj", view_projection.m);
        self.shader.setVec3("u_eye", .{ eye.x, eye.y, eye.z });
        self.shader.setVec3("u_sun_dir", .{ sun_dir.x, sun_dir.y, sun_dir.z });
        self.shader.setVec3("u_sun_colour", .{ sun_colour.x, sun_colour.y, sun_colour.z });
        self.shader.setVec3("u_ambient_ground", .{ ambient_ground.x, ambient_ground.y, ambient_ground.z });
        const sh_names: [9][:0]const u8 = .{
            "u_sh[0]", "u_sh[1]", "u_sh[2]", "u_sh[3]", "u_sh[4]", "u_sh[5]", "u_sh[6]", "u_sh[7]", "u_sh[8]",
        };
        for (sh_names, 0..) |name, i| {
            self.shader.setVec3(name, .{ sh[i].x, sh[i].y, sh[i].z });
        }
        shadow.setUniforms(&self.shader);
        self.shader.setInt("u_ao_tex", 3);
        self.shader.setFloat2("u_ao_origin", .{ self.ao_min_x, self.ao_min_z });
        self.shader.setFloat("u_ao_size", self.ao_size);
        self.shader.setFloat("u_ao_enabled", if (self.ao_enabled) 1.0 else 0.0);
        gl.ActiveTexture(gl.TEXTURE3);
        gl.BindTexture(gl.TEXTURE_2D, self.ao_tex);
        const tex_names: [12][:0]const u8 = .{
            "u_ground_tex0", "u_ground_tex1", "u_ground_tex2",
            "u_snow_tex0",   "u_snow_tex1",   "u_snow_tex2",
            "u_shore_tex0",  "u_shore_tex1",  "u_shore_tex2",
            "u_rock_tex0",   "u_rock_tex1",   "u_rock_tex2",
        };
        for (tex_names, 0..) |name, i| {
            const slot: c_int = 4 + @as(c_int, @intCast(i));
            self.shader.setInt(name, slot);
            gl.ActiveTexture(gl.TEXTURE4 + @as(u32, @intCast(i)));
            const tex = if (i < 3) self.ground_tex[i] else if (i < 6) self.snow_tex[i - 3] else if (i < 9) self.shore_tex[i - 6] else self.rock_tex[i - 9];
            gl.BindTexture(gl.TEXTURE_2D, tex);
        }
        self.shader.setFloat("u_ground_enabled", 1.0);
        self.shader.setFloat("u_snow_enabled", 1.0);
        self.shader.setFloat("u_shore_enabled", 1.0);
        self.shader.setFloat("u_rock_enabled", 1.0);
        gl.ActiveTexture(gl.TEXTURE0);
        self.shader.setVec3("u_fog_colour", .{ fog_colour.x, fog_colour.y, fog_colour.z });
        self.shader.setVec3("u_fog_sun", .{ fog_sun.x, fog_sun.y, fog_sun.z });
        self.shader.setFloat("u_fog_density", fog_density);
        self.shader.setFloat("u_fog_height", fog_height);
        self.shader.setFloat("u_fog_base", fog_base);
        self.shader.setFloat("u_atmosphere", if (atmosphere) 1.0 else 0.0);
        self.shader.setFloat("u_detail", detail);
        self.shader.setFloat("u_surfaces", surfaces);
        self.shader.setFloat("u_sea_level", sea_level);
        self.shader.setFloat("u_snow_line", snow_line);
        self.shader.setFloat("u_mud_band", mud_band);
        gl.BindVertexArray(self.vao);
        gl.DrawElements(gl.TRIANGLES, @intCast(index_count), gl.UNSIGNED_INT, 0);
    }
};
