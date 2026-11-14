defmodule ExMujoco.FieldsTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "../fixtures/pendulum.xml")

  setup do
    {:ok, model} = ExMujoco.load_xml(@fixture)
    %{model: model, data: ExMujoco.data(model)}
  end

  describe "a scalar field" do
    test "answers the number MuJoCo holds", %{model: model} do
      assert ExMujoco.Model.nq(model) == 1
      assert ExMujoco.Model.nbody(model) == 2
      assert ExMujoco.Model.ngeom(model) == 2
    end

    test "a data scalar is read from the data, not the model", %{data: data} do
      # `nefc` is mjData's: zero constraints before a forward pass on a free arm.
      assert ExMujoco.Data.nefc(data) == 0
      assert ExMujoco.Data.ncon(data) == 0
    end
  end

  describe "an array field" do
    test "carries its shape and its element type", %{model: model} do
      geom_size = ExMujoco.Model.geom_size(model)

      assert geom_size.type == :f64
      assert geom_size.shape == {2, 3}
      assert ExMujoco.Tensor.to_list(geom_size) == [[5.0, 5.0, 0.1], [0.05, 0.05, 0.5]]
    end

    test "an n × 1 array is a vector, not a matrix", %{data: data} do
      qpos = ExMujoco.Data.qpos(data)

      assert qpos.shape == {1}
      assert ExMujoco.Tensor.to_list(qpos) == [0.0]
    end

    test "an int array is int32", %{model: model} do
      parent = ExMujoco.Model.body_parentid(model)

      assert parent.type == :i32
      assert ExMujoco.Tensor.to_list(parent) == [0, 0]
    end

    test "a data array dimensioned by the model finds the model's size", %{data: data} do
      # `xpos` is `nbody × 3`, and `nbody` is the model's.
      assert ExMujoco.Data.xpos(data).shape == {2, 3}
      assert ExMujoco.Data.qvel(data).shape == {1}
    end

    test "reading copies, so the value does not change under the reader",
         %{data: data} do
      ExMujoco.forward(data)
      held = ExMujoco.Data.qpos(data)
      [start] = ExMujoco.Tensor.to_list(held)

      for _ <- 1..50, do: ExMujoco.step(data)

      assert ExMujoco.Tensor.to_list(held) == [start]
      refute ExMujoco.Tensor.to_list(ExMujoco.Data.qpos(data)) == [start]
    end
  end

  describe "a field the package does not expose" do
    test "is not a function here at all", %{model: model} do
      # `mjModel.buffer` is the arena everything else points into; MuJoCo gives
      # it no extent, so it is not a field a caller can read.
      refute function_exported?(ExMujoco.Model, :buffer, 1)
      assert is_integer(ExMujoco.Model.nbuffer(model))
    end
  end
end
