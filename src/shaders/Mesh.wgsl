struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@group(0) @binding(0) var<uniform> view_matrix: mat4x4<f32>;
@group(0) @binding(1) var texture: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;

@vertex
fn vs(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.position = view_matrix * vec4<f32>(in.position, 1.0);
    out.uv = in.uv;
    return out;
}

@fragment
fn fs(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(texture, smp, in.uv);
}
