// Offscreen rendering: MuJoCo's own `mjv_*`/`mjr_*` renderer, wrapped in a value
// a NIF can own.
//
// This is the same three-part job MuJoCo's Python `Renderer` does — an abstract
// scene, the visualisation options, and a render context with an offscreen
// framebuffer — with the differences that matter for a package:
//
//   * the GL context is this package's (see `gl.hpp`), not a platform binding's;
//   * a pass answers *this* pass's bytes, not a numpy array, so nothing has to
//     cross as JSON;
//   * the depth pass converts the depth buffer to metres here, so a caller is
//     handed the distance rather than the projection's reciprocal.

#pragma once

#include <string>
#include <vector>

#include <mujoco/mujoco.h>

#include "handles.hpp"

namespace exmujoco {

// What one pass draws. The three are not alternatives — a step that wants the
// picture, the distance and the object ids renders all three.
enum class Pass {
  kRgb,
  kDepth,
  kSegmentation,
};

// An `mjrContext` and the scene it draws, for one resolution.
//
// The model is held, not borrowed: a render context uploads the model's meshes
// and textures into GL objects, and a model freed underneath it would leave them
// pointing at nothing.
struct Renderer {
  Renderer(fine::ResourcePtr<Model> model, int width, int height);
  ~Renderer();

  Renderer(const Renderer &) = delete;
  Renderer &operator=(const Renderer &) = delete;

  // Draws `passes` for the camera `camera` names, in order, appending one image
  // to `images` per pass:
  //
  //   * `kRgb`          — `3 * width * height` bytes, RGB, top row first;
  //   * `kDepth`        — `4 * width * height` bytes, float32 metres, top row first;
  //   * `kSegmentation` — `4 * width * height` bytes, int32 geom ids, top row first.
  //
  // A background pixel is `-1`, which is MuJoCo's "no geom" and what every
  // caller of segmentation already has to understand.
  void render(const mjData *data, const std::string &camera, const std::vector<Pass> &passes,
              std::vector<std::string> &images);

  int width() const { return width_; }
  int height() const { return height_; }

 private:
  void draw(mjrRect rect, Pass pass, std::string &image);

  fine::ResourcePtr<Model> model_;
  int width_;
  int height_;

  mjvScene scene_;
  mjvOption option_;
  mjvCamera camera_;
  mjrContext context_;

  // The flags `mjv_defaultScene` set: a pass starts from these, because the
  // segmentation passes set two of them and nothing may be left over.
  mjtByte default_flags_[mjNRNDFLAG] = {0};
};

// Whether MuJoCo will make a renderer on this machine, memoised, with the reason
// when it will not.
//
// A context that this package's own GL calls are happy with is not the same
// thing: `mjr_makeContext` resolves its entry points through its own loader and
// refuses a model whose default framebuffer it cannot read, so the only answer a
// caller can trust is MuJoCo's. It is asked once, on a scene of two bodies that
// is built and thrown away.
bool renderable(std::string *reason);

}  // namespace exmujoco
