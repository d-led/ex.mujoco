# The plan

Where this package is going, and why it is going in this order. The short version: the
physics first, because that is what Monty needs and what a NIF is good at; the scene second,
because building a model at run time is a data-structure problem; rendering last, because a GL
context is a platform problem.

## v0.1 — physics (this release)

What is here:

* a model compiled from MJCF, from a path or from memory;
* a data block, stepping, `mj_forward`, and the integration state as a binary;
* every field of `mjModel` and `mjData`, one function each, generated from the headers;
* every MuJoCo enum, resolved from the headers;
* the C functions in `c_src/manifest.exs`, bound 1:1 (`ExMujoco.Api`), plus a dozen
  hand-written ones where a call needs a decision;
* MuJoCo's fatal error caught and re-raised, so a bad model cannot abort the VM.

What is deliberately not here: `mjSpec`, rendering. Both are below.

### What "later replaces the Python wrapper" needs

`ex.tbp.monty/priv/monty_py/world.py` imports `MjData, MjSpec, Renderer, mj_forward,
mjtGeom, mjtJoint, mjtLightType, mjtTexture, mjtTextureRole`. Three of those four are covered
here. The fourth — and the one that builds the scene — is `mjSpec`.

## v0.2 — `mjSpec`: a model you build, not only one you read

The object graph MuJoCo compiles from: `mjSpec`, `mjsBody`, `mjsGeom`, `mjsJoint`,
`mjsLight`, `mjsCamera`, `mjsSite`, `mjsTexture`, `mjsMesh`, plus `mj_compile`.

The shape of the work:

* `mjsBody* body = mjs_addBody(parent, spec)` returns a pointer into a tree owned by the spec,
  so the resource is the `mjSpec` and the Elixir side holds a *path* to an element, not a
  pointer — an element handle that outlives a re-parent is a use-after-free waiting to be
  written. The alternative, one resource per element, holds the spec alive per element and is
  easier to reason about; that is the decision to make first.
* The `mjsXxx` structs are plain C, so their fields generate the same way `mjModel`'s do.
* `mj_compile` returns an `mjModel` that the spec still owns; `mj_recompile` is the loop that
  matters for editing a scene between episodes.

Monty's world builder needs one more thing: **meshes from memory**. `mjs_addMesh` takes a name
and fills `vert`/`face`; MuJoCo also has `mj_addBufferVFS` for assets that are not files. That
is the piece that replaces `mesh_data` handling in the Python wrapper.

## v0.3 — rendering

`mjrContext`, `mjrRender`, `mjvScene`, `mjvCamera`, `mjvUpdateGeom`, and an offscreen frame to
`depth` / `rgb` / `segmentation`.

Why it is last: a GL context belongs to a thread and to a platform. Linux wants EGL or
OSMesa, macOS wants CGL, Windows wants WGL, and MuJoCo's own `Renderer` picks between them
with `mjr_resolveGLContext`. Two consequences:

* **one NIF per frame and a context pinned to one scheduler thread**, or a dirty-IO NIF with
  its own thread; the Python wrapper already had to solve this (`_on_one_thread`), and the
  reason it did is worth reading before writing the Elixir one;
* the context must be created and destroyed by the same thread, so the resource holds the
  thread, not just the context.

Until then, `depth` and `segmentation` come from Python, or from whatever else already renders.

## Beyond

* **`mj_step` on a worker.** A step is one call into MuJoCo, which is the point of the NIF — but
  on a big model it is milliseconds, and milliseconds inside a normal NIF block a scheduler.
  `step/1` is documented as such; a `step_async/1` backed by a dirty-IO NIF or a
  `Task`-per-episode pool is the next thing a caller will want.
* **`Nx`.** `ExMujoco.Tensor` is `{type, shape, binary}`, which is `Nx.from_binary/2` plus a
  shape. A dependency on Nx in a physics package would be a dependency on a numerical
  ecosystem the caller may not have, so the conversion is theirs to make and one line long.
* **Batched rollouts.** `mjbatch` exists in MuJoCo 4 and is a genuine match for a BEAM process
  per environment; it is not in v0.1 because it is a large API and wants `mjSpec` first.
* **A `MuJoCo` plugin surface.** `mj_loadPluginLibrary` and the decoder plugins
  (`libstl_decoder`, `libobj_decoder`) ship with the release; loading them from a path in
  `priv/` is a small addition once someone needs a format the built-in decoder does not read.
