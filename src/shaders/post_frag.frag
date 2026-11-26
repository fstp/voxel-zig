#version 460 core
uniform sampler2D u_hdr;
uniform sampler2D u_ao;      // blurred SSAO, unit 1 (4.9)
uniform float u_ao_strength;
uniform float u_ao_enabled;
uniform float u_exposure;
uniform float u_tonemap; // 0 = clip only, 1 = ACES (F11 A/B)
uniform vec2 u_texel;    // one pixel in uv
uniform float u_fxaa;    // 0 off, 1 on (F13)
in vec2 v_uv;
out vec4 f_colour;

// ACES fitted (Narkowicz). A filmic curve with a shoulder: values above 1
// roll off toward white instead of clipping to flat colour, which is what
// made the old pipeline read as "too bright" wherever the sun landed.
vec3 aces(vec3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// The full resolve for one uv: AO, exposure, curve. FXAA needs the final
// colour at neighbouring pixels, so it has to be a function.
vec3 scene(vec2 uv) {
    vec3 hdr = texture(u_hdr, uv).rgb;
    if (u_ao_enabled > 0.5) {
        float ao = texture(u_ao, uv).r;
        hdr *= mix(1.0, ao, u_ao_strength);
    }
    hdr *= u_exposure;
    return mix(clamp(hdr, 0.0, 1.0), aces(hdr), u_tonemap);
}

vec3 toSrgb(vec3 c) { return pow(clamp(c, 0.0, 1.0), vec3(1.0 / 2.2)); }
float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// FXAA, edge-direction variant. Cheaper and blunter than SMAA or MSAA, and it
// is the only one that costs nothing in the pipeline: no multisample target, no
// history buffer, one extra pass over the pixels the resolve already touched.
vec3 fxaa() {
    // Work in perceptual space: FXAA's thresholds mean nothing in linear light.
    vec3 m = toSrgb(scene(v_uv));
    vec3 nw = toSrgb(scene(v_uv + vec2(-1.0, -1.0) * u_texel));
    vec3 ne = toSrgb(scene(v_uv + vec2( 1.0, -1.0) * u_texel));
    vec3 sw = toSrgb(scene(v_uv + vec2(-1.0,  1.0) * u_texel));
    vec3 se = toSrgb(scene(v_uv + vec2( 1.0,  1.0) * u_texel));

    float lNW = luma(nw), lNE = luma(ne), lSW = luma(sw), lSE = luma(se), lM = luma(m);
    float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
    // Flat area: nothing to do, which is most of the screen.
    if (lMax - lMin < max(0.0312, lMax * 0.125)) return m;

    vec2 dir = vec2(-((lNW + lNE) - (lSW + lSE)), ((lNW + lSW) - (lNE + lSE)));
    float reduce = max((lNW + lNE + lSW + lSE) * 0.03125, 0.0078125);
    dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), vec2(-8.0), vec2(8.0));
    vec3 a = toSrgb(scene(v_uv + dir * u_texel * (1.0 / 8.0)));
    vec3 b = toSrgb(scene(v_uv + dir * u_texel * (2.0 / 8.0)));
    vec3 blended = (a + b) * 0.5;
    return pow(mix(m, blended, 0.75), vec3(2.2));   // back to linear for the write
}

void main() {
    if (u_fxaa > 0.5) {
        f_colour = vec4(fxaa(), 1.0);
        return;
    }
    vec3 hdr = texture(u_hdr, v_uv).rgb;
    // 4.9: ambient occlusion, applied in linear light before exposure. It
    // multiplies everything rather than just the ambient term, which is the
    // standard screen-space approximation and the reason the strength is a
    // knob rather than 1.0.
    if (u_ao_enabled > 0.5) {
        float ao = texture(u_ao, v_uv).r;
        hdr *= mix(1.0, ao, u_ao_strength);
    }
    hdr *= u_exposure;
    vec3 mapped = mix(clamp(hdr, 0.0, 1.0), aces(hdr), u_tonemap);
    // Linear out: the default framebuffer has GL_FRAMEBUFFER_SRGB, so the
    // hardware applies the transfer function (ADR 0008).
    f_colour = vec4(mapped, 1.0);
}
