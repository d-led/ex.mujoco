# Working on the package

For people changing ExMujoco itself. Using it needs none of this — `README.md` and the API
reference cover that.

## The shape of the repository

|                                   |                                                                           |
| --------------------------------- | ------------------------------------------------------------------------- |
| `lib/ex_mujoco.ex`                | the curated API, hand-written                                             |
| `lib/ex_mujoco/`                  | `Model`, `Data`, `Api`, `Native` and `Types/*` — **generated**, committed |
| `c_src/ex_mujoco_nif.cpp`         | the hand-written half of the NIF: loading, state, contacts, errors        |
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
which are bound by hand because each call needs an answer no signature gives.

A change to a template in `lib/ex_mujoco/gen/` can emit C++ the compiler rejects, and
`mix ex_mujoco.gen` compiles the project before it runs — a deadlock. Make the edit to
`c_src/generated/*.inc` by hand first, compile, then generate.

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
