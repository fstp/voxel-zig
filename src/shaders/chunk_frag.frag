#version 460 core
uniform sampler2DArray u_tex;
uniform float u_legacy;  // 1 = the old face table, 0 = sun lighting (F4 A/B)
uniform float u_normals; // 1 = debug view: colour by normal (F6)
uniform vec3 u_sun_dir;  // toward the sun, unit
uniform vec3 u_sun_colour;    // linear, scaled by sun height
uniform vec3 u_ambient_sky;   // linear hemisphere ambient, up
uniform vec3 u_ambient_ground;
uniform vec3 u_eye;
uniform vec3 u_sky_horizon;  // same ramp the sky pass draws with
uniform vec3 u_sky_zenith;
uniform float u_fog_start;
uniform float u_fog_end;
uniform float u_fog_enabled;
uniform sampler2D u_shadow;   // depth from the sun, unit 1
uniform mat4 u_light_vp;
uniform vec2 u_shadow_texel;
uniform float u_shadow_bias;
uniform float u_shadow_normal_offset;
uniform float u_shadow_pcf_radius; // in texels (3.12: soft edges)
uniform int u_shadow_kernel;       // 1 = 3x3, 2 = 5x5 taps (hard mode)
uniform float u_shadow_uv_per_block;   // uv units per block in light space
uniform float u_shadow_depth_range;    // blocks across the 0..1 depth range
uniform float u_shadow_light_size;     // artistic sun size, drives the penumbra
uniform int u_shadow_quality;          // 0 = hard PCF, 1 = PCSS
uniform float u_shadows_enabled;
uniform vec4 u_material[8];   // per layer: x roughness, y metallic, z diffuse, w unused
uniform samplerCube u_env;    // sky probe (4.4), unit 2
uniform sampler2DArray u_normal; // tangent-space normals (4.7), unit 3
uniform sampler2DArray u_rough;  // per-texel roughness (4.7), unit 4
uniform float u_env_max_mip;
in vec2 v_uv;
in float v_layer;
in float v_ao;
in float v_face;
in vec3 v_normal;
in vec3 v_world;
in float v_wave;
uniform float u_water_layer_f;
uniform float u_foam;
uniform float u_debug_flat; // 1 = paint water a flat colour, to tell a gap from a shading line
uniform float u_time;
uniform float u_wave_amp;
uniform float u_waves;
out vec4 f_colour;

float hash21(vec2 p) {
    p = fract(p * vec2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

float vnoise2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x),
               mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}

// Cheap directional stand-in for lighting: face order is px, nx, py, ny, pz, nz.
float faceBrightness(float id) {
    if (id < 0.5) return 0.80; // +x
    if (id < 1.5) return 0.80; // -x
    if (id < 2.5) return 1.00; // +y
    if (id < 3.5) return 0.50; // -y
    if (id < 4.5) return 0.65; // +z
    return 0.65;               // -z
}
// 16-point Poisson disc, reused for the blocker search (first 8) and the PCF.
const vec2 POISSON[16] = vec2[16](
    vec2(-0.613, 0.617), vec2(0.170, -0.040), vec2(-0.299, -0.792), vec2(0.645, 0.493),
    vec2(-0.651, -0.110), vec2(0.421, -0.599), vec2(-0.072, 0.888), vec2(0.915, -0.016),
    vec2(-0.218, 0.328), vec2(0.376, 0.780), vec2(-0.905, -0.421), vec2(0.590, -0.383),
    vec2(0.043, -0.317), vec2(-0.437, 0.892), vec2(0.870, 0.372), vec2(-0.836, 0.088)
);

// Percentage-closer soft shadows (5.1): find the average occluder, then widen
// the filter by how far the receiver is behind it. That is what makes a shadow
// hard where a block touches the ground and soft where it is metres above it,
// instead of one fixed blur everywhere.
float pcss(vec3 p) {
    float blocker_sum = 0.0;
    float blockers = 0.0;
    float search = 7.0; // texels
    for (int i = 0; i < 8; ++i) {
        float d = texture(u_shadow, p.xy + POISSON[i] * u_shadow_texel * search).r;
        if (p.z - u_shadow_bias > d) {
            blocker_sum += d;
            blockers += 1.0;
        }
    }
    if (blockers < 0.5) return 1.0;

    float avg_blocker = blocker_sum / blockers;
    // Similar triangles give penumbra = gap * light_size / blocker_distance, but
    // with an orthographic light the "blocker distance" is just how far the map
    // was fitted back (420 blocks), so the textbook form collapses to a fraction
    // of a texel and every shadow stays hard. Using the gap directly keeps the
    // property that matters - contact hard, distant soft - with one constant.
    float gap_blocks = max(p.z - avg_blocker, 0.0) * u_shadow_depth_range;
    float penumbra_blocks = gap_blocks * u_shadow_light_size;
    float radius = penumbra_blocks * u_shadow_uv_per_block;
    radius = clamp(radius, u_shadow_texel.x, 12.0 * u_shadow_texel.x);

    float lit = 0.0;
    for (int i = 0; i < 16; ++i) {
        float depth = texture(u_shadow, p.xy + POISSON[i] * radius).r;
        lit += (p.z - u_shadow_bias <= depth) ? 1.0 : 0.0;
    }
    return lit / 16.0;
}

// 3x3 PCF with a normal offset: offsetting along the normal is what kills
// the acne that a depth bias alone leaves on large flat voxel faces.
float sunVisibility(vec3 world, vec3 normal) {
    if (u_shadows_enabled < 0.5) return 1.0;
    vec4 light_position = u_light_vp * vec4(world + normal * u_shadow_normal_offset, 1.0);
    vec3 p = light_position.xyz / light_position.w * 0.5 + 0.5;
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;
    // Fade the shadow out over the last few percent of the map instead of stepping
    // to "fully lit" at its edge. Over a flat surface that step is a perfectly
    // straight bright seam, which is exactly what was lying across the sea.
    float edge = min(min(p.x, 1.0 - p.x), min(p.y, 1.0 - p.y));
    float edge_fade = smoothstep(0.0, 0.06, edge);
    if (u_shadow_quality == 1) return mix(1.0, pcss(p), edge_fade);
    float sum = 0.0;
    float taps = 0.0;
    for (int y = -u_shadow_kernel; y <= u_shadow_kernel; ++y) {
        for (int x = -u_shadow_kernel; x <= u_shadow_kernel; ++x) {
            taps += 1.0;
            float depth = texture(u_shadow, p.xy + vec2(float(x), float(y)) * u_shadow_texel * u_shadow_pcf_radius).r;
            sum += (p.z - u_shadow_bias <= depth) ? 1.0 : 0.0;
        }
    }
    return mix(1.0, sum / taps, edge_fade);
}

const float PI = 3.14159265;

// GGX / Trowbridge-Reitz: the shape of the specular lobe. Rough surfaces
// spread the highlight, smooth ones keep it tight.
float D_GGX(float noh, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float d = noh * noh * (a2 - 1.0) + 1.0;
    return a2 / max(PI * d * d, 1e-7);
}

// Smith height-correlated visibility. Returns 1/(4 N.V N.L) folded in, which
// is why the specular term below has no denominator of its own.
float V_SmithGGX(float nov, float nol, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float gv = nol * sqrt(nov * nov * (1.0 - a2) + a2);
    float gl = nov * sqrt(nol * nol * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-7);
}

vec3 F_Schlick(vec3 f0, float voh) {
    return f0 + (vec3(1.0) - f0) * pow(clamp(1.0 - voh, 0.0, 1.0), 5.0);
}

// 4.8: per-block UV variation. Every face maps its texture 0..1, so a wall of
// stone repeats the same image block after block. Hashing the owning block's
// coordinate gives each face its own offset and mirror flags, which breaks the
// grid without any vertex data: the hash is constant across a one-block face,
// so the quad still samples one continuous piece of the texture.
float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

vec2 blockUV(vec3 world, vec3 normal, vec2 uv) {
    vec3 cell = floor(world - normal * 0.5 + normal * 0.001);
    float h = hash13(cell + normal * 17.0);
    // Mirroring keeps the tile seamless where a plain rotation would not for
    // quads that span more than one block (greedy meshing).
    if (h > 0.75) uv.x = 1.0 - uv.x;
    else if (h > 0.5) uv.y = 1.0 - uv.y;
    else if (h > 0.25) uv = vec2(1.0 - uv.x, 1.0 - uv.y);
    // Offset by a hash of the same cell, in the other two axes so it is
    // independent of the mirror choice.
    vec2 offset = vec2(hash13(cell.yzx + 5.0), hash13(cell.zxy + 11.0));
    return uv + offset;
}

void main() {
    vec3 geoN = normalize(v_normal);
    vec2 uv = blockUV(v_world, geoN, v_uv);
    vec4 c = texture(u_tex, vec3(uv, v_layer));
    if (c.a < 0.5) discard; // alpha cutout (leaves, ADR 0002)
    if (u_debug_flat > 0.5 && abs(v_layer - u_water_layer_f) < 0.5) {
        // Diagnostic: a gap in the water shows the background here, a shading
        // discontinuity shows as a different shade of magenta.
        f_colour = vec4(1.0, 0.0, 1.0, 1.0);
        return;
    }
    // AO 0..15 (3.12) with a curve: more bands than the old 0..3, and the
    // curve keeps the darkest step from reading as a black line.
    float ao = mix(0.42, 1.0, pow(clamp(v_ao / 15.0, 0.0, 1.0), 0.85));
    if (u_normals > 0.5) {
        // Debug: -1..1 mapped to 0..1, so +Y is green, +X red, +Z blue.
        // The framebuffer is sRGB (ADR 0008), so encode here or the colours
        // come out washed out.
        f_colour = vec4(pow(v_normal * 0.5 + 0.5, vec3(2.2)), 1.0);
        return;
    }
    // Physical shading (ADR 0011): metallic-roughness, one directional light
    // plus the sky as ambient. The material comes from the texture layer, so
    // the vertex format and the mesher are untouched.
    vec4 material = u_material[int(v_layer + 0.5)];
    float roughness = clamp(material.x, 0.06, 1.0);
    float metallic = clamp(material.y, 0.0, 1.0);
    // 4.4: water sets this near zero, so its bright albedo stops drowning the
    // reflection it is supposed to show.
    float diffuse_scale = clamp(material.z, 0.0, 1.0);
    vec3 albedo = c.rgb * diffuse_scale;

    // 4.7: tangent basis. Every voxel face is axis aligned, so the basis falls
    // out of the face normal - no tangent attribute, no vertex change.
    vec3 T = (abs(geoN.y) > 0.5) ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0);
    vec3 B = cross(geoN, T);
    bool is_water = abs(v_layer - u_water_layer_f) < 0.5;
    vec3 tangent_normal;
    if (is_water && u_waves > 0.5) {
        // Two copies of the water normal map drifting at different speeds and
        // scales: the sum never repeats on screen even though each layer tiles.
        vec2 uv1 = uv + vec2(u_time * 0.035, u_time * 0.021);
        vec2 uv2 = uv * 1.7 + vec2(-u_time * 0.026, u_time * 0.018);
        vec3 n1 = texture(u_normal, vec3(uv1, v_layer)).rgb * 2.0 - 1.0;
        vec3 n2 = texture(u_normal, vec3(uv2, v_layer)).rgb * 2.0 - 1.0;
        // GPU Gems 1 ch. 1 attenuates any wave the surface cannot represent.
        // Here the pixel is the limit: past a few tens of blocks the ripple
        // detail is smaller than a pixel, and all it can do is shimmer.
        float detail = 1.0 - smoothstep(20.0, 70.0, length(u_eye - v_world));
        tangent_normal = vec3((n1.xy + n2.xy) * 0.9 * detail, 1.0);
    } else {
        tangent_normal = texture(u_normal, vec3(uv, v_layer)).rgb * 2.0 - 1.0;
    }
    // Photo normals at one block per metre are far stronger than the surface
    // they describe; half strength reads as relief instead of wet tarmac.
    tangent_normal = vec3(tangent_normal.xy * 0.55, tangent_normal.z);
    vec3 N = normalize(T * tangent_normal.x + B * tangent_normal.y + geoN * max(tangent_normal.z, 0.15));

    // Per-texel roughness, mostly the map and partly the layer's own value, so
    // the table still controls the material's character.
    roughness = clamp(mix(roughness, texture(u_rough, vec3(uv, v_layer)).r, 0.8), 0.06, 1.0);

    vec3 V = normalize(u_eye - v_world);
    vec3 L = u_sun_dir;
    vec3 H = normalize(V + L);
    float ndl = max(dot(N, L), 0.0);
    float ndv = max(dot(N, V), 1e-4);
    float ndh = max(dot(N, H), 0.0);
    float vdh = max(dot(V, H), 0.0);

    // A dielectric reflects 4 percent at normal incidence; a metal reflects its
    // own albedo and has no diffuse lobe at all.
    vec3 f0 = mix(vec3(0.04), c.rgb, metallic);
    vec3 fresnel = F_Schlick(f0, vdh);
    vec3 specular = D_GGX(ndh, roughness) * V_SmithGGX(ndv, ndl, roughness) * fresnel;
    if (is_water) specular *= 0.55;
    // Energy conservation: whatever is reflected specularly cannot also diffuse.
    vec3 diffuse = (vec3(1.0) - fresnel) * (1.0 - metallic) * albedo / PI;

    // u_sun_colour is scaled for the old Lambert path, so it carries an implicit
    // PI: multiply it back here rather than retuning the sky that shares it.
    // Water takes no shadow lookup: its map covers 230 blocks around the player, and
    // the boundary of that coverage draws a straight line across an otherwise flat
    // sea. Water gains almost nothing from self-shadowing, so skipping it costs the
    // look nothing and removes the seam.
    float visibility = is_water ? 1.0 : sunVisibility(v_world, geoN);
    vec3 direct = (diffuse + specular) * u_sun_colour * PI * ndl * visibility;

    vec3 hemi = mix(u_ambient_ground, u_ambient_sky, N.y * 0.5 + 0.5);
    // 4.4: the reflected ray is looked up in the sky probe with the mip chosen
    // by roughness, so a polished face mirrors the gradient and the sun while
    // a rough one averages to a soft sheen.
    vec3 R = reflect(-V, N);
    vec3 environment = textureLod(u_env, R, roughness * u_env_max_mip).rgb;
    vec3 ambient_specular = environment * F_Schlick(f0, ndv);
    vec3 ambient = (hemi * albedo * (1.0 - metallic) + ambient_specular) * ao;

    // AO darkens the ambient fully and the direct sun only partly: the shadow
    // map is what should darken a lit face that is in shadow, and multiplying
    // both factors at full strength made corners twice as dark as either.
    vec3 lit = direct * mix(0.55, 1.0, ao) + ambient;
    // F4 A/B: the old hardcoded table, kept so 3.9 can show the difference.
    vec3 legacy = vec3(faceBrightness(v_face) * ao);
    vec3 rgb = mix(c.rgb * lit, c.rgb * legacy, u_legacy);

    // 5.6: foam rides the crests. Height comes from the same wave function the
    // vertex stage displaced with, so the white caps sit exactly where the water
    // is highest; the noise breaks the line so it does not read as a contour.
    if (is_water && u_foam > 0.5 && u_waves > 0.5) {
        // Only the very top of the swell: a low threshold put foam on a third
        // of the sea, which read as static speckle instead of breaking crests.
        float crest = smoothstep(0.72, 1.00, v_wave / max(u_wave_amp, 1e-3));
        float n = vnoise2(v_world.xz * 0.40 + vec2(u_time * 0.20, -u_time * 0.13));
        float foam = crest * smoothstep(0.48, 0.78, n) * 0.8;
        vec3 foam_colour = vec3(0.90, 0.94, 1.0) * (u_sun_colour * 0.8 + u_ambient_sky * 0.7);
        rgb = mix(rgb, foam_colour, foam);
    }

    // Distance fog, in linear space, coloured by the same sky gradient the sky
    // pass draws (3.7). Duplicated on purpose: two lines and one pair of
    // uniforms is cheaper than a texture lookup, and the uniforms come from
    // the same sun.ramp() call, so they cannot drift.
    if (u_fog_enabled > 0.5) {
        vec3 to_fragment = v_world - u_eye;
        float distance = length(to_fragment);
        vec3 dir = to_fragment / max(distance, 1e-4);
        vec3 fog_colour = mix(u_sky_horizon, u_sky_zenith, pow(clamp(dir.y, 0.0, 1.0), 0.45));
        float fog = smoothstep(u_fog_start, u_fog_end, distance);
        rgb = mix(rgb, fog_colour, fog);
    }
    f_colour = vec4(rgb, c.a);
}
