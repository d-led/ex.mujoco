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
  [{:ex_mujoco, "~> 0.1"}]
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

Three ways to point it at a MuJoCo, in the order they are tried:

| how                     | command                                         | when                                                |
| ----------------------- | ----------------------------------------------- | --------------------------------------------------- |
| your own install        | `MUJOCO_DIR=/opt/mujoco mix compile`            | Conan, vcpkg, a build of your own, a system package |
| from source, at any ref | `EX_MUJOCO_SOURCE_REF=main mix compile`         | the latest MuJoCo, or a commit that fixes something |
| from a checkout         | `EX_MUJOCO_SOURCE_DIR=~/src/mujoco mix compile` | you are working on MuJoCo                           |
| the pinned release      | `mix compile`                                   | everything else                                     |

The source build runs CMake and takes a few minutes; the release fetch takes seconds.
[`docs/building.md`](docs/building.md) has the detail, including what happens to the shared
library afterwards and why.

Windows needs nothing set up: the library MuJoCo ships is loaded from `priv/` by a second,
small library, because Windows will not look beside a library for the libraries it imports.
The one prerequisite is MuJoCo's own — the Visual C++ runtime, which ships with Visual Studio.

## What you get

`ExMujoco` is the curated surface — a model, its data, stepping, state:

|                                           |                                          |
| ----------------------------------------- | ---------------------------------------- |
| `ExMujoco.load_xml/1`, `load_string/1`    | compile MJCF, from a file or from memory |
| `ExMujoco.data/1`                         | an `mjData` for a model                  |
| `ExMujoco.forward/1`, `step/1`, `reset/1` | the three things you do to data          |
| `ExMujoco.state/1,2`, `put_state/3`       | save and restore the integration state   |
| `ExMujoco.contact_force/2`                | one contact's six numbers                |

Underneath, generated from the headers:

- **`ExMujoco.Model`** — every field of `mjModel`, one function each: `nq/1`, `geom_size/1`,
  `body_mass/1`, `jnt_axis/1` … A scalar answers a number; an array answers an
  `ExMujoco.Tensor` carrying the element type and the shape.
- **`ExMujoco.Data`** — the same for `mjData`: `qpos/1`, `qvel/1`, `xpos/1`, `efc_force/1` …
- **`ExMujoco.Api`** — MuJoCo's own functions, bound one for one, under MuJoCo's names:
  `mj_name2id/3`, `mj_step1/2`, `mj_kinematics/2` …
- **`ExMujoco.Types`** — every enum, as numbers, with names that read like Monty's Python:
  `ExMujoco.Types.Geom.box()`, `ExMujoco.Types.Obj.body()`.

Reading a field copies it, so the value you hold does not change when the next step runs.

```elixir
iex> ExMujoco.Model.geom_size(model)
#ExMujoco.Tensor<{2, 3} :f64 6 values>

iex> ExMujoco.Api.mj_name2id(model, ExMujoco.Types.Obj.geom(), "floor")
0
```

## What is not here yet

Both are in [`docs/plan.md`](docs/plan.md) with the reason they are their own phase:

- **`mjSpec`** — building a model in memory (`mjs_addBody` and the rest). Compiling XML, from
  a path or from a string, covers everything that can be expressed in MJCF.
- **Rendering** — `mjrContext` and offscreen frames. A GL context is per platform (EGL,
  OSMesa, CGL, WGL) and belongs to a thread; that is a different job from stepping physics.

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

## How the bindings are made

MuJoCo generates its own Python bindings by reading its headers. This package does the same:
`mix ex_mujoco.gen` parses `MUJOCO_DIR/include/mujoco/*.h` — functions, struct members with the
extents from `mjxmacro.h`, and enums — and writes the C++ that Fine registers and the Elixir
that calls it. The output is committed, so a package build needs neither the generator nor a
network, and `mix ex_mujoco.gen --check` (which CI runs) fails when the two disagree.

`c_src/manifest.exs` is the one hand-edited decision: which C functions are bound 1:1, and
which are bound by hand because each call needs an answer no signature gives.

## Releasing

`VERSION` is the one place the version lives; `mix.exs` reads it. To publish:

```console
$ ./scripts/tag_and_push_version.sh --dry-run   # what it would do
$ ./scripts/tag_and_push_version.sh             # v0.1.0, pushed
```

It refuses to tag a commit whose CI is not green, and a commit CI never saw —
a docs-only push, since the workflow ignores markdown — is compared against the
last run that did succeed. The tag is what `.github/workflows/release.yml`
publishes from: it builds the package, publishes it to Hex and creates the
GitHub release.

## Licence

MPL-2.0 for this package. MuJoCo is Apache-2.0 and is linked, not modified; see `NOTICE`.
