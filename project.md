# My webgpu abstraction

## GPU Layer 
Bag of helpers to use for gpu level work without interacting with any of the higher level systems. 

## GPU Systems
A set of self contained independent modules that can be composed together for a copmlete systems
or can be used with custom abstractions, or direct access.

- dynamic and static shader creation
- dynamic shaders will get a validation layer via tint

## Renderer
My own renderer abstraction. For throwing together fast concepts. Performant and ergonomic

```zig

const renderer = Renderer.init(...);

const shader_handle
const material = RenderObject.initMaterial();

const cube = RenderObject.initCube(.{ color: "red" });
const cam = Camera.initPerspective();

const frame = renderer.beginFrame();
const render_pass = frame.beginPass();
render_pass.setCamera(cam);
render_pass.draw(cube, transform);
render_pass.draw(cube, transform);
render_pass.draw(cube, transform);
frame.endPass(render_pass);
const shadow_pass = frame.beginPass();
shadow_pass.draw();
shadow_pass.draw();
frame.endPass(shadow_pass);
renderer.submitFrame(frame);


```
