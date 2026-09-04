struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) col: vec4<f32>,
    @location(2) normal: vec3<f32>,
    @location(3) pos_light: vec4<f32>,
};

struct World {
    vp_matrix: mat4x4<f32>,
    light_vp: mat4x4<f32>,
    light_pos: vec3<f32>,
    ambient: f32,
};

struct Instance {
    model: mat4x4<f32>,
    tint: vec4<f32>,
};

@group(0) @binding(0) var<uniform> world: World;
@group(0) @binding(1) var texture: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
@group(0) @binding(3) var<storage, read> instances: array<Instance>;
@group(0) @binding(4) var shadow_map: texture_depth_2d;
@group(0) @binding(5) var shadow_smp: sampler_comparison;

fn shadow_factor(pos_light: vec4<f32>) -> f32 {
    let p = pos_light.xyz / pos_light.w;
    let uv = p.xy * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5, 0.5);
    if p.z > 1.0 { return 1.0; }

    let texel = 1.0 / 2048;
    var sum = 0.0;
    for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
            let offset = vec2<f32>(f32(dx), f32(dy)) * texel;
            sum += textureSampleCompareLevel(shadow_map, shadow_smp, uv + offset, p.z - 0.0005);
        }
    }

    return sum / 9.0;
}

@vertex
fn vs(in: VertexInput, @builtin(instance_index) ii: u32) -> VertexOutput {
    var out: VertexOutput;
    out.position = world.vp_matrix * instances[ii].model * vec4<f32>(in.position, 1.0);
    out.uv = in.uv;
    out.col = instances[ii].tint;
    out.normal = (instances[ii].model * vec4<f32>(in.normal, 0.0)).xyz;
    out.pos_light = world.light_vp * instances[ii].model * vec4<f32>(in.position, 1.0);
    return out;
}

@fragment
fn fs(in: VertexOutput) -> @location(0) vec4<f32> {
    var lightness = world.ambient + max(dot(normalize(in.normal), normalize(world.light_pos)), 0) * shadow_factor(in.pos_light);
    return textureSample(texture, smp, in.uv) * in.col * lightness;
}
