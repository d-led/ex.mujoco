# Changelog

## 0.1.5

Every field's heading is MuJoCo's, and every field has one.

- `ExMujoco.Model` (585 fields) and `ExMujoco.Data` (218) are now filed under the heading
  MuJoCo's header gives the block a field is declared in: `bodies`, `geoms`, `sizes needed at
mjModel construction`, `state`, `control`, and — for the fields a pass writes —
  `computed by mj_fwdPosition/mj_kinematics`, `computed by mj_makeConstraint` and the rest. The
  words are MuJoCo's own.
- This replaces the prefix rule of 0.1.4, which named a section after the field's prefix once ten
  fields shared it and left 193 fields of `Model` and 157 of `Data` in one alphabetical list. The
  flat list held the dimension counters (`nq`, `ngeom`, `ntendon`) and, in `Data`, `time`,
  `qpos`, `qvel`, `ctrl`, `xpos` and `sensordata` — the names a caller types first.
- The parser keeps the heading it found each declaration under instead of discarding comment
  lines, and the generator writes it as `@doc group:`. There is no threshold left to tune: the
  heading is whatever MuJoCo wrote above the field.

## 0.1.4

A field reference you can navigate.

- `ExMujoco.Model` and `ExMujoco.Data` group their functions the way MuJoCo names fields:
  `geom`, `body`, `jnt`, `actuator`, `tendon`, `flex`, `sensor` and the rest are sections of the
  page instead of one alphabetical wall of several hundred functions. The heading is MuJoCo's own
  prefix, and a family needs ten fields to earn one, so nothing is invented and no heading
  covers two functions.
- The rule is `@family_size` in the generator, so changing it is one edit and
  `mix ex_mujoco.gen` decides the rest — and `--check` keeps the committed bindings honest.

## 0.1.3

The documentation a caller reads, separated from the documentation a maintainer reads.

- `README.md` — which Hex publishes and HexDocs renders as the front page — is now written for
  using the package: install, the pinned MuJoCo and how to ask which one you have, the curated
  surface, errors, and a table of where each other question is answered.
- Everything about working on the package moved to `docs/development.md`: the repository's
  shape, how the bindings are generated, the tests that state contracts, the CI jobs, and
  releasing.
- The API reference is grouped the way a reader looks for things — `Physics`, `The C API`,
  `Types`, `Errors`, and `Generating the bindings` — so eighty `ExMujoco.Types.*` modules are
  one group instead of a wall, and the generator's modules are not among the API.
- `mix docs` prints no warnings: prose names an internal module by what it does, not with a
  link to a module that is hidden on purpose.

## 0.1.2

Which MuJoCo is in front of you, answerable from code.

- `ExMujoco.mujoco_version/0` answers the pin as MuJoCo spells it (`"4.0.1"`), compiled in from
  `mujoco.version`, so it answers inside a dependency. `version/0` and `header_version/0` are
  what the library and the headers say; the module doc names all three, and a test holds the pin
  to the library — a build against `main` now disagrees instead of stepping physics it cannot
  name.
- The prepared MuJoCo's `.provider` records the artifact and its checksum, not only the version:
  for a binary nobody here built, the checksum names the bytes where a commit would only name
  source.

## 0.1.1

The patch that makes the pin enforced rather than merely intended.

- The release workflow refuses to build a tag against anything but the pinned MuJoCo artifact:
  it fails if an override is set, and it reads the prepared library's `.provider` and requires
  it to name that release.
- A `mujoco main` workflow builds and steps a model against upstream `main` once a day, so a
  pin that can no longer be moved is known before somebody tries to move it.

## 0.1.0

The first release: physics, and nothing that needs a window.

- A model compiled from MJCF — `ExMujoco.load_xml/1` for a file, `ExMujoco.load_string/1` for
  memory — and `ExMujoco.data/1` for its state.
- `ExMujoco.forward/1`, `step/1`, `reset/1`, and the integration state as a binary:
  `state/1,2`, `put_state/3`, `state_size/1,2`.
- **Every field of `mjModel` and `mjData`**, one function each, generated from MuJoCo's own
  headers with the extents from `mjxmacro.h`: `ExMujoco.Model.geom_size/1`,
  `ExMujoco.Data.qpos/1`. A scalar answers a number, an array answers an
  `ExMujoco.Tensor` with its element type and shape.
- **Every enum**, resolved from the headers — including the ones C numbers implicitly and the
  ones that are an OR of their siblings: `ExMujoco.Types.Geom.box()`,
  `ExMujoco.Types.State.integration()`.
- Twenty-odd C functions bound 1:1 under their own names in `ExMujoco.Api`, and a dozen
  written by hand where the call needs a decision.
- MuJoCo's fatal error is intercepted and re-raised as `ExMujoco.Error`, so a model MuJoCo
  refuses is an exception in one process instead of a dead node.
- The library and the headers are compared on first use; a mismatch raises rather than
  stepping a different physics.
- Building: the official MuJoCo release is fetched and checksum-verified for Linux, macOS and
  Windows, or built from source at any ref (`EX_MUJOCO_SOURCE_REF=main`), or taken from a
  `MUJOCO_DIR` of your own.
- On Windows nothing has to be on `PATH`: `priv/ex_mujoco_preload.dll` puts MuJoCo in the
  process before the NIF that imports it, which is the one thing Windows will not do for a
  library on its own. MuJoCo's own Windows requirement — the Visual C++ runtime — is named
  in [`docs/building.md`](docs/building.md).

No `mjSpec` and no rendering; [`docs/plan.md`](docs/plan.md) says why they are their own
releases.
