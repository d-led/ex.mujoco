# Changelog

## 0.1.0

The first release: physics, and nothing that needs a window.

* A model compiled from MJCF — `ExMujoco.load_xml/1` for a file, `ExMujoco.load_string/1` for
  memory — and `ExMujoco.data/1` for its state.
* `ExMujoco.forward/1`, `step/1`, `reset/1`, and the integration state as a binary:
  `state/1,2`, `put_state/3`, `state_size/1,2`.
* **Every field of `mjModel` and `mjData`**, one function each, generated from MuJoCo's own
  headers with the extents from `mjxmacro.h`: `ExMujoco.Model.geom_size/1`,
  `ExMujoco.Data.qpos/1`. A scalar answers a number, an array answers an
  `ExMujoco.Tensor` with its element type and shape.
* **Every enum**, resolved from the headers — including the ones C numbers implicitly and the
  ones that are an OR of their siblings: `ExMujoco.Types.Geom.box()`,
  `ExMujoco.Types.State.integration()`.
* Twenty-odd C functions bound 1:1 under their own names in `ExMujoco.Api`, and a dozen
  written by hand where the call needs a decision.
* MuJoCo's fatal error is intercepted and re-raised as `ExMujoco.Error`, so a model MuJoCo
  refuses is an exception in one process instead of a dead node.
* The library and the headers are compared on first use; a mismatch raises rather than
  stepping a different physics.
* Building: the official MuJoCo release is fetched and checksum-verified for Linux, macOS and
  Windows, or built from source at any ref (`EX_MUJOCO_SOURCE_REF=main`), or taken from a
  `MUJOCO_DIR` of your own.

No `mjSpec` and no rendering; [`docs/plan.md`](docs/plan.md) says why they are their own
releases.
