defmodule ExMujocoTest do
  use ExUnit.Case, async: true

  alias ExMujoco.Types.State

  @fixture Path.join(__DIR__, "fixtures/pendulum.xml")

  describe "loading a model" do
    test "a file with a hinge becomes a model with one coordinate" do
      assert {:ok, model} = ExMujoco.load_xml(@fixture)

      assert ExMujoco.Model.nq(model) == 1
      assert ExMujoco.Model.nv(model) == 1
      assert ExMujoco.Model.nbody(model) == 2
      assert ExMujoco.Model.ngeom(model) == 2
    end

    test "the same model from memory" do
      xml = File.read!(@fixture)

      assert {:ok, model} = ExMujoco.load_string(xml)
      assert ExMujoco.Model.nq(model) == 1
    end

    test "a model MuJoCo will not parse is an error naming what is wrong" do
      assert {:error, %ExMujoco.Error{message: message}} =
               ExMujoco.load_string("<mujoco><worldbody><body></worldbody></mujoco>")

      assert message =~ ~r/error|Error/
    end

    test "a file that is not there is an error, not a crash" do
      assert {:error, %ExMujoco.Error{}} = ExMujoco.load_xml("/nonexistent/model.xml")
    end
  end

  describe "stepping" do
    setup do
      {:ok, model} = ExMujoco.load_xml(@fixture)
      %{model: model, data: ExMujoco.data(model)}
    end

    test "the arm falls from its out-of-balance pose", %{data: data} do
      ExMujoco.forward(data)
      at_rest = angle(data)

      for _ <- 1..250, do: ExMujoco.step(data)

      refute_in_delta angle(data), at_rest, 0.01
    end

    test "a forward pass alone does not move the state", %{data: data} do
      ExMujoco.forward(data)
      before = ExMujoco.Data.qpos(data)

      for _ <- 1..10, do: ExMujoco.forward(data)

      assert ExMujoco.Data.qpos(data) == before
    end

    test "reset puts the arm back where the model starts", %{data: data} do
      ExMujoco.forward(data)
      start = ExMujoco.Data.qpos(data)

      for _ <- 1..50, do: ExMujoco.step(data)
      ExMujoco.reset(data)

      assert ExMujoco.Data.qpos(data) == start
    end
  end

  describe "state" do
    setup do
      {:ok, model} = ExMujoco.load_xml(@fixture)
      %{model: model, data: ExMujoco.data(model)}
    end

    test "a state read before stepping, and written back, is the same state",
         %{model: model, data: data} do
      ExMujoco.forward(data)
      saved = ExMujoco.state(data)
      angle_before = angle(data)

      for _ <- 1..50, do: ExMujoco.step(data)
      refute_in_delta angle(data), angle_before, 0.001

      :ok = ExMujoco.put_state(data, State.integration(), saved)

      assert angle(data) == angle_before
      assert byte_size(saved) == 8 * ExMujoco.state_size(model)
    end

    test "a narrower signature is a smaller state", %{model: model, data: data} do
      physics = State.physics()

      assert ExMujoco.state_size(model, physics) < ExMujoco.state_size(model)
      assert byte_size(ExMujoco.state(data, physics)) == 8 * ExMujoco.state_size(model, physics)
    end

    test "a state of the wrong length is refused", %{data: data} do
      # An argument of the wrong shape is an `ArgumentError`: nothing MuJoCo
      # said, just a binary that is not the size the signature implies.
      assert_raise ArgumentError, fn ->
        ExMujoco.put_state(data, State.integration(), <<0.0::float-64>>)
      end
    end
  end

  describe "the library" do
    test "is the version its headers are" do
      # The library and the headers that generated the bindings are the same
      # MuJoCo or the numbers on either side of the border describe different
      # physics. Which version that is, is `mujoco.version`'s statement and the
      # next test's; a literal here would be a third copy of it to keep in step,
      # and was one: this file said 4.0.1 while the branch pinned 3.13.0.
      assert ExMujoco.version() == ExMujoco.header_version()
    end

    test "is the version the pin names" do
      # MuJoCo numbers a release `major * 1_000_000 + minor * 1_000 + patch`. The
      # pin is a third statement of the version, beside the library's and the
      # headers', and a build against anything else disagrees here rather than
      # answering confidently about the wrong physics.
      [major, minor, patch] =
        ExMujoco.mujoco_version() |> String.split(".") |> Enum.map(&String.to_integer/1)

      assert ExMujoco.version() == major * 1_000_000 + minor * 1_000 + patch
    end
  end

  defp angle(data) do
    data |> ExMujoco.Data.qpos() |> ExMujoco.Tensor.to_list() |> hd()
  end
end
