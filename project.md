# My webgpu abstraction

## GPU Layer 
Bag of helpers to use for gpu level work without interacting with any of the higher level systems. 

## GPU Systems
A set of self contained independent modules that can be composed together for a copmlete systems
or can be used with custom abstractions, or direct access.

## Renderer
My own renderer abstraction. For throwing together fast concepts. Performant and ergonomic

```zig

const renderer = Renderer.init(...):

const cube = RenderObject.initCube();
const cam = Camera.initPerspective();

const frame = renderer.beginFrame();
const renderPass = frame.beginPass();
renderPass.setCamera(cam);
renderPass.draw(cube, transform);
renderPass.draw(cube, transform);
renderPass.draw(cube, transform);
frame.endPass(renderPass);
const shadowPass = frame.beginPass();
shadowPass.draw();
shadowPass.draw();
frame.endPass(shadowPass);
renderer.submitFrame(frame);


```
