struct Camera {
    view_proj: mat4x4<f32>,
    eye: vec3<f32>,
    light_dir: vec3<f32>,
};

struct Instance {
    model: mat4x4<f32>,
    normal: mat4x4<f32>,
    color: vec4<f32>,
    uv_scale: vec2<f32>,
};

@group(0) @binding(0) var<uniform> camera: Camera;
@group(0) @binding(1) var smp: sampler;
@group(0) @binding(2) var tex: texture_2d<f32>;

@group(1) @binding(0) var<storage, read> instances: array<Instance>;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) world_normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
};

@vertex
fn vs(in: VertexInput, @builtin(instance_index) ii: u32) -> VertexOutput {
    let inst = instances[ii];

    let world = inst.model * vec4<f32>(in.position, 1.0);

    var out: VertexOutput;
    out.clip_pos = camera.view_proj * world;
    out.world_pos = world.xyz;
    out.world_normal = (inst.normal * vec4<f32>(in.normal, 0.0)).xyz;
    out.uv = in.uv * inst.uv_scale;
    out.color = inst.color;
    return out;
}

@fragment
fn fs(in: VertexOutput) -> @location(0) vec4<f32> {
    let n = normalize(in.world_normal);
    let l = normalize(camera.light_dir);
    let v = normalize(camera.eye - in.world_pos);
    let h = normalize(l + v);

    let albedo = textureSample(tex, smp, in.uv).rgb * in.color.rgb;

    let ndotl = dot(n, l);
    let diffuse = max(ndotl, 0.0);
    let specular = select(0.0, pow(max(dot(n, h), 0.0), 48.0), ndotl > 0.0);

    let sky = vec3<f32>(0.24, 0.28, 0.36);
    let ground = vec3<f32>(0.10, 0.09, 0.08);
    let ambient = mix(ground, sky, n.y * 0.5 + 0.5);

    let lit = albedo * (ambient + vec3<f32>(diffuse * 0.95)) + vec3<f32>(specular * 0.35);
    return vec4<f32>(lit, in.color.a);
}
