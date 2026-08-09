// Storage-buffer instancing client.
//
// Per-instance data lives in a read-only storage array indexed by
// @builtin(instance_index) -- NOT in a per-instance vertex buffer. The vertex
// stage carries only the shared quad geometry (group-0 texture unchanged from
// 2DTextured); everything that varies per instance is pulled from group 1.
//
// The payload is deliberately "structured": a full model transform plus a tint.
// That is the case vertex-attribute instancing handles badly -- a mat4x4 would
// be four separate @location slots -- so it is the honest justification for the
// storage path. The mat4x4 also doubles as the 3D model matrix later; here it
// just transforms the quad in the z=0 plane.

struct VertexInput {
    @location(0) vpos: vec2<f32>,
    @location(1) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) tint: vec4<f32>,
};

// One entry per instance. Reflection should generate the matching Zig extern
// struct (model: mat4x4 -> 64 bytes @0, tint: vec4 -> 16 bytes @64, size 80,
// no padding) so the app uploads a []Instance instead of hand-packed bytes.
struct Instance {
    model: mat4x4<f32>,
    tint: vec4<f32>,
};

@group(0) @binding(0) var smp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;

// The new surface: a typed storage binding. Instancing count comes from the
// draw call (instance_count), not from a vertex-buffer step mode.
@group(1) @binding(0) var<storage, read> instances: array<Instance>;

@vertex
fn vs(in: VertexInput, @builtin(instance_index) ii: u32) -> VertexOutput {
    let inst = instances[ii];

    var out: VertexOutput;
    out.position = inst.model * vec4<f32>(in.vpos, 0.0, 1.0);
    out.uv = in.uv;
    out.tint = inst.tint;
    return out;
}

@fragment
fn fs(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(tex, smp, in.uv) * in.tint;
}
