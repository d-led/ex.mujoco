# ExMujoco

MuJoCo physics from Elixir, through a NIF generated from MuJoCo's own headers.

```elixir
{:ok, model} = ExMujoco.load_xml("model/scene.xml")
data = ExMujoco.data(model)

for _ <- 1..1000, do: ExMujoco.step(data)

ExMujoco.Data.qpos(data) |> ExMujoco.Tensor.to_list()
ExMujoco.Model.geom_size(model) |> ExMujoco.Tensor.to_list()
```

No Python, no `pythonx`, no wheel: a C++ NIF built with [Fine](https://github.com/elixir-nx/fine),
linked against the MuJoCo library and compiled for the machine it runs on.

## Why

[Monty](https://github.com/thousandbrainsproject/tbp.monty) — the Thousand Brains Project's
sensorimotor framework — reaches MuJoCo through the Python bindings, and in this house that
means a `pythonx` interpreter inside the BEAM. That works, and it costs: JSON between the
layers, a thread that owns the GL context, and a second runtime to ship. The physics is a C
library. This package calls it.

The plan is phased — physics first, then scene building, then rendering — and
[`docs/plan.md`](docs/plan.md) says what each phase is for and what it is waiting on.

## Install

```elixir
def deps do
  [{:ex_mujoco, "~> 0.2.6"}]
end
```

Building it wants a C++17 compiler and `make` — the same thing Fine wants, and the toolchain
an Elixir install already has (Xcode command line tools on macOS, `build-essential` on Linux,
MSVC on Windows). MuJoCo itself is fetched for you: the official release artifact for the
platform, checked against the checksum published beside it, in about ten seconds.

```console
$ mix compile
ex_mujoco: Fetching MuJoCo 4.0.1 for darwin-universal
ex_mujoco: MuJoCo 4.0.1 is in _build/mujoco/4.0.1-darwin-arm64
```

Four ways to point it at a MuJoCo, in the order they are tried:

| how                     | command                                         | when                                                |
| ----------------------- | ----------------------------------------------- | --------------------------------------------------- |
| your own install        | `MUJOCO_DIR=/opt/mujoco mix compile`            | Conan, vcpkg, a build of your own, a system package |
| from source, at any ref | `EX_MUJOCO_SOURCE_REF=main mix compile`         | the latest MuJoCo, or a commit that fixes something |
| from a checkout         | `EX_MUJOCO_SOURCE_DIR=/path/to/mujoco mix compile` | you are working on MuJoCo                           |
| the pinned release      | `mix compile`                                   | everything else                                     |

A release pins one MuJoCo: `mujoco.version` names it, the official artifact's published
checksum is checked before it is unpacked, and the release workflow refuses to build a tag
against anything else. The three overrides above are the development paths — `main` included —
and `mix ex_mujoco.gen --check` tells you when they have moved past the committed bindings.

```elixir
iex> ExMujoco.mujoco_version()   # the pin, as MuJoCo spells it
"4.0.1"
iex> ExMujoco.version()          # what the linked library answers
4000001
iex> ExMujoco.header_version()   # what the bindings were generated from
4000001
```

All three agree, or the NIF does not load — two versions of one physics is not a difference of
behaviour, it is a difference of answer. What the build itself fetched (version, artifact name,
artifact checksum, platform, timestamp) is in `_build/mujoco/<version>-<platform>-<arch>/.provider`.

## What you get

`ExMujoco` is the curated surface — a model, its data, stepping, state:

|                                           |                                          |
| ----------------------------------------- | ---------------------------------------- |
| `ExMujoco.load_xml/1`, `load_string/1`    | compile MJCF, from a file or from memory |
| `ExMujoco.data/1`                         | an `mjData` for a model                  |
| `ExMujoco.forward/1`, `step/1`, `reset/1` | the three things you do to data          |
| `ExMujoco.state/1,2`, `put_state/3`       | save and restore the integration state   |
| `ExMujoco.contact_force/2`                | one contact's six numbers                |
| `ExMujoco.Renderer`                       | the scene as pictures, through a camera  |

Underneath, generated from the headers:

- **`ExMujoco.Model`** — every field of `mjModel`, one function each: `nq/1`, `geom_size/1`,
  `body_mass/1`, `jnt_axis/1` … A scalar answers a number; an array answers an
  `ExMujoco.Tensor` carrying the element type and the shape.
- **`ExMujoco.Data`** — the same for `mjData`: `qpos/1`, `qvel/1`, `xpos/1`, `efc_force/1` …
- **`ExMujoco.Api`** — MuJoCo's own functions, bound one for one, under MuJoCo's names:
  `mj_name2id/3`, `mj_step1/2`, `mj_kinematics/2` …
- **`ExMujoco.Types`** — every enum, as numbers, named as MuJoCo names them:
  `ExMujoco.Types.Geom.box()`, `ExMujoco.Types.Obj.body()`.

Reading a field copies it, so the value you hold does not change when the next step runs.

```elixir
iex> ExMujoco.Model.geom_size(model)
#ExMujoco.Tensor<{2, 3} :f64 6 values>

iex> ExMujoco.Api.mj_name2id(model, ExMujoco.Types.Obj.geom(), "floor")
0
```

## Pictures

`ExMujoco.Renderer` draws the scene offscreen through a camera in it, one binary per pass,
asked for together so the scene is updated once:

```elixir
iex> ExMujoco.Renderer.available?()
true

iex> renderer = ExMujoco.Renderer.new(model, 64, 64)
iex> ExMujoco.Renderer.read(renderer, data, "cam", [:rgb, :depth, :segmentation])
[<<...>>, <<...>>, <<...>>]
```

| pass            | shape                | holds                                  |
| --------------- | -------------------- | -------------------------------------- |
| `:rgb`          | `width * height * 3` | red, green, blue                       |
| `:depth`        | `width * height * 4` | float32 metres from the camera         |
| `:segmentation` | `width * height * 4` | int32 geom id, `-1` for the background |

Rendering needs an OpenGL context and the package makes one itself — **nothing is linked**:
CGL on macOS, EGL on Linux, both opened with `dlopen` when the first renderer is asked for. A
machine with no GL still loads this package and steps models; `available?/0` says which
machine it is on, and `unavailable_reason/0` says why not in words. Windows has no offscreen
context yet.

## What is not here yet

In [`docs/plan.md`](docs/plan.md), with the reason it is its own phase:

- **`mjSpec`** — building a model in memory (`mjs_addBody` and the rest). Compiling XML, from
  a path or from a string, covers everything that can be expressed in MJCF.
- **WGL** — offscreen rendering on Windows. The classic renderer needs a hidden window there,
  which is a platform binding this package has not written; macOS and Linux are carried.

`docs/coverage.md` lists every MuJoCo function this package does _not_ bind, and why. Nothing
is dropped in silence.

## Errors

MuJoCo reports a fatal error by not returning — inside a NIF that would abort the VM. The NIF
intercepts it (`c_src/mj_call.hpp`), and it arrives as `ExMujoco.Error` with MuJoCo's own
message:

```elixir
iex> ExMujoco.load_string("<mujoco></mujoco>")
{:error, %ExMujoco.Error{message: "mj_parseXMLString: ..."}}
```

## Where to find what

| link                                                                   | what it answers                                              |
| ---------------------------------------------------------------------- | ------------------------------------------------------------ |
| [`ExMujoco`](https://hexdocs.pm/ex_mujoco/ExMujoco.html)               | the curated surface, and the example above                   |
| [`ExMujoco.Model`](https://hexdocs.pm/ex_mujoco/ExMujoco.Model.html)   | one function per `mjModel` field, named as MuJoCo names them |
| [`ExMujoco.Data`](https://hexdocs.pm/ex_mujoco/ExMujoco.Data.html)     | the same for `mjData`                                        |
| [`ExMujoco.Api`](https://hexdocs.pm/ex_mujoco/ExMujoco.Api.html)       | MuJoCo's C functions, bound one for one                      |
| [`ExMujoco.Tensor`](https://hexdocs.pm/ex_mujoco/ExMujoco.Tensor.html) | what an array field answers, and how to read it              |
| [`docs/coverage.md`](https://hexdocs.pm/ex_mujoco/coverage.html)       | what is bound, what is not, and why                          |
| [`docs/plan.md`](https://hexdocs.pm/ex_mujoco/plan.html)               | what is not here yet, and when                               |
| [`docs/building.md`](https://hexdocs.pm/ex_mujoco/building.html)       | platforms, your own MuJoCo, where the shared library goes    |
| [`docs/development.md`](https://hexdocs.pm/ex_mujoco/development.html) | working on the package: bindings, tests, releasing           |

That table is the shape of the documentation, on purpose: **this page is for using the
package** — install, the pin, usage, and where each other question is answered — and everything
about building it, planning it or working on it is a guide beside it. The API reference is
grouped the same way, so `Physics` is the curated surface, `The C API` is MuJoCo's own
functions, `Types` is the enums (eighty-odd tiny modules, in one group rather than loose in the
list), and the generator's modules sit at the end under `Generating the bindings` where a caller
never has to scroll past them.

The field pages are filed the way MuJoCo's header is: `ExMujoco.Model.geom_pos/1` is under
`geoms`, `ExMujoco.Data.qpos/1` under `state`, and `ExMujoco.Data.xpos/1` under
`computed by mj_fwdPosition/mj_kinematics` — the heading MuJoCo writes above the block, so the
index is MuJoCo's index. `ExMujoco.Api` does the same, and each function there carries MuJoCo's
own sentence about what it does; each `ExMujoco.Types.*` value carries MuJoCo's sentence about
what it means.

## Licence

MPL-2.0 for this package. MuJoCo is Apache-2.0 and is linked, not modified; see `NOTICE`.
