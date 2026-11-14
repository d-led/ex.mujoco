// The hand-written half of the NIF.
//
// Everything that needs a decision per call lives here: reading a file whose
// failure is a buffer of text, making a data block from a model, stepping, and
// the state signature. Everything with a signature that speaks for itself is
// generated into `generated/functions.inc` and `generated/fields.inc`, both of
// which are in this translation unit.
//
// Note the shape of every entry point: decode arguments, then one call into
// MuJoCo through `exmujoco::call`, which is what keeps a MuJoCo error from
// aborting the VM. See `mj_call.hpp`.

#include <cstring>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include <erl_nif.h>
#include <fine.hpp>
#include <mujoco/mujoco.h>

#include "gl.hpp"
#include "handles.hpp"
#include "mj_call.hpp"
#include "renderer.hpp"

namespace exmujoco {

// ---------------------------------------------------------------------- handles

// `Model` and `Data` are defined in `handles.hpp`: a renderer holds one of the
// first, so both sides of this file need to see them.

}  // namespace exmujoco

FINE_RESOURCE(exmujoco::Model);
FINE_RESOURCE(exmujoco::Data);
FINE_RESOURCE(exmujoco::Renderer);

namespace exmujoco {

// Fine stores a NIF's answer in a local, so no NIF can answer `void`. MuJoCo's
// `void` means "it worked; ask the data", which crosses as `:ok`.
//
// The atom is named at each call rather than kept in a global that Fine caches
// a term for at load: on Windows the cached term does not survive into a later
// call, and a truncated atom term is `:""` — an atom nobody meant to write.
inline fine::Atom ok() { return fine::Atom("ok"); }

namespace {

// ---------------------------------------------------------------------- helpers

// MuJoCo reports a compile failure by writing into a buffer it was given, and by
// calling mju_error for the failures that are not the file's fault. Both arrive
// here as a thrown runtime_error carrying the text.
std::runtime_error failure(const char *error,
                           const std::string &fallback) {
  return std::runtime_error(error != nullptr && error[0] != '\0' ? error
                                                                 : fallback);
}

mjModel *model_from_file(const std::string &path) {
  char error[1024] = {0};

  mjModel *model = call([&] {
    return ::mj_loadXML(path.c_str(), nullptr, error, sizeof(error));
  });

  if (model == nullptr) {
    throw failure(error, "MuJoCo could not read " + path);
  }

  return model;
}

mjModel *model_from_string(const std::string &xml) {
  char error[1024] = {0};

  mjSpec *spec = call([&] {
    return ::mj_parseXMLString(xml.c_str(), nullptr, error, sizeof(error));
  });

  if (spec == nullptr) {
    throw failure(error, "MuJoCo could not parse the model");
  }

  mjModel *model = nullptr;

  try {
    model = call([&] { return ::mj_compile(spec, nullptr); });
  } catch (...) {
    mj_deleteSpec(spec);
    throw;
  }

  mj_deleteSpec(spec);

  if (model == nullptr) {
    throw failure(error, "MuJoCo could not compile the model");
  }

  return model;
}

// A float64 binary, checked against what MuJoCo is about to be told it holds.
const mjtNum *as_mjtNum(const ErlNifBinary &binary, size_t expected) {
  if (binary.size != expected * sizeof(mjtNum)) {
    throw std::invalid_argument(
        "expected " + std::to_string(expected) + " float64 values, got " +
        std::to_string(binary.size) + " bytes");
  }

  return reinterpret_cast<const mjtNum *>(binary.data);
}

}  // namespace
}  // namespace exmujoco

// ---------------------------------------------------------------------- model

namespace {

using exmujoco::Data;
using exmujoco::Model;

fine::ResourcePtr<Model> load_xml(ErlNifEnv *, std::string path) {
  return fine::make_resource<Model>(exmujoco::model_from_file(path));
}
FINE_NIF(load_xml, 0);

fine::ResourcePtr<Model> load_xml_string(ErlNifEnv *, std::string xml) {
  return fine::make_resource<Model>(exmujoco::model_from_string(xml));
}
FINE_NIF(load_xml_string, 0);

// ---------------------------------------------------------------------- data

fine::ResourcePtr<Data> data(ErlNifEnv *, fine::ResourcePtr<Model> model) {
  return fine::make_resource<Data>(model);
}
FINE_NIF(data, 0);

fine::Atom reset(ErlNifEnv *, fine::ResourcePtr<Data> handle) {
  exmujoco::call([&] { ::mj_resetData(handle->model->model, handle->data); });
  return exmujoco::ok();
}
FINE_NIF(reset, 0);

fine::Atom forward(ErlNifEnv *, fine::ResourcePtr<Data> handle) {
  exmujoco::call([&] { ::mj_forward(handle->model->model, handle->data); });
  return exmujoco::ok();
}
FINE_NIF(forward, 0);

fine::Atom step(ErlNifEnv *, fine::ResourcePtr<Data> handle) {
  exmujoco::call([&] { ::mj_step(handle->model->model, handle->data); });
  return exmujoco::ok();
}
FINE_NIF(step, 0);

// ---------------------------------------------------------------------- state

int64_t state_size(ErlNifEnv *, fine::ResourcePtr<Model> handle, int64_t signature) {
  return exmujoco::call([&] {
    return ::mj_stateSize(handle->model, static_cast<int>(signature));
  });
}
FINE_NIF(state_size, 0);

fine::Term get_state(ErlNifEnv *env, fine::ResourcePtr<Data> handle,
                     int64_t signature) {
  int size = exmujoco::call([&] {
    return ::mj_stateSize(handle->model->model, static_cast<int>(signature));
  });

  std::vector<mjtNum> state(static_cast<size_t>(size));

  exmujoco::call([&] {
    ::mj_getState(handle->model->model, handle->data, state.data(),
                  static_cast<int>(signature));
  });

  return fine::make_new_binary(env, reinterpret_cast<const char *>(state.data()),
                               sizeof(mjtNum) * state.size());
}
FINE_NIF(get_state, 0);

fine::Atom set_state(ErlNifEnv *, fine::ResourcePtr<Data> handle, int64_t signature,
                      ErlNifBinary values) {
  int size = exmujoco::call([&] {
    return ::mj_stateSize(handle->model->model, static_cast<int>(signature));
  });

  const mjtNum *state = exmujoco::as_mjtNum(values, static_cast<size_t>(size));

  exmujoco::call([&] {
    ::mj_setState(handle->model->model, handle->data, state,
                  static_cast<int>(signature));
  });

  return exmujoco::ok();
}
FINE_NIF(set_state, 0);

// How many float64 values `set_state` wants, so a caller can be told what it
// asked for by name before handing over a binary of another size. It takes the
// data because `set_state` does: a state signature is only meaningful together
// with the model the data belongs to.
int64_t data_state_size(ErlNifEnv *, fine::ResourcePtr<Data> handle,
                        int64_t signature) {
  return exmujoco::call([&] {
    return static_cast<int64_t>(
        ::mj_stateSize(handle->model->model, static_cast<int>(signature)));
  });
}
FINE_NIF(data_state_size, 0);

// ---------------------------------------------------------------------- contacts

// `mj_contactForce` writes six numbers into a buffer the caller owns. A NIF that
// took the buffer would be asking Elixir to guess its length, so it allocates it
// and answers the six.
fine::Term contact_force(ErlNifEnv *env, fine::ResourcePtr<Data> handle,
                         int64_t index) {
  mjtNum force[6] = {0};

  exmujoco::call([&] {
    ::mj_contactForce(handle->model->model, handle->data,
                      static_cast<int>(index), force);
  });

  return fine::make_new_binary(env, reinterpret_cast<const char *>(force),
                               sizeof(force));
}
FINE_NIF(contact_force, 0);

// ---------------------------------------------------------------------- rendering

// Offscreen rendering, for a machine that has it. The renderer is a resource of
// its own because it owns a GL context's worth of objects — the model's meshes
// and textures are uploaded into it — and it has to outlive every call that
// draws.
//
// `renderer_available` is the question a caller asks first: a machine with no
// OpenGL still loads this package, steps and reads models, and says so here
// rather than failing at the first frame.
//
// The answer is an atom made here by name, not a `bool`: `Encoder<bool>` hands
// back Fine's `true`/`false` atoms, and under MSVC those arrive as `:""` — an
// atom whose name is empty — which a caller's `not` then raises on.
fine::Atom renderer_available(ErlNifEnv *) {
  std::string reason;

  return fine::Atom(exmujoco::gl::available(&reason) ? "true" : "false");
}
FINE_NIF(renderer_available, 0);

// Why rendering is not available, in words a person can read. Empty when it is.
std::string renderer_unavailable_reason(ErlNifEnv *) {
  std::string reason;
  exmujoco::gl::available(&reason);
  return reason;
}
FINE_NIF(renderer_unavailable_reason, 0);

fine::ResourcePtr<exmujoco::Renderer> renderer_new(ErlNifEnv *,
                                                   fine::ResourcePtr<Model> model,
                                                   int64_t width, int64_t height) {
  return fine::make_resource<exmujoco::Renderer>(model, static_cast<int>(width),
                                                 static_cast<int>(height));
}
FINE_NIF(renderer_new, 0);

// One step's images: `passes` names what to draw (`[:rgb, :depth, :segmentation]`),
// and the answer is one binary per pass, in that order.
//
// The scene is updated once and drawn once per pass, which is how MuJoCo's own
// renderer is used — and the reason a caller asks for one call rather than three
// is that three calls would update the scene three times.
fine::Term renderer_render(ErlNifEnv *env, fine::ResourcePtr<exmujoco::Renderer> renderer,
                           fine::ResourcePtr<Data> data, std::string camera,
                           std::vector<fine::Atom> passes) {
  std::vector<exmujoco::Pass> wanted;
  wanted.reserve(passes.size());

  for (const auto &pass : passes) {
    const auto name = pass.to_string();

    if (name == "rgb") {
      wanted.push_back(exmujoco::Pass::kRgb);
    } else if (name == "depth") {
      wanted.push_back(exmujoco::Pass::kDepth);
    } else if (name == "segmentation") {
      wanted.push_back(exmujoco::Pass::kSegmentation);
    } else {
      throw std::invalid_argument("there is no '" + std::string(name) +
                                 "' pass: ask for :rgb, :depth or :segmentation");
    }
  }

  std::vector<std::string> images;
  images.reserve(wanted.size());

  renderer->render(data->data, camera, wanted, images);

  std::vector<ERL_NIF_TERM> terms;
  terms.reserve(images.size());

  for (const auto &image : images) {
    terms.push_back(fine::make_new_binary(env, image.data(), image.size()));
  }

  return fine::Term(enif_make_list_from_array(env, terms.data(),
                                              static_cast<unsigned int>(terms.size())));
}
FINE_NIF(renderer_render, 0);

}  // namespace

// ---------------------------------------------------------------------- versions

// The library's version and the header's. They are compared when the NIF loads:
// a `priv/` that was built against one MuJoCo and is running against another
// would step different physics, quietly, and that is worse than not loading.
int64_t version(ErlNifEnv *) { return ::mj_version(); }
FINE_NIF(version, 0);

int64_t header_version(ErlNifEnv *) { return mjVERSION_HEADER; }
FINE_NIF(header_version, 0);

// ---------------------------------------------------------------------- generated

// The generated half lives in its own namespace: a NIF named `mj_step1` would
// otherwise shadow MuJoCo's `mj_step1` and every `::mj_step1(...)` in this file
// would resolve to the binding instead of the function. `FINE_NIF` registers
// under the bare name, so Elixir still calls `mj_step1`.
namespace exmujoco_generated {

#include "generated/fields.inc"
#include "generated/functions.inc"

}  // namespace exmujoco_generated

// ---------------------------------------------------------------------- init

namespace {

void load_callback(ErlNifEnv *, void **, fine::Term) {
  exmujoco::install_error_handler();
}

// Runs after the resource types exist and before the first call. Installing the
// handler at load means no call can reach MuJoCo's default one, which aborts.
auto __load_registration =
    fine::Registration::register_load(load_callback);

}  // namespace

FINE_INIT("Elixir.ExMujoco.Native");
