// std430 layout torture test for the runtime-sized-array helpers:
// the wrapping header struct's *_OFFSET / *_STRIDE constants, plus the
// header's trailing pad up to where the array actually starts.
//
// Element Item (align 16):
//   a vec3 @0 ; b vec3 @16 (pad 12->16) ; c f32 @28 (packs into b's tail)
//   -> @sizeOf 32, so array stride == 32
//
// Header ItemBuffer:
//   count  u32  @0
//   origin vec3 @16 (pad 4->16)          -- header field vec3 padding
//   items: array<Item> starts at roundUp(28,16) = 32
//   -> header @sizeOf must be 32 == ITEMS_OFFSET, ITEMS_STRIDE == 32
//   (ParticleSim's header was just `count`, landing on 16 for free; here the
//    header ends at 28 and must be padded up to 32.)
struct Item {
    a: vec3<f32>,
    b: vec3<f32>,
    c: f32,
};

struct ItemBuffer {
    count: u32,
    origin: vec3<f32>,
    items: array<Item>,
};

@group(0) @binding(0) var<storage, read_write> buf: ItemBuffer;

@compute @workgroup_size(1)
fn probe(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    if i >= buf.count { return; }
    buf.items[i].a = buf.origin + buf.items[i].b * buf.items[i].c;
}
