#version 460 core
uniform sampler2D u_depth;
uniform mat4 u_projection;
uniform mat4 u_inv_projection;
uniform vec2 u_texel;      // size of one AO pixel in uv units
uniform float u_radius;    // in view-space units (blocks)
uniform float u_bias;
uniform float u_power;     // contrast curve
uniform float u_near;
uniform float u_far;
in vec2 v_uv;
out vec4 f_colour;

const int SAMPLES = 12;

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Depth buffer to view-space position. The projection is the engine's own, so
// this stays correct if the near plane ever moves.
vec3 viewPosition(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 view = u_inv_projection * clip;
    return view.xyz / view.w;
}

void main() {
    float depth = texture(u_depth, v_uv).r;
    if (depth >= 1.0) {              // sky: nothing to occlude
        f_colour = vec4(1.0);
        return;
    }
    vec3 position = viewPosition(v_uv, depth);

    // Normal from the depth gradients. Cheap and stable on the flat faces this
    // world is made of.
    vec3 right = viewPosition(v_uv + vec2(u_texel.x, 0.0), texture(u_depth, v_uv + vec2(u_texel.x, 0.0)).r);
    vec3 up = viewPosition(v_uv + vec2(0.0, u_texel.y), texture(u_depth, v_uv + vec2(0.0, u_texel.y)).r);
    // View space looks down -Z, so cross(up, right) points away from the eye.
    // Negating makes the hemisphere face the camera, which is the difference
    // between contact shadow and an evenly grey frame.
    vec3 normal = normalize(cross(right - position, up - position));

    // A per-pixel rotation, hashed from the fragment coordinate, turns twelve
    // samples into a much denser-looking pattern than twelve fixed directions.
    float angle = hash12(gl_FragCoord.xy) * 6.2831853;
    float ca = cos(angle), sa = sin(angle);
    mat2 rot = mat2(ca, -sa, sa, ca);

    float occlusion = 0.0;
    for (int i = 0; i < SAMPLES; ++i) {
        // A spiral on the sphere: cheap, evenly spread, no kernel buffer.
        float fi = float(i) + 0.5;
        float phi = fi * 2.39996323;          // golden angle
        float z = 1.0 - fi / float(SAMPLES);  // hemisphere, biased to the normal
        float r = sqrt(max(0.0, 1.0 - z * z));
        vec3 dir = vec3(cos(phi) * r, sin(phi) * r, z);
        dir.xy = rot * dir.xy;
        // Build the tangent frame around the normal.
        vec3 tangent = normalize(abs(normal.z) < 0.9 ? cross(normal, vec3(0, 0, 1)) : cross(normal, vec3(1, 0, 0)));
        vec3 bitangent = cross(normal, tangent);
        vec3 sample_pos = position + (tangent * dir.x + bitangent * dir.y + normal * dir.z) * u_radius;

        vec4 offset = u_projection * vec4(sample_pos, 1.0);
        vec2 sample_uv = offset.xy / offset.w * 0.5 + 0.5;
        if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) continue;

        float scene_depth = texture(u_depth, sample_uv).r;
        vec3 scene_pos = viewPosition(sample_uv, scene_depth);
        // Occluded when the scene is closer to the eye than the sample, by more
        // than the bias, and only within this sample's own reach.
        float range = smoothstep(0.0, 1.0, u_radius / max(abs(position.z - scene_pos.z), 1e-4));
        occlusion += (scene_pos.z > sample_pos.z + u_bias) ? range : 0.0;
    }
    float ao = 1.0 - occlusion / float(SAMPLES);
    f_colour = vec4(vec3(pow(clamp(ao, 0.0, 1.0), u_power)), 1.0);
}
