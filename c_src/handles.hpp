// The handles a NIF holds: MuJoCo's model and data, owned by resources.
//
// Declared here rather than in the NIF's own file because a renderer keeps the
// model alive through one of these, and the model's arrays are what a render
// reads. `FINE_RESOURCE` is invoked once, in `ex_mujoco_nif.cpp`; including this
// header elsewhere only makes the types visible.

#pragma once

#include <stdexcept>

#include <fine.hpp>
#include <mujoco/mujoco.h>

namespace exmujoco {

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

  explicit Data(fine::ResourcePtr<Model> m) : model(m), data(mj_makeData(m->model)) {
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
