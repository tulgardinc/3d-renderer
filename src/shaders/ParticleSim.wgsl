// Particle simulation compute shader.
// Stress test for the reflection tool:
//   - nested struct (Particle) with vec3 + vec4 padding quirks
//   - a bare runtime-sized array binding      (array<Particle>)
//   - a struct wrapping a runtime-sized array  (ParticleBuffer)
//   - a uniform block full of vec3 padding     (SimParams)
//   - a compute entry point

struct Particle {
    position: vec3<f32>,
    velocity: vec3<f32>,
    mass: f32,
    color: vec4<f32>,
};

struct SimParams {
    delta_time: f32,
    particle_count: u32,
    gravity: vec3<f32>,
    bounds_min: vec3<f32>,
    bounds_max: vec3<f32>,
};

struct ParticleBuffer {
    count: u32,
    particles: array<Particle>,   // runtime-sized array of structs
};

// bare runtime array as the whole binding
@group(0) @binding(0) var<storage, read> particles_in: array<Particle>;

// runtime array wrapped in a struct
@group(0) @binding(1) var<storage, read_write> particles_out: ParticleBuffer;

@group(0) @binding(2) var<uniform> params: SimParams;

@compute @workgroup_size(64)
fn simulate(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    if (i >= params.particle_count) {
        return;
    }

    var p = particles_in[i];
    p.velocity += params.gravity * params.delta_time;
    p.position += p.velocity * params.delta_time;

    particles_out.particles[i] = p;
    particles_out.count = params.particle_count;
}
