// Offscreen rendering, in C++: see `renderer.hpp` for what it is for.
//
// The numbers here are MuJoCo's own Python `Renderer`'s, deliberately — the depth
// conversion, the reverse-Z assumption, the vertical flip and the segmentation
// id packing are all copied from it, because a scene rendered differently is a
// different experiment.

#include "renderer.hpp"

#include <cstring>
#include <mutex>
#include <stdexcept>

#include "gl.hpp"
#include "mj_call.hpp"

namespace exmujoco {
namespace {

// MuJoCo's Python bindings' default, and enough for any scene this is likely to
// draw: the scene holds one entry per visible geom.
constexpr int kMaxGeom = 10000;

// The depth buffer, converted to the distance it stands for.
//
// OpenGL hands back a value in [0, 1]; the projection maps it to a distance
// hyperbolically, and MuJoCo renders in reverse-Z so 1 is the near plane. These
// are the coefficients of MuJoCo's Python `Renderer`, in the same precision:
// float32 for the planes and float64 for the arithmetic, because a 64-bit
// conversion is what keeps a 500 m far plane from swallowing a 5 cm scene.
void unproject(float *depth, size_t count, const mjModel *model, int orthographic) {
  const float znear = static_cast<float>(model->vis.map.znear * model->stat.extent);
  const float zfar = static_cast<float>(model->vis.map.zfar * model->stat.extent);

  if (orthographic) {
    for (size_t i = 0; i < count; i++) {
      depth[i] = zfar - depth[i] * (zfar - znear);
    }
    return;
  }

  // Float32 coefficients, like MuJoCo's own Python renderer computes them: two
  // renderers that agree to the bit are what makes a depth image a fixture.
  const float c_base = -(zfar + znear) / (zfar - znear);
  const float d_base = -(2.0f * zfar * znear) / (zfar - znear);

  const float c_coef = -0.5f * c_base - 0.5f;
  const float d_coef = -0.5f * d_base;

  for (size_t i = 0; i < count; i++) {
    depth[i] = static_cast<float>(d_coef / (static_cast<double>(depth[i]) + c_coef));
  }
}

// OpenGL hands pixels back bottom row first, and every reader of an image wants
// the top row first.
template <typename T>
void flip_rows(T *pixels, int width, int height) {
  const size_t row = static_cast<size_t>(width) * sizeof(T);

  for (int top = 0, bottom = height - 1; top < bottom; top++, bottom--) {
    T *a = pixels + static_cast<size_t>(top) * row / sizeof(T);
    T *b = pixels + static_cast<size_t>(bottom) * row / sizeof(T);

    for (size_t i = 0; i < row / sizeof(T); i++) {
      const T held = a[i];
      a[i] = b[i];
      b[i] = held;
    }
  }
}

}  // namespace

Renderer::Renderer(fine::ResourcePtr<Model> model, int width, int height)
    : model_(std::move(model)), width_(width), height_(height) {
  std::string reason;

  if (!gl::available(&reason)) {
    throw std::runtime_error("this machine cannot render offscreen: " + reason);
  }

  if (width <= 0 || height <= 0) {
    throw std::invalid_argument("a renderer needs a positive size, got " + std::to_string(width) +
                                "x" + std::to_string(height));
  }

  const mjModel *m = model_->model;

  if (width > m->vis.global.offwidth || height > m->vis.global.offheight) {
    throw std::invalid_argument(
        "an image of " + std::to_string(width) + "x" + std::to_string(height) +
        " does not fit the model's offscreen buffer of " + std::to_string(m->vis.global.offwidth) +
        "x" + std::to_string(m->vis.global.offheight) +
        ": raise `<visual><global offwidth=… offheight=…/>` in the model");
  }

  // A GL context has to be current before any of the calls below, and GL objects
  // belong to it.
  gl::Session session;

  mjv_defaultScene(&scene_);
  mjv_defaultOption(&option_);
  mjv_defaultCamera(&camera_);
  mjr_defaultContext(&context_);

  std::memcpy(default_flags_, scene_.flags, sizeof(default_flags_));

  call([&] { mjv_makeScene(m, &scene_, kMaxGeom); });
  call([&] { mjr_makeContext(m, &context_, mjFONTSCALE_150); });

  // MuJoCo renders in reverse-Z, which is what the conversion above assumes.
  context_.readDepthMap = mjDEPTH_ZEROFAR;
}

Renderer::~Renderer() {
  std::string reason;

  if (!gl::available(&reason)) {
    return;
  }

  // Freeing a context deletes GL objects, which has to happen with the context
  // that made them current.
  gl::Session session;

  mjr_freeContext(&context_);
  mjv_freeScene(&scene_);
}

void Renderer::render(const mjData *data, const std::string &camera,
                      const std::vector<Pass> &passes, std::vector<std::string> &images) {
  const mjModel *m = model_->model;

  const int id = call([&] { return ::mj_name2id(m, mjOBJ_CAMERA, camera.c_str()); });

  if (id < 0) {
    throw std::invalid_argument("the model has no camera named '" + camera + "'");
  }

  gl::Session session;

  // A fixed camera is the one the scene declares — Monty's sensors are cameras
  // on the agent's head, and a step looks through exactly one of them.
  camera_.type = mjCAMERA_FIXED;
  camera_.fixedcamid = id;

  gl::Session &held = session;
  (void)held;

  call([&] { mjv_updateScene(m, const_cast<mjData *>(data), &option_, nullptr, &camera_,
                             mjCAT_ALL, &scene_); });

  const mjrRect rect{0, 0, width_, height_};

  for (Pass pass : passes) {
    std::string image;
    draw(rect, pass, image);
    images.push_back(std::move(image));
  }
}

void Renderer::draw(mjrRect rect, Pass pass, std::string &image) {
  // Every pass starts from the scene's own flags: the segmentation passes set
  // two of them and the next pass must not inherit them.
  std::memcpy(scene_.flags, default_flags_, sizeof(default_flags_));

  // This renderer's own offscreen buffer, bound here rather than once in the
  // constructor: the binding is process-wide GL state, and another renderer made
  // after this one has bound its own. Rendering into that one and reading this
  // one drew a first image whose bottom rows were never written.
  call([&] { mjr_setBuffer(mjFB_OFFSCREEN, &context_); });

  if (pass == Pass::kDepth || pass == Pass::kSegmentation) {
    // MuJoCo's Python bindings render depth this way too: with segmentation on,
    // the depth buffer is written at the full precision its own pass needs,
    // which is what makes a 5 cm scene readable at a 500 m far plane.
    scene_.flags[mjRND_SEGMENT] = 1;
    scene_.flags[mjRND_IDCOLOR] = 1;
  }

  call([&] { mjr_render(rect, &scene_, &context_); });

  const size_t pixels = static_cast<size_t>(width_) * static_cast<size_t>(height_);

  switch (pass) {
    case Pass::kRgb: {
      image.resize(pixels * 3);
      auto *rgb = reinterpret_cast<unsigned char *>(image.data());

      call([&] { mjr_readPixels(rgb, nullptr, rect, &context_); });
      flip_rows(rgb, width_ * 3, height_);
      break;
    }

    case Pass::kDepth: {
      image.resize(pixels * sizeof(float));
      auto *depth = reinterpret_cast<float *>(image.data());

      call([&] { mjr_readPixels(nullptr, depth, rect, &context_); });

      unproject(depth, pixels, model_->model, scene_.camera[0].orthographic);
      flip_rows(depth, width_, height_);
      break;
    }

    case Pass::kSegmentation: {
      // The ids come back packed into three colour bytes, which is MuJoCo's own
      // encoding (`mjRND_IDCOLOR`): the low byte is the red channel.
      std::vector<unsigned char> packed(pixels * 3);
      call([&] { mjr_readPixels(packed.data(), nullptr, rect, &context_); });

      // A raw id is `segid + 1`, so that 0 can mean the background; the answer
      // is the geom's own id, and -1 where nothing was drawn.
      const int geoms = scene_.ngeom;
      std::vector<int32_t> ids(static_cast<size_t>(geoms) + 2, -1);

      for (int g = 0; g < geoms; g++) {
        const mjvGeom &geom = scene_.geoms[g];

        if (geom.segid >= 0 && geom.segid + 1 < static_cast<int>(ids.size())) {
          ids[static_cast<size_t>(geom.segid) + 1] = geom.objid;
        }
      }

      image.resize(pixels * sizeof(int32_t));
      auto *segmentation = reinterpret_cast<int32_t *>(image.data());

      for (size_t i = 0; i < pixels; i++) {
        const unsigned char *pixel = &packed[i * 3];
        const size_t raw = pixel[0] + (pixel[1] << 8) + (pixel[2] << 16);

        segmentation[i] = raw < ids.size() ? ids[raw] : -1;
      }

      flip_rows(segmentation, width_, height_);
      break;
    }
  }
}

bool renderable(std::string *reason) {
  static std::once_flag once;
  static bool ok = false;
  static std::string why;

  std::call_once(once, [&] {
    if (!gl::available(&why)) {
      return;
    }

    // A scene of one body and one geom: enough for `mjr_makeContext` to make its
    // context and answer, small enough to build and throw away.
    constexpr const char *kScene =
        "<mujoco><worldbody><body><geom type=\"sphere\" size=\".1\"/></body></worldbody></mujoco>";

    mjVFS vfs;
    mj_defaultVFS(&vfs);
    mj_addBufferVFS(&vfs, "probe.xml", kScene, static_cast<int>(std::strlen(kScene)));

    char error[1024] = "";
    mjModel *model = mj_loadXML("probe.xml", &vfs, error, sizeof(error));
    mj_deleteVFS(&vfs);

    if (model == nullptr) {
      why = std::string("a scene MuJoCo would not compile: ") + error;
      return;
    }

    mjvScene scene;
    mjv_defaultScene(&scene);

    mjrContext context;
    mjr_defaultContext(&context);

    try {
      gl::Session session;

      call([&] { mjv_makeScene(model, &scene, kMaxGeom); });
      call([&] { mjr_makeContext(model, &context, mjFONTSCALE_150); });

      ok = true;

      call([&] {
        mjr_freeContext(&context);
        mjv_freeScene(&scene);
      });
    } catch (const std::exception &error) {
      why = error.what();
    }

    mj_deleteModel(model);
  });

  if (!ok && reason != nullptr) {
    *reason = why;
  }

  return ok;
}

}  // namespace exmujoco
