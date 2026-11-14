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

#include "mj_call.hpp"

namespace exmujoco {

// ---------------------------------------------------------------------- handles

// An mjModel, owned. MuJoCo's model is immutable once compiled, so a resource
// shared between processes is safe to read.
struct Model {
  mjModel *model;

  explicit Model(mjModel *m) : model(m) {}

  Model(const Model &) = delete;
  Model &operator=(const Model &) = delete;

  ~Model() {
    if (model != nullptr) {
      mj_deleteModel(model);
    }
  }
};

// An mjData, owned, and the model it was made from — mjData does not point at
// its model, and every step needs both, so holding the model here is what makes
// `step(data)` possible and what stops the model being freed first.
struct Data {
  fine::ResourcePtr<Model> model;
  mjData *data;

  explicit Data(fine::ResourcePtr<Model> m)
      : model(m), data(mj_makeData(m->model)) {
    if (data == nullptr) {
      throw std::runtime_error("mj_makeData returned nothing");
    }
  }

  Data(const Data &) = delete;
  Data &operator=(const Data &) = delete;

  ~Data() {
    if (data != nullptr) {
      mj_deleteData(data);
    }
  }
};

}  // namespace exmujoco

FINE_RESOURCE(exmujoco::Model);
FINE_RESOURCE(exmujoco::Data);

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
