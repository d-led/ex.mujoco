# Generated files are reviewed by their generator: `mix ex_mujoco.gen --check`
# proves they are what the headers say, and a style rule applied to them would be
# a rule about the emitter, not about the code it writes. Everything else is read
# by both.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "scripts/"],
        excluded: [
          "lib/ex_mujoco/api.ex",
          "lib/ex_mujoco/data.ex",
          "lib/ex_mujoco/model.ex",
          "lib/ex_mujoco/native.ex",
          "lib/ex_mujoco/types/"
        ]
      },
      strict: true
    }
  ]
}
