# What `mix ex_mujoco.gen` binds, and what it deliberately does not.
#
# The headers say what MuJoCo has — 551 functions, 83 enums, and every field of
# mjModel and mjData. This file is the human decision on top of that, and it is
# the only hand-edited input to the generator.
#
# `functions` are the ones bound 1:1 from their C signature. A name here that the
# generator cannot bind — a callback, a `void*`, a variadic list — is an error,
# not a silent omission, and says which of those it is.
#
# Everything else MuJoCo declares is listed in `docs/coverage.md` as unbound.
# That is where the next function goes when someone needs it.
map = %{
  functions: ~w(
    mj_versionString
    mj_name2id
    mj_id2name
    mj_isSparse
    mj_isDual
    mj_getTotalmass
    mj_step1
    mj_step2
    mj_kinematics
    mj_comPos
    mj_camlight
    mj_flex
    mj_tendon
    mj_transmission
    mj_crb
    mj_sensorPos
    mj_sensorVel
    mj_sensorAcc
    mj_energyPos
    mj_energyVel
    mj_collision
    mj_makeConstraint
    mj_projectConstraint
    mj_referenceConstraint
    mj_resetDataKeyframe
  ),

  # Bound by hand in `c_src/ex_mujoco_nif.cpp`, with the arity each NIF has and
  # the reason it is not generated. The arity is here because
  # `:erlang.load_nif` insists that every function the library registers already
  # exists in the module it is loading into — so these get stubs like the rest.
  #
  # `c` is the MuJoCo function each one translates, and `nil` where the answer is
  # a constant in the header rather than a call. Nothing else in the build needs
  # it; `docs/coverage.md` does, because a hand-bound function is covered and must
  # not be offered as something to bind.
  hand_written: [
    %{name: "load_xml", c: "mj_loadXML", arity: 1, why: "the error is a caller-sized char buffer; here it is our buffer and an exception"},
    %{name: "load_xml_string", c: "mj_parseXMLString", arity: 1, why: "a parsed spec has to be compiled and freed around the model, which is a lifetime question"},
    %{name: "data", c: "mj_makeData", arity: 1, why: "the data block belongs to a model, so the handle holds both"},
    %{name: "reset", c: "mj_resetData", arity: 1, why: "the step surface is `(data)`, because the handle carries its model"},
    %{name: "forward", c: "mj_forward", arity: 1, why: "same: `ExMujoco.forward/1` takes the data, not model and data"},
    %{name: "step", c: "mj_step", arity: 1, why: "same: `ExMujoco.step/1` takes the data"},
    %{name: "state_size", c: "mj_stateSize", arity: 2, why: "paired with get_state and set_state, which share the signature's meaning"},
    %{name: "get_state", c: "mj_getState", arity: 2, why: "writes into a buffer whose length `state_size` fixed; allocated here"},
    %{name: "set_state", c: "mj_setState", arity: 3, why: "reads a buffer whose length `state_size` fixed; checked here"},
    %{name: "data_state_size", c: "mj_stateSize", arity: 2, why: "the same count, asked of the data `put_state` is given"},
    %{name: "contact_force", c: "mj_contactForce", arity: 2, why: "writes six numbers into a caller's array; allocated here"},
    %{name: "version", c: "mj_version", arity: 0, why: "the library's own version, checked against the headers at load time"},
    %{name: "header_version", c: nil, arity: 0, why: "the header's version, for the same check"},
    %{name: "renderer_available", c: nil, arity: 0, why: "the question a caller asks before rendering; the answer is this package's own (is there an OpenGL context here), not one MuJoCo declares"},
    %{name: "renderer_unavailable_reason", c: nil, arity: 0, why: "the sentence `renderer_available/0` answers false with, so a caller can say why instead of only 'no'"},
    %{name: "renderer_new", c: "mjr_makeContext", arity: 3, why: "a render context uploads the model's meshes and textures into GL objects, so it is a resource that holds its model and needs an OpenGL context of this package's own"},
    %{name: "renderer_render", c: "mjr_render", arity: 4, why: "one scene update and one draw per pass, answering this pass's bytes rather than a caller-sized buffer — the depth conversion and the vertical flip belong to the answer"}
  ],

  # Choices that would otherwise look like omissions.
  notes: %{
    "mjSpec" => "building a model at run time (mjs_addBody and the rest) is v0.2; loading XML, from a path or from a string, is enough to run anything meanwhile",
    "mjr_readPixels, mjv_updateScene, mjv_makeScene, mjr_setBuffer, mjv_defaultScene" => "the renderer's own plumbing: `renderer_render/4` calls them in MuJoCo's own order, and binding them one by one would offer a caller a way to break that order",
    "mj_printData, mj_printModel" => "they write into a buffer the caller sizes; a string-returning wrapper is a design decision, not a translation",
    "mj_copyData" => "it answers the destination it was given, and a handle to a data block you already hold is not a useful answer; copying state is `state/2` and `put_state/3`"
  }
}

map
