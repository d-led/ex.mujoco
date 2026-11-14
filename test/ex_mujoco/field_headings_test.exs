defmodule ExMujoco.FieldHeadingsTest do
  use ExUnit.Case, async: true

  # MuJoCo's header is a run of headings and the declarations under them. The
  # reference page says the same thing in the same words, so a reader who knows
  # MuJoCo's header already knows where to look — and a reader who does not is
  # being taught it.
  describe "a field's page" do
    test "files it under the heading MuJoCo declares it under" do
      assert heading_of(ExMujoco.Model, :geom_size) == "geoms"
      assert heading_of(ExMujoco.Model, :body_pos) == "bodies"

      assert heading_of(ExMujoco.Data, :qpos) == "state"
      assert heading_of(ExMujoco.Data, :ctrl) == "control"
    end

    test "files a computed field under the pass that computes it" do
      assert heading_of(ExMujoco.Data, :xpos) ==
               "computed by mj_fwdPosition/mj_kinematics"

      assert heading_of(ExMujoco.Data, :qacc_smooth) ==
               "computed by mj_fwdAcceleration"
    end

    test "files the model's dimensions together, not under their own prefixes" do
      assert heading_of(ExMujoco.Model, :nq) ==
               "sizes needed at mjModel construction"

      assert heading_of(ExMujoco.Model, :ngeom) ==
               heading_of(ExMujoco.Model, :nq)
    end

    test "leaves no field without one" do
      for module <- [ExMujoco.Model, ExMujoco.Data], function <- fields(module) do
        assert heading_of(module, function) != nil,
               "#{inspect(module)}.#{function} is in the flat list"
      end
    end
  end

  defp heading_of(module, name) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    Enum.find_value(docs, fn
      {{:function, ^name, _arity}, _annotation, _signature, _doc, metadata} ->
        Map.get(metadata, :group)

      _ ->
        nil
    end)
  end

  defp fields(module) do
    for {{:function, name, _arity}, _, _, _, _} <- docs(module), do: name
  end

  defp docs(module) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)
    docs
  end
end
