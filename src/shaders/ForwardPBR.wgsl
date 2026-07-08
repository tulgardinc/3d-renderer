// Forward render shader with three bind groups of differing sizes:
//   group 0 = 1 entry, group 1 = 3 entries, group 2 = 1 entry.
// Exercises the emitter's group-transition logic (the "last group never
// opens its brace" suspicion), plus textures, samplers, mat4x4, and a
// storage buffer with a runtime-sized array.

struct Camera {
    view_proj: mat4x4<f32>,
    camera_pos: vec3<f32>,
};

struct Material {
    base_color: vec4<f32>,
    metallic: f32,
    roughness: f32,
};

struct Light {
    position: vec3<f32>,
    color: vec3<f32>,
};

struct LightBuffer {
    count: u32,
    lights: array<Light>,
};

@group(0) @binding(0) var<uniform> camera: Camera;

@group(1) @binding(0) var<uniform> material: Material;
@group(1) @binding(1) var albedo_tex: texture_2d<f32>;
@group(1) @binding(2) var albedo_sampler: sampler;

@group(2) @binding(0) var<storage, read> lights: LightBuffer;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

@vertex
fn vs(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_pos = camera.view_proj * vec4<f32>(in.position, 1.0);
    out.world_pos = in.position;
    out.normal = in.normal;
    out.uv = in.uv;
    return out;
}

@fragment
fn fs(in: VertexOutput) -> @location(0) vec4<f32> {
    let albedo = textureSample(albedo_tex, albedo_sampler, in.uv) * material.base_color;
    var lighting = vec3<f32>(0.0);
    for (var i = 0u; i < lights.count; i++) {
        let l = normalize(lights.lights[i].position - in.world_pos);
        let diff = max(dot(in.normal, l), 0.0);
        lighting += diff * lights.lights[i].color;
    }
    return vec4<f32>(albedo.rgb * lighting, albedo.a);
}
