# Working on the package

For people changing ExMujoco itself. Using it needs none of this — `README.md` and the API
reference cover that.

## The shape of the repository

|                                   |                                                                           |
| --------------------------------- | ------------------------------------------------------------------------- |
| `lib/ex_mujoco.ex`                | the curated API, hand-written                                             |
| `lib/ex_mujoco/`                  | `Model`, `Data`, `Api`, `Native` and `Types/*` — **generated**, committed |
| `c_src/ex_mujoco_nif.cpp`         | the hand-written half of the NIF: loading, state, contacts, rendering     |
| `c_src/renderer.cpp`, `.hpp`      | `mjv_*`/`mjr_*` in a resource: scene, options, context, three passes      |
| `c_src/gl.cpp`, `.hpp`            | the offscreen OpenGL context: CGL on macOS, EGL on Linux, `dlopen` only   |
| `lib/ex_mujoco/renderer.ex`       | `ExMujoco.Renderer`, hand-written                                         |
| `c_src/manifest.exs`              | which C functions are bound 1:1, and which are bound by hand              |
| `c_src/generated/`                | `fields.inc` and `functions.inc` — **generated**, committed               |
| `scripts/prepare_mujoco.exs`      | fills one MuJoCo directory, from a release, source, or yours              |
| `scripts/tag_and_push_version.sh` | tags the version and lets the release workflow publish                    |

## How the bindings are made

MuJoCo generates its own Python bindings by reading its headers. This package does the same:
`mix ex_mujoco.gen` parses `MUJOCO_DIR/include/mujoco/*.h` — functions, struct members with the
extents from `mjxmacro.h`, and enums — and writes the C++ that Fine registers and the Elixir
that calls it. The output is committed, so a package build needs neither the generator nor a
network, and `mix ex_mujoco.gen --check` (which CI runs) fails when the two disagree.

`c_src/manifest.exs` is the one hand-edited decision: which C functions are bound 1:1, and
which are bound by hand because each call needs an answer no signature gives. Each hand-written
entry also names the C function it translates (`c:`), because `docs/coverage.md` needs it: a
hand-bound function is covered, and must not be offered there as something still to bind. The
generator raises when that name is not one MuJoCo declares.

`docs/coverage.md` is generated from the same reading, and answers _can the package do this?_
with names rather than counts: what is bound, what a name in the manifest would add — under the
heading MuJoCo's header gives each block of functions — and, per area, what cannot be bound
from a signature at all. Its rows are one decomposition of the same list, so they add up.

A change to a template in `lib/ex_mujoco/gen/` can emit C++ the compiler rejects, and
`mix ex_mujoco.gen` compiles the project before it runs — a deadlock. Make the edit to
`c_src/generated/*.inc` by hand first, compile, then generate.

## Rendering

A renderer is MuJoCo's own three-part job — an abstract scene, the visualisation options, and an
`mjrContext` with an offscreen framebuffer attached to a current OpenGL context. Nuances that
are easy to get wrong, and are pinned by `test/ex_mujoco/renderer_test.exs`:

- **The context is this package's, and nothing links OpenGL.** `c_src/gl.cpp` opens the
  platform library with `dlopen` — `/System/Library/Frameworks/OpenGL.framework/OpenGL` for CGL,
  `libEGL.so.1` for EGL — so a machine without GL still loads the package. MuJoCo's glad loader
  then finds the same library by itself. Windows has no branch; `available?/0` says so.
- **A GL context belongs to the thread that made it current**, and the BEAM hands successive
  NIF calls to whichever scheduler is free, so `gl::Session` makes it current _and holds a lock_
  for the length of a render. Freeing a context is a session too: its GL objects are only
  deletable while it is current.
- **The depth pass converts the projection's reciprocal to metres**, in float32 coefficients and
  float64 arithmetic, exactly as MuJoCo's Python `Renderer` does — and it renders with
  `mjRND_SEGMENT`/`mjRND_IDCOLOR` set, which is MuJoCo's trick for a depth buffer accurate at
  both 5 cm and 500 m. With different precision the images differ in the last bits; a test
  compares ours with Python's byte for byte.
- **OpenGL hands pixels back bottom row first** and every reader wants the top row first, so
  each pass is flipped on the way out.
- **The image may not be larger than the model's offscreen buffer** (`<visual><global
offwidth=… offheight=…/>`), and asking for more is refused by name rather than rendered
  black.
- **A machine without OpenGL is the half of the matrix that skips**, so it stays unobserved
  unless something makes it reachable: `EX_MUJOCO_NO_GL=1` makes `gl::available` answer
  "no" (with a sentence) on a machine that could render. `EX_MUJOCO_NO_GL=1 mix test` runs
  the suite as a GL-less runner would, and `renderer_availability_test.exs` pins both
  answers wherever the suite runs.
- **A new `.cpp` in `c_src/` also belongs in `Makefile.win`.** The Unix `Makefile` globs
  `c_src/*.cpp`; Windows has no `wildcard`, so its list is written out, and 0.2.0's two new
  units were missed there until the Windows link failed on four unresolved symbols — with a
  CI job on `windows-2022` as the only thing that would have noticed. Anything platform
  specific in a shared unit has to compile where it is not implemented, too: `<dlfcn.h>` is
  included under `__APPLE__ || __linux__` for that reason.
- **A NIF that answers `bool` answers `:""` under MSVC.** Fine encodes `true` and `false`
  from atoms it fills in at load, and on Windows the encoding arrives as an atom with an
  empty name — which is truthy, so `if` takes the wrong branch and `not` raises. Build the
  atom by name (`fine::Atom(ok ? "true" : "false")`) and normalise at the Elixir boundary
  (`== true`), and keep one test that runs where the suite runs, not only where it renders:
  the renderer cases skip on a machine without OpenGL, and the refusal is exactly the path
  that had the bug.

## What the build compiles

Optimised, on every platform: `-O3` in `Makefile` (Linux and macOS), `/O2` in `Makefile.win`
(MSVC), and MuJoCo itself either as the upstream release artifact or, where there is none for
the platform, a CMake `Release` build — `scripts/prepare_mujoco.exs` is what decides, and it
never asks for a debug configuration.

A debug build is asked for by name: `EX_MUJOCO_DEBUG=1 mix compile` adds `-g -O0`. The
variable is prefixed for a reason — a bare `DEBUG` can already be set in a shell or on a
runner for reasons that have nothing to do with this package, and would then quietly turn a
release into an unoptimised one. Windows has no conditional in `Makefile.win` (nmake has no
`ifdef`): a debug build there is a change to the `/O2` on its `CPPFLAGS` line.

## Tests


`mix test` runs the suite against the pinned MuJoCo: behaviour (`step`, state round-trips,
errors), the generated fields, the tensor shape rules, the generator's own checks, and two
contracts worth knowing about —

- **the package ships what the build reads** (`test/ex_mujoco/package_test.exs`), because a
  file left out of `package: files` is a dependency that cannot compile;
- **the pin is the version the library answers**, so a build against `main` fails rather than
  reporting physics it cannot name.

`mix precommit` — when it is present — is compile with `--warnings-as-errors`, format check,
`credo --strict`, `dialyzer`, the generator check, and the suite.

## A release runs the load hook too early

Every module carrying an `@on_load` goes into a release's boot script, and `init` runs those
hooks while the kernel is still starting. A library cannot be loaded there: the preloader is a
module the hook would have to load, and module loading is the one thing that does not work yet,
so the call answers `undef`, the hook fails, and the VM dies in `on_load_function_failed` before
any application starts. That was 0.2.3 — a host's server gone in 300 ms with 44 lines of crash
report — and no test in this repository could see it, because a test VM starts applications and
never runs a boot script.

The hook now answers `:later` when the module it needs is not reachable, and the
application callback (`lib/ex_mujoco/application.ex`) loads the library when the
application starts — after the kernel is up, before any caller can reach a stub
that is not a NIF yet. `scripts/release-boot.sh` is the check: it builds a
release of this library, starts it, and asks it the library's version over
`rpc`. The `test (ubuntu)` job runs it.

## CI

`ci.yml`, on every push that touches something other than prose:

| job                         | what it proves                                                                                  |
| --------------------------- | ----------------------------------------------------------------------------------------------- |
| `lint`                      | no warnings, formatted, credo, and that `VERSION`, `mix.exs` and the README agree               |
| `gen`                       | `mix ex_mujoco.gen --check` — the committed bindings are the pinned headers                     |
| `types`                     | `mix dialyzer`                                                                                  |
| `test (ubuntu, windows)`    | the suite on both, with MuJoCo fetched fresh on every run                                       |
| `package (ubuntu, windows)` | the tarball Hex would ship is unpacked and installed with `Mix.install/2` in an empty directory |

There is no macOS job: this account has no macOS runner, and a job that cannot start is
cancelled rather than failed, which reddens a run for something the build did not do. macOS is
the machine the package is developed on, and `mix hex.build` → `Mix.install` is how a release is
verified there.

`mujoco-main.yml` runs once a day against upstream `main` and is information, not a gate: it
builds MuJoCo from source at `heads/main` and steps a model, so a pin that can no longer be
moved is known before somebody tries to move it.

## Docs

`mix docs` has to print nothing, and `mix hex.publish` builds the docs from the package, so the
documentation is part of a release rather than something added afterwards.

- The front page is `README.md`, and it is written for a caller: install, the pin, usage, where
  to look. Anything about working on the package belongs here, not there.
- `mix.exs` groups the modules with patterns: `Types` is a regular expression over
  `ExMujoco.Types.*` against the module name, because the alternative is eighty module names in
  a list. `Physics`, `The C API` and `Errors` are short lists; `Generating the bindings` is the
  other pattern, so the generator's modules do not sit among the API.
- Prose names an internal module by what it does ("the NIF's load hook") or by its file
  (`priv/ex_mujoco_preload.dll`). A backticked `` `ExMujoco.Native` `` in a rendered document is
  an ex_doc warning, because that module is hidden on purpose — and warnings in a docs build are
  how a stale link survives a release.
- The generated field functions carry the generator's description of the field, taken from
  MuJoCo's own header comments, so `ExMujoco.Model.geom_size/1` is documented with MuJoCo's
  documentation for `geom_size`.
- A field is filed under the heading MuJoCo's header gives its block: `// bodies` and the
  `body_` pointers under it, `// computed by mj_fwdPosition/mj_kinematics` and what that pass
  writes. The parser keeps the heading it found each declaration under and the generator writes
  it as `@doc group:`; the words are MuJoCo's, none is invented, and every field has one. So
  `geom_pos` is under `geoms`, `qpos` under `state`, `xpos` under
  `computed by mj_fwdPosition/mj_kinematics`. A heading is a title in a C comment and lands in
  an Elixir string literal, so `escape/1` in `lib/ex_mujoco/gen/template.ex` comes first.

  Earlier releases derived the heading from the name's prefix (`geom_size` → `geom`) once ten
  fields shared it. That left a third of both pages in one alphabetical heap — including the
  dimension counters and `qpos` — because MuJoCo's blocks are not always one prefix.

- The bound functions are filed the same way, and for the same reason. `mujoco.h` writes a prose
  comment above each `MJAPI` declaration and a `// ---- Main simulation ----` line above runs of
  them; the declarations themselves are read with the comments stripped, so a second pass over
  the same text keeps both, keyed by the name in the declaration (`annotations/1` in
  `lib/ex_mujoco/gen/header.ex`). `ExMujoco.Api` then carries the sentence and the heading, and
  so does the C++ — a NIF with MuJoCo's line above it is easier to review than one without.
- The enumerations are the third case. `typedef enum mjtGeom_ {  // type of geometric shape`
  describes the enumeration, and the comment after each value describes that value, so
  `enums_in/1` reads the header **with** its comments kept. A comment holding a brace would end
  the body early, so the same scan runs over the text with comments removed and the two have to
  find the same enumerations, in the same order — a drift raises instead of generating wrong
  numbers.

## Releasing

`VERSION` is the one place the version lives; `mix.exs` and the README's dependency line are
updated from it.

```console
$ ./scripts/tag_and_push_version.sh --dry-run   # what it would do
$ ./scripts/tag_and_push_version.sh             # v0.1.3, pushed
```

It refuses to tag a commit whose CI is not green, and a commit CI never saw — a docs-only push,
since the workflow ignores prose — is compared against the last run that did succeed.

The tag is what `.github/workflows/release.yml` publishes from. It checks that the tag, `VERSION`
and `mix.exs` agree; **that the build came from the pinned MuJoCo** (no override in the
environment, and the prepared library's `.provider` says `release=<pin>`);
`mix ex_mujoco.gen --check`; then `mix hex.publish` and the GitHub release.

Hex stages every publish on this account for approval — package and docs separately — so
`mix hex.publish` succeeding is not the same as being live. Check
`https://hex.pm/api/packages/ex_mujoco/releases/<version>` and the dashboard link the publish
prints.

A patch bump is the default between releases: nothing a caller wrote has to change.
