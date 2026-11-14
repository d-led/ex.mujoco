defmodule ExMujoco.Gen do
  @moduledoc """
  Turns MuJoCo's headers into the bindings this package ships.

  Three inputs decide the output:

    * the headers under `MUJOCO_DIR/include`, read by `ExMujoco.Gen.Header`;
    * `c_src/manifest.exs`, the one human decision — which C functions are bound
      1:1, and what was left out and why;
    * the shapes in `ExMujoco.Gen.Template`.

  What comes out is committed, so the package builds without a network and
  without a generator run: the C++ that Fine registers, and the Elixir that calls
  it. `mix ex_mujoco.gen --check` regenerates into a temporary directory and
  compares, which is how drift between the headers and the bindings is caught —
  the same rule MuJoCo applies to its own `python/mujoco/introspect` output.

  Everything the headers describe but this package does not bind is written to
  `docs/coverage.md`, with the reason. Nothing is dropped in silence.
  """

  alias ExMujoco.Gen.Header
  alias ExMujoco.Gen.Template

  @generated_files [
    "lib/ex_mujoco/native.ex",
    "lib/ex_mujoco/model.ex",
    "lib/ex_mujoco/data.ex",
    "c_src/generated/fields.inc",
    "c_src/generated/functions.inc",
    "docs/coverage.md"
  ]

  @doc """
  Regenerates everything, or — with `check: true` — compares what is on disk
  against what would be generated.

  Answers `{:ok, files}` with the paths written, or `{:error, stale}` naming the
  files that disagree.
  """
  def run(project_dir, opts \\ []) do
    files = generate(project_dir)

    if Keyword.get(opts, :check, false) do
      check(project_dir, files)
    else
      Enum.each(files, fn {path, content} ->
        full = Path.join(project_dir, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
      end)

      {:ok, Map.keys(files)}
    end
  end

  @doc """
  All generated content, as `%{path => content}`.
  """
  def generate(project_dir) do
    headers_dir = Path.join([mujoco_dir!(project_dir), "include"])
    api = Header.read(headers_dir)
    manifest = manifest!(project_dir)

    structs =
      Map.new(api.structs, fn {name, members} -> {name, Enum.map(members, &member!/1)} end)

    functions = Enum.map(api.functions, &function!/1)

    verify_manifest!(functions, manifest)

    generated = %{
      "lib/ex_mujoco/native.ex" => Template.native(structs, functions, manifest),
      "lib/ex_mujoco/api.ex" => Template.api(functions, manifest),
      "lib/ex_mujoco/model.ex" => Template.fields("Model", "model", structs["mjModel"]),
      "lib/ex_mujoco/data.ex" => Template.fields("Data", "data", structs["mjData"]),
      "c_src/generated/fields.inc" => Template.field_nifs(structs),
      "c_src/generated/functions.inc" => Template.function_nifs(functions, manifest),
      "docs/coverage.md" => Template.coverage(structs, functions, api.enums, manifest)
    }

    # One module per enum, each its own file so that a reader looking for
    # `mjtGeom` finds `ExMujoco.Types.Geom` and nothing else.
    generated
    |> Map.merge(Template.enum_modules(api.enums))
    |> Map.new(fn {path, content} -> {path, formatted(path, content)} end)
  end

  # Generated code is read and reviewed like any other, so it is formatted like
  # any other — and formatting it here is what lets `--check` compare text rather
  # than syntax: `mix format` must not be able to change a generated file.
  defp formatted(path, content) do
    if String.ends_with?(path, ".ex") do
      content |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")
    else
      content
    end
  end

  @doc "The files this generator owns."
  def generated_files, do: @generated_files

  defp check(project_dir, files) do
    stale =
      files
      |> Enum.reject(fn {path, content} ->
        full = Path.join(project_dir, path)
        File.exists?(full) and File.read!(full) == content
      end)
      |> Enum.map(&elem(&1, 0))

    if stale == [] do
      {:ok, []}
    else
      {:error, stale}
    end
  end

  defp mujoco_dir!(project_dir) do
    script = Path.join(project_dir, "scripts/prepare_mujoco.exs")
    {dir, 0} = System.cmd("elixir", [script, "--print-dir"])
    String.trim(dir)
  end

  # A name in the manifest that MuJoCo does not have, or has with a signature no
  # NIF can answer, is a mistake in the manifest — not something to skip. What
  # cannot be bound is said out loud, one function at a time.
  defp verify_manifest!(functions, manifest) do
    known = Map.new(functions, &{&1.name, &1})

    unknown = Enum.reject(manifest.functions, &Map.has_key?(known, &1))

    if unknown != [] do
      raise """
      c_src/manifest.exs names functions MuJoCo does not declare:

        #{Enum.join(unknown, ", ")}

      Either the name moved, or the MuJoCo this build is against is not the one
      the manifest was written for.
      """
    end

    unexpressible =
      for name <- manifest.functions,
          function = Map.fetch!(known, name),
          not Template.expressible?(function) do
        "#{name} — #{Template.unexpressible_reason(function)}"
      end

    if unexpressible != [] do
      raise """
      c_src/manifest.exs names functions that cannot be bound from their signature:

      #{Enum.map_join(unexpressible, "\n", &("  " <> &1))}

      Bind them by hand in c_src/ex_mujoco_nif.cpp, where the question they raise
      can be answered, or take them out of the manifest and say why in `notes`.
      """
    end
  end

  defp manifest!(project_dir) do
    path = Path.join(project_dir, "c_src/manifest.exs")

    unless File.exists?(path) do
      raise "c_src/manifest.exs is missing, and it is what says which C functions to bind"
    end

    {manifest, _} = Code.eval_file(path)
    Map.merge(%{functions: [], hand_written: [], notes: %{}}, manifest)
  end

  # A member arrives with its dimensions as `{d1, d2}` strings that still say
  # which struct each names (`nefc@data`), or as a bare C expression.
  defp member!(member) do
    %{
      name: member.name,
      kind: member.kind,
      dims: member.dims,
      element: Map.get(member, :element),
      c_type: member.type.name <> String.duplicate("*", member.type.pointers),
      pointers: member.type.pointers,
      doc: member.doc,
      section: Map.get(member, :section),
      reason: Map.get(member, :reason)
    }
  end

  defp function!(function) do
    %{
      name: function.name,
      returns: function.returns,
      parameters: function.parameters,
      doc: function.doc,
      section: Map.get(function, :section),
      variadic: function.variadic
    }
  end
end
