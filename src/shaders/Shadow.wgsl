struct VertexInput {
    @location(0) position: vec3<f32>,
};

@group(0) @binding(0) var<uniform> light_vp: mat4x4<f32>;
@group(0) @binding(1) var<storage, read> instances: array<Instance>;

struct Instance {
    model: mat4x4<f32>,
    tint: vec4<f32>,
};

@vertex
fn vs(in: VertexInput, @builtin(instance_index) ii: u32) -> @builtin(position) vec4<f32> {
    return light_vp * instances[ii].model * vec4<f32>(in.position.xyz, 1);
}

