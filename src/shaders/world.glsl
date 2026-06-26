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

// ---- PBR functions (used by vox_fs only) ------------------------------------

@block pbr_fns
const float PBR_PI = 3.14159265359;

// GGX normal distribution
float D_GGX(float ndh, float alpha) {
    float a2 = alpha * alpha;
    float d = ndh * ndh * (a2 - 1.0) + 1.0;
    return a2 / (PBR_PI * d * d + 1e-7);
}

// Smith visibility (height-correlated)
float V_Smith(float ndv, float ndl, float alpha) {
    float k = alpha * 0.5;
    float gv = ndv / (ndv * (1.0 - k) + k + 1e-7);
    float gl = ndl / (ndl * (1.0 - k) + k + 1e-7);
    return gv * gl;
}

// Schlick Fresnel
vec3 F_Schlick(float vdh, vec3 f0) {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - vdh, 0.0, 1.0), 5.0);
}

// Triplanar blend weights — sharp blend biased toward dominant axis
vec3 triplanar_weights(vec3 n) {
    vec3 w = max(abs(n) - 0.2, 0.0);
    w = w * w * w;
    return w / max(w.x + w.y + w.z, 1e-7);
}

// Cook-Torrance PBR: sun + hemisphere ambient + flashlight
vec3 pbr_shade(vec3 albedo, float roughness, float metallic, float ao,
               vec3 n, vec3 wpos,
               vec4 eye_pos, vec4 sun_dir, vec4 sun_color,
               vec4 ambient_up, vec4 ambient_dn,
               vec4 flash_pos, vec4 flash_dir, vec4 flash_color) {
    vec3 v   = normalize(eye_pos.xyz - wpos);
    vec3 l   = normalize(-sun_dir.xyz);
    vec3 h   = normalize(v + l);
    float ndl = max(dot(n, l), 0.0);
    float ndv = max(dot(n, v), 0.001);
    float ndh = max(dot(n, h), 0.0);
    float vdh = max(dot(v, h), 0.0);
    float alpha = roughness * roughness;
    vec3 f0 = mix(vec3(0.04), albedo, metallic);

    // Direct sun: Cook-Torrance specular + Lambertian diffuse
    vec3 F    = F_Schlick(vdh, f0);
    vec3 spec = D_GGX(ndh, alpha) * V_Smith(ndv, ndl, alpha) * F;
    vec3 kd   = (1.0 - F) * (1.0 - metallic);
    vec3 col  = (kd * albedo / PBR_PI + spec) * sun_color.rgb * ndl;

    // Hemisphere ambient
    vec3 amb = mix(ambient_dn.rgb, ambient_up.rgb, n.y * 0.5 + 0.5);
    col += (1.0 - f0) * (1.0 - metallic) * albedo * amb * ao;

    // Flashlight (PBR-aware)
    if (flash_pos.w > 0.5) {
        vec3 fl   = flash_pos.xyz - wpos;
        float fd  = max(length(fl), 0.001);
        vec3 fld  = fl / fd;
        float att = 1.0 / (1.0 + 0.06 * fd + 0.015 * fd * fd);
        float cone = smoothstep(flash_dir.w, flash_color.w, dot(-fld, flash_dir.xyz));
        float fndl = max(dot(n, fld), 0.0);
        vec3 fh   = normalize(v + fld);
        float fndh = max(dot(n, fh), 0.0);
        float fvdh = max(dot(v, fh), 0.0);
        vec3 fF   = F_Schlick(fvdh, f0);
        vec3 fspec = D_GGX(fndh, alpha) * V_Smith(ndv, fndl, alpha) * fF;
        vec3 fkd  = (1.0 - fF) * (1.0 - metallic);
        col += (fkd * albedo / PBR_PI + fspec) * flash_color.rgb * (cone * att * fndl * 7.0);
    }
    return col;
}
@end

// ---- Instance renderer (players, weapons, projectiles) — Blinn-Phong --------

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

// ---- Voxel terrain/structures: triplanar PBR --------------------------------
//
// Vertex color alpha carries the material index packed as u8 / 255.0.
// Six texture2DArray samplers (one layer per Material enum value) provide
// albedo, normal, roughness, metallic, ao, and height maps.
// Height drives a simple world-space parallax offset before all other samples.
//
// Normal map reprojection per axis (UV → world):
//   X projection (zy plane): T=+Z, B=+Y, N=±X  →  world = (b·sn.x, g,  r)
//   Y projection (xz plane): T=+X, B=+Z, N=±Y  →  world = (r,  b·sn.y, g)
//   Z projection (xy plane): T=+X, B=+Y, N=±Z  →  world = (r,  g,  b·sn.z)

@vs vox_vs
layout(binding=0) uniform vox_vs_params {
    mat4 vp;
};

in vec3 a_pos;
in vec4 a_norm;   // BYTE4N  — xyz normal, w unused
in vec4 a_color;  // UBYTE4N — rgb tint (unused with textures), a = mat_id / 255

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

layout(binding=0) uniform texture2DArray t_albedo;
layout(binding=1) uniform texture2DArray t_normal;
layout(binding=2) uniform texture2DArray t_orm;   // R=ao  G=roughness  B=metallic
layout(binding=0) uniform sampler smp;

@include_block lighting_fns
@include_block pbr_fns

in vec3 vx_normal;
in vec3 vx_wpos;
in vec4 vx_color;
out vec4 frag_color;

const float VOX_S = 0.5; // texture scale: 1 tile per 2 m

// Triplanar albedo (sRGB → linear).
vec3 vox_albedo(float mat, vec3 bw) {
    return pow(max(texture(sampler2DArray(t_albedo, smp), vec3(vx_wpos.zy * VOX_S, mat)).rgb, vec3(0.0)), vec3(2.2)) * bw.x
         + pow(max(texture(sampler2DArray(t_albedo, smp), vec3(vx_wpos.xz * VOX_S, mat)).rgb, vec3(0.0)), vec3(2.2)) * bw.y
         + pow(max(texture(sampler2DArray(t_albedo, smp), vec3(vx_wpos.xy * VOX_S, mat)).rgb, vec3(0.0)), vec3(2.2)) * bw.z;
}

// Triplanar normal map reprojected to world space.
vec3 vox_normal_ws(float mat, vec3 sn, vec3 bw) {
    vec3 nmx = texture(sampler2DArray(t_normal, smp), vec3(vx_wpos.zy * VOX_S, mat)).rgb * 2.0 - 1.0;
    vec3 nmy = texture(sampler2DArray(t_normal, smp), vec3(vx_wpos.xz * VOX_S, mat)).rgb * 2.0 - 1.0;
    vec3 nmz = texture(sampler2DArray(t_normal, smp), vec3(vx_wpos.xy * VOX_S, mat)).rgb * 2.0 - 1.0;
    vec3 nx_ws = vec3(nmx.z * sn.x, nmx.y,        nmx.x        );
    vec3 ny_ws = vec3(nmy.x,        nmy.z * sn.y,  nmy.y        );
    vec3 nz_ws = vec3(nmz.x,        nmz.y,         nmz.z * sn.z );
    return normalize(nx_ws * bw.x + ny_ws * bw.y + nz_ws * bw.z);
}

// Dominant-axis ORM sample (seams unnoticeable for scalar maps).
vec3 vox_orm(float mat, vec3 bw) {
    vec2 suv = bw.x >= bw.y && bw.x >= bw.z ? vx_wpos.zy
             : bw.y >= bw.z                  ? vx_wpos.xz
             :                                 vx_wpos.xy;
    return texture(sampler2DArray(t_orm, smp), vec3(suv * VOX_S, mat)).rgb;
}

void main() {
    vec3  geom_n  = normalize(vx_normal);
    float mat_a   = floor(vx_color.a * 255.0 + 0.5); // primary material
    float mat_b   = floor(vx_color.r * 255.0 + 0.5); // secondary material (for blending)
    float blend_w = vx_color.g;                       // 0 = no blend, encoded by terrain_vertex_color
    vec3  sn = vec3(
        geom_n.x >= 0.0 ? 1.0 : -1.0,
        geom_n.y >= 0.0 ? 1.0 : -1.0,
        geom_n.z >= 0.0 ? 1.0 : -1.0
    );
    vec3 bw = triplanar_weights(geom_n);

    vec3 alb = vox_albedo(mat_a, bw);
    vec3 n   = vox_normal_ws(mat_a, sn, bw);
    vec3 orm = vox_orm(mat_a, bw);

    // Material boundary blend — only fires for terrain vertices near a transition.
    if (blend_w > 0.004) {
        alb = mix(alb, vox_albedo(mat_b, bw),              blend_w);
        n   = normalize(mix(n, vox_normal_ws(mat_b, sn, bw), blend_w));
        orm = mix(orm, vox_orm(mat_b, bw),                  blend_w);
    }

    float ao        = orm.r;
    float roughness = orm.g;
    float metallic  = orm.b;

    vec3 col = pbr_shade(alb, roughness, metallic, ao, n, vx_wpos,
        eye_pos, sun_dir, sun_color, ambient_up, ambient_dn,
        flash_pos, flash_dir, flash_color);
    col = apply_fog(col, vx_wpos, eye_pos, fog_color);
    col = pow(max(col, vec3(0.0)), vec3(1.0 / 2.2));
    float dist = length(eye_pos.xyz - vx_wpos);
    float coc  = clamp(1.0 - dist / 0.45, 0.0, 0.75);
    frag_color = vec4(col, 1.0 - coc);
}
@end

@program voxel vox_vs vox_fs

// ---- Viewmodel: Blinn-Phong shading, encodes near-DOF CoC in alpha ----
// Rendered to an offscreen RT (sample_count=1) with near=0.01 projection.
// alpha: 1.0 = in-focus, <1.0 = blurred in the DOF composite.

@fs vm_fs
layout(binding=1) uniform vm_fs_params {
    @include_block lighting_uniforms
};

@include_block lighting_fns

in vec3 v_normal;
in vec3 v_wpos;
in vec4 v_color;
out vec4 frag_color;

void main() {
    vec3 n   = normalize(v_normal);
    vec3 col = shade_lighting(v_color.rgb, n, v_wpos, 0.4,
        eye_pos, sun_dir, sun_color, ambient_up, ambient_dn,
        flash_pos, flash_dir, flash_color);
    col = pow(max(col, vec3(0.0)), vec3(1.0 / 2.2));
    // Near DOF: focus plane at 0.45 m; anything closer picks up blur.
    float dist = length(eye_pos.xyz - v_wpos);
    float coc  = clamp(1.0 - dist / 0.45, 0.0, 0.75);
    frag_color = vec4(col, 1.0 - coc); // alpha=1 sharp, <1 blurred
}
@end

@program vm_world vs vm_fs

// ---- Near-DOF composite: blurs viewmodel offscreen RT by per-pixel CoC ----

@vs dof_vs
in vec2 a_pos; // NDC [-1,1]
in vec2 a_uv;
out vec2 v_uv;
void main() {
    gl_Position = vec4(a_pos, 0.0, 1.0);
    v_uv = a_uv;
}
@end

@fs dof_fs
layout(binding=0) uniform dof_fs_params {
    vec4 texel_size; // xy = 1/width, 1/height
};
layout(binding=0) uniform texture2D t_vm;
layout(binding=0) uniform sampler smp_vm;

in vec2 v_uv;
out vec4 frag_color;

void main() {
    vec4 center = texture(sampler2D(t_vm, smp_vm), v_uv);
    // World is now rendered into this RT too, so every pixel has content.
    // alpha=1 means sharp (far away), alpha<1 means blurred (near DOF).
    float coc = 1.0 - center.a;         // 0 = sharp, 0.75 = max blur
    if (coc < 0.015) {
        frag_color = vec4(center.rgb, 1.0);
        return;
    }
    float r = coc * 14.0;               // blur radius in pixels
    vec3  acc = center.rgb;
    float w   = 1.0;
    // 8-tap circular gather; skip background taps to avoid dark fringing
    vec2 ring[8];
    ring[0] = vec2( 1.000,  0.000);
    ring[1] = vec2( 0.707,  0.707);
    ring[2] = vec2( 0.000,  1.000);
    ring[3] = vec2(-0.707,  0.707);
    ring[4] = vec2(-1.000,  0.000);
    ring[5] = vec2(-0.707, -0.707);
    ring[6] = vec2( 0.000, -1.000);
    ring[7] = vec2( 0.707, -0.707);
    for (int i = 0; i < 8; i++) {
        vec4 s = texture(sampler2D(t_vm, smp_vm), v_uv + ring[i] * r * texel_size.xy);
        if (s.a > 0.005) { acc += s.rgb; w += 1.0; }
    }
    frag_color = vec4(acc / w, 1.0);
}
@end

@program vm_dof dof_vs dof_fs
