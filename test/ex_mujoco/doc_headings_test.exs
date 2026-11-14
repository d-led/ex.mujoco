defmodule ExMujoco.DocHeadingsTest do
  use ExUnit.Case, async: true

  # MuJoCo's header is a run of headings and the declarations under them. The
  # reference pages say the same thing in the same words, so a reader who knows
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
      for module <- [ExMujoco.Model, ExMujoco.Data], field <- names(module) do
        assert heading_of(module, field) != nil,
               "#{inspect(module)}.#{field} is in the flat list"
      end
    end
  end

  describe "a bound function's page" do
    test "files it under MuJoCo's heading for the run it belongs to" do
      assert heading_of(ExMujoco.Api, :mj_step1) == "Main simulation"
      assert heading_of(ExMujoco.Api, :mj_resetDataKeyframe) == "Initialization"
      assert heading_of(ExMujoco.Api, :mj_name2id) == "Support"
    end

    test "says what the function does, in MuJoCo's words" do
      assert doc_of(ExMujoco.Api, :mj_kinematics) =~ "Run forward kinematics."
      assert doc_of(ExMujoco.Api, :mj_getTotalmass) =~ "Sum all body masses."
    end

    test "leaves no bound function without a heading or a description" do
      for function <- names(ExMujoco.Api) do
        assert heading_of(ExMujoco.Api, function) != nil,
               "ExMujoco.Api.#{function} is in the flat list"

        assert doc_of(ExMujoco.Api, function) =~ ~r/ in C\./,
               "ExMujoco.Api.#{function} does not say what the C signature is"
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

  defp doc_of(module, name) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    Enum.find_value(docs, fn
      {{:function, ^name, _arity}, _annotation, _signature, doc, _metadata} ->
        case doc do
          %{"en" => text} -> text
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp names(module) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)
    for {{:function, name, _arity}, _, _, _, _} <- docs, do: name
  end
end
