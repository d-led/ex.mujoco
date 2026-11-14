defmodule ExMujoco.TypesTest do
  use ExUnit.Case, async: true

  alias ExMujoco.Types.{Geom, Obj, State}

  # The numbers are MuJoCo's, read from the headers. The names are the ones
  # Monty's Python uses, which is what this package is for: `mjtGeom.mjGEOM_BOX`
  # is `Geom.box()`.

  test "the geometry types" do
    assert Geom.plane() == 0
    assert Geom.sphere() == 2
    assert Geom.box() == 6
    assert Geom.mesh() == 7
  end

  test "the object types" do
    assert Obj.unknown() == 0
    assert Obj.body() == 1
    assert Obj.geom() == 5
  end

  test "a value is also an atom, in both directions" do
    assert Geom.to_integer(:box) == 6
    assert Geom.to_atom(6) == :box
    assert Geom.to_atom(:box) == :box
    assert Geom.to_integer(6) == 6
    assert Geom.to_atom(999) == nil
  end

  test "the values are in the header's order" do
    values = Geom.values()

    assert {:plane, 0} == hd(values)
    assert Enum.all?(values, fn {_name, value} -> is_integer(value) end)
  end

  test "a bitmask enum resolves its shifts and its ORs" do
    # `mjSTATE_TIME = 1<<0`, `mjSTATE_INTEGRATION` is every bit set.
    assert State.time() == 1
    assert State.qpos() == 2
    assert State.integration() == 32_767
  end
end
