struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) tint: vec4<f32>,
    @location(2) normal: vec3<f32>,
};

struct World {
    vp_matrix: mat4x4<f32>,
};

struct Instance {
    model: mat4x4<f32>,
    tint: vec4<f32>,
};

@group(0) @binding(0) var<uniform> world: World;

@group(1) @binding(0) var texture: texture_2d<f32>;
@group(1) @binding(1) var smp: sampler;

@group(2) @binding(0) var<storage, read> instances: array<Instance>;

const light_dir = vec3<f32>(0.5, 1.0, 0.3);
const ambient = 0.15;

@vertex
fn vs_main(in: VertexInput, @builtin(instance_index) ii: u32) -> VertexOutput {
    let instance = instances[ii];
    var out: VertexOutput;
    out.position = world.vp_matrix * instance.model * vec4<f32>(in.position, 1.0);
    out.uv = in.uv;
    out.tint = instance.tint;
    out.normal = (instance.model * vec4<f32>(in.normal, 0.0)).xyz;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let diffuse = max(dot(normalize(in.normal), normalize(light_dir)), 0.0);
    let color = textureSample(texture, smp, in.uv) * in.tint;
    return vec4<f32>(color.rgb * (ambient + diffuse), color.a);
}
