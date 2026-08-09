// std430 layout torture test for the reflection tool's vec3 padding helpers.
// Not a real shader -- it exists so codegen output can be checked against
// hand-computed std430 offsets. Each field probes a distinct vec3 rule.
//
// Expected std430 layout of Vec3Layout (align 16):
//   a  vec3  @0      (occupies [0,12))
//   b  f32   @12     scalar packs into the vec3's 4-byte tail -- NO pad
//   c  vec3  @16     realigned to 16 after the scalar
//   d  vec3  @32     a following vec3 forces a c->d pad (28 -> 32)
//   e  vec3  @48     and again (44 -> 48)
//   -- struct size rounds 60 -> 64: a TRAILING pad
// So: @sizeOf == 64, offsets {a:0, b:12, c:16, d:32, e:48}, array stride 64.
struct Vec3Layout {
    a: vec3<f32>,
    b: f32,
    c: vec3<f32>,
    d: vec3<f32>,
    e: vec3<f32>,
};

@group(0) @binding(0) var<storage, read> data: array<Vec3Layout>;
@group(0) @binding(1) var<storage, read_write> sink: array<f32>;

@compute @workgroup_size(1)
fn probe(@builtin(global_invocation_id) gid: vec3<u32>) {
    let v = data[gid.x].a + data[gid.x].c + data[gid.x].d + data[gid.x].e;
    sink[gid.x] = v.x + v.y + v.z + data[gid.x].b;
}
