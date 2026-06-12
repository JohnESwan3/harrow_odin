@header package main
@header import sg "../sokol/gfx"
@ctype mat4 Mat4
@ctype vec3 Vec3
@ctype vec4 Vec4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 view_proj;
};

in vec3 a_pos;
in vec3 a_norm;
in vec4 i_col0;
in vec4 i_col1;
in vec4 i_col2;
in vec4 i_col3;
in vec4 i_color;

out vec3 v_normal;
out vec3 v_wpos;
out vec4 v_color;

void main() {
    mat4 model = mat4(i_col0, i_col1, i_col2, i_col3);
    vec4 wp = model * vec4(a_pos, 1.0);
    gl_Position = view_proj * wp;
    v_wpos = wp.xyz;
    v_normal = mat3(model) * a_norm;
    v_color = i_color;
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec4 eye_pos;    // xyz: camera position
    vec4 sun_dir;    // xyz: direction the light travels
    vec4 sun_color;  // rgb * intensity
    vec4 ambient_up; // hemisphere sky
    vec4 ambient_dn; // hemisphere ground
    vec4 fog_color;  // rgb, w = density
};

in vec3 v_normal;
in vec3 v_wpos;
in vec4 v_color;
out vec4 frag_color;

void main() {
    vec3 n = normalize(v_normal);
    vec3 l = normalize(-sun_dir.xyz);
    float ndl = max(dot(n, l), 0.0);
    vec3 amb = mix(ambient_dn.rgb, ambient_up.rgb, n.y * 0.5 + 0.5);
    vec3 v = normalize(eye_pos.xyz - v_wpos);
    vec3 h = normalize(l + v);
    float spec = pow(max(dot(n, h), 0.0), 48.0) * 0.4;
    vec3 col = v_color.rgb * (amb + sun_color.rgb * ndl) + sun_color.rgb * spec * min(ndl * 4.0, 1.0);
    float dist = length(eye_pos.xyz - v_wpos);
    float fog = 1.0 - exp(-pow(dist * fog_color.w, 1.4));
    col = mix(col, fog_color.rgb, clamp(fog, 0.0, 1.0));
    col = pow(max(col, vec3(0.0)), vec3(1.0 / 2.2));
    frag_color = vec4(col, v_color.a);
}
@end

@program world vs fs

// ---- voxel terrain: per-vertex color, shared lighting model -----------------

@vs vox_vs
layout(binding=0) uniform vox_vs_params {
    mat4 vp;
};

in vec3 a_pos;
in vec4 a_norm;  // BYTE4N
in vec4 a_color; // UBYTE4N

out vec3 vx_normal;
out vec3 vx_wpos;
out vec4 vx_color;

void main() {
    gl_Position = vp * vec4(a_pos, 1.0);
    vx_wpos = a_pos;
    vx_normal = a_norm.xyz;
    vx_color = a_color;
}
@end

@fs vox_fs
layout(binding=1) uniform vox_fs_params {
    vec4 eye_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 ambient_up;
    vec4 ambient_dn;
    vec4 fog_color;
};

in vec3 vx_normal;
in vec3 vx_wpos;
in vec4 vx_color;
out vec4 frag_color;

void main() {
    vec3 n = normalize(vx_normal);
    vec3 l = normalize(-sun_dir.xyz);
    float ndl = max(dot(n, l), 0.0);
    vec3 amb = mix(ambient_dn.rgb, ambient_up.rgb, n.y * 0.5 + 0.5);
    vec3 col = vx_color.rgb * (amb + sun_color.rgb * ndl);
    float dist = length(eye_pos.xyz - vx_wpos);
    float fog = 1.0 - exp(-pow(dist * fog_color.w, 1.4));
    col = mix(col, fog_color.rgb, clamp(fog, 0.0, 1.0));
    col = pow(max(col, vec3(0.0)), vec3(1.0 / 2.2));
    frag_color = vec4(col, 1.0);
}
@end

@program voxel vox_vs vox_fs
