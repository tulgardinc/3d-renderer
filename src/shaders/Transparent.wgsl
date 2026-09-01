struct VertexInput {
    @location(0) position: vec3<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) col: vec4<f32>,
};

struct World {
    vp_matrix: mat4x4<f32>,
};

struct Instance {
    model: mat4x4<f32>,
    color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> world: World;
@group(0) @binding(1) var<storage, read> instances: array<Instance>;

@vertex
fn vs(in: VertexInput, @builtin(instance_index) ii: u32) -> VertexOutput {
    var out: VertexOutput;
    out.position = world.vp_matrix * instances[ii].model * vec4<f32>(in.position, 1.0);
    out.col = instances[ii].color;
    return out;
}

@fragment
fn fs(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.col;
}
