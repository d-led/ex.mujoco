defmodule ExMujoco.GenTest do
  use ExUnit.Case, async: true

  alias ExMujoco.Gen.{Header, Template}

  @project Path.expand("../..", __DIR__)

  describe "the bindings in this repository" do
    test "are what the headers say they should be" do
      # The same check CI runs: regenerate into a comparison, write nothing.
      # A hand-edited generated file, or a MuJoCo bump without a regeneration,
      # fails here rather than drifting silently.
      assert {:ok, []} = ExMujoco.Gen.run(@project, check: true)
    end
  end

  describe "reading a header" do
    test "a function keeps its parameters, in order" do
      function = function!(Enum.find(all_functions(), &(&1.name == "mj_jacSite")))

      assert function.returns.name == "void"
      assert Enum.map(function.parameters, & &1.name) == ~w(m d jacp jacr site)

      assert Enum.map(function.parameters, & &1.kind) ==
               [:resource, :resource, :buffer, :buffer, :integer]
    end

    test "a return type keeps its stars" do
      function = Enum.find(all_functions(), &(&1.name == "mj_id2name"))

      assert %{name: "char", const: true, pointers: 1} = function.returns
    end

    test "a variadic function is not expressible" do
      function = Enum.find(all_functions(), &(&1.name == "mju_error"))

      refute Template.expressible?(function)
      assert Template.unexpressible_reason(function) =~ "variadic"
    end

    test "a const buffer is expressible, a writable one is not" do
      reader = Enum.find(all_functions(), &(&1.name == "mju_dot3"))
      writer = Enum.find(all_functions(), &(&1.name == "mj_getState"))

      assert Template.expressible?(reader)

      refute Template.expressible?(writer)
      assert Template.unexpressible_reason(writer) =~ "length"
    end
  end

  describe "reading a struct" do
    test "a pointer field carries the extent mjxmacro.h gives it" do
      geom_pos = Enum.find(members("mjModel"), &(&1.name == "geom_pos"))

      assert geom_pos.kind == :array
      assert geom_pos.element == {:f64, "mjtNum"}
      assert geom_pos.dims == {"ngeom", "3"}
    end

    test "a dimension that is a model member says so" do
      # `body_user` is `nbody × nuser_body`, and `nuser_body` is the model's.
      body_user = Enum.find(members("mjModel"), &(&1.name == "body_user"))

      assert body_user.dims == {"nbody", "nuser_body@model"}
    end

    test "a struct-typed member is not a field a caller can read" do
      options = Enum.find(members("mjModel"), &(&1.name == "opt"))

      assert options.kind == :unsupported
      assert options.reason =~ "by value"
    end
  end

  defp all_functions, do: Header.read(headers()) |> Map.fetch!(:functions)

  defp members(struct) do
    Header.struct_members!(headers(), struct)
  end

  defp headers do
    dir =
      System.cmd("elixir", [Path.join(@project, "scripts/prepare_mujoco.exs"), "--print-dir"])
      |> elem(0)
      |> String.trim()

    Path.join(dir, "include")
  end

  defp function!(function), do: function
end
