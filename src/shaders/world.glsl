@header package main
@header import sg "../sokol/gfx"
@ctype mat4 Mat4
@ctype vec3 Vec3
@ctype vec4 Vec4

@block lighting_uniforms
    vec4 eye_pos;     // xyz: camera position
    vec4 sun_dir;     // xyz: direction the light travels (sun or moon)
    vec4 sun_color;   // rgb * intensity
    vec4 ambient_up;  // hemisphere sky
    vec4 ambient_dn;  // hemisphere ground
    vec4 fog_color;   // rgb, w = density
    vec4 flash_pos;   // xyz, w = on (0/1)
    vec4 flash_dir;   // xyz, w = cos outer cone
    vec4 flash_color; // rgb * intensity, w = cos inner cone
@end

@block lighting_fns
vec3 shade_lighting(vec3 base, vec3 n, vec3 wpos, float spec_amt,
                    vec4 eye_pos, vec4 sun_dir, vec4 sun_color,
                    vec4 ambient_up, vec4 ambient_dn,
                    vec4 flash_pos, vec4 flash_dir, vec4 flash_color) {
    vec3 l = normalize(-sun_dir.xyz);
    float ndl = max(dot(n, l), 0.0);
    vec3 amb = mix(ambient_dn.rgb, ambient_up.rgb, n.y * 0.5 + 0.5);
    vec3 v = normalize(eye_pos.xyz - wpos);
    vec3 col = base * (amb + sun_color.rgb * ndl);
    if (spec_amt > 0.0) {
        vec3 hv = normalize(l + v);
        float spec = pow(max(dot(n, hv), 0.0), 48.0) * spec_amt;
        col += sun_color.rgb * spec * min(ndl * 4.0, 1.0);
    }
    if (flash_pos.w > 0.5) {
        vec3 fl = flash_pos.xyz - wpos;
        float fd = max(length(fl), 0.001);
        vec3 fldir = fl / fd;
        float cosa = dot(-fldir, flash_dir.xyz);
        float cone = smoothstep(flash_dir.w, flash_color.w, cosa);
        float att = 1.0 / (1.0 + 0.06 * fd + 0.015 * fd * fd);
        float fndl = max(dot(n, fldir), 0.0);
        col += base * flash_color.rgb * (cone * att * fndl * 7.0);
    }
    return col;
}

vec3 apply_fog(vec3 col, vec3 wpos, vec4 eye_pos, vec4 fog_color) {
    float dist = length(eye_pos.xyz - wpos);
    float fog = 1.0 - exp(-pow(max(dist * fog_color.w, 0.0), 1.4));
    return mix(col, fog_color.rgb, clamp(fog, 0.0, 1.0));
}
@end

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
    @include_block lighting_uniforms
};

@include_block lighting_fns

in vec3 v_normal;
in vec3 v_wpos;
in vec4 v_color;
out vec4 frag_color;

void main() {
    vec3 n = normalize(v_normal);
    vec3 col = shade_lighting(v_color.rgb, n, v_wpos, 0.4,
        eye_pos, sun_dir, sun_color, ambient_up, ambient_dn,
        flash_pos, flash_dir, flash_color);
    col = apply_fog(col, v_wpos, eye_pos, fog_color);
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
    @include_block lighting_uniforms
};

@include_block lighting_fns

in vec3 vx_normal;
in vec3 vx_wpos;
in vec4 vx_color;
out vec4 frag_color;

void main() {
    vec3 n = normalize(vx_normal);
    vec3 col = shade_lighting(vx_color.rgb, n, vx_wpos, 0.0,
        eye_pos, sun_dir, sun_color, ambient_up, ambient_dn,
        flash_pos, flash_dir, flash_color);
    col = apply_fog(col, vx_wpos, eye_pos, fog_color);
    col = pow(max(col, vec3(0.0)), vec3(1.0 / 2.2));
    frag_color = vec4(col, 1.0);
}
@end

@program voxel vox_vs vox_fs
