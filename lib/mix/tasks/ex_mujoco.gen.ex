defmodule Mix.Tasks.ExMujoco.Gen do
  @shortdoc "Regenerates the bindings from MuJoCo's headers"

  @moduledoc """
  Rewrites the NIF bindings, the Elixir that calls them, and `docs/coverage.md`
  from the MuJoCo headers this build is against.

      $ mix ex_mujoco.gen
      $ mix ex_mujoco.gen --check

  The headers come from the MuJoCo that `scripts/prepare_mujoco.exs` prepared, so
  the bindings and the library are always the same version. What is bound is
  `c_src/manifest.exs`; everything else the headers describe is written to
  `docs/coverage.md` as unbound, with the reason.

  `--check` writes nothing and exits non-zero when a generated file disagrees with
  what would be generated. CI runs it on every push, so a hand-edited generated
  file, or a MuJoCo version bump without a regeneration, fails the build rather
  than drifting.

  The output is committed: a package that generated its bindings at build time
  would need a generator on the machine that builds it, and would make two builds
  of the same version differ.
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: [check: :boolean])

    if invalid != [] or rest != [] do
      Mix.raise("usage: mix ex_mujoco.gen [--check]")
    end

    case ExMujoco.Gen.run(File.cwd!(), opts) do
      {:ok, []} ->
        Mix.shell().info("ex_mujoco: the bindings agree with the headers")

      {:ok, files} ->
        Mix.shell().info("ex_mujoco: regenerated #{length(files)} files")

        Enum.each(files, &Mix.shell().info("  #{&1}"))

      {:error, stale} ->
        Mix.raise("""
        ex_mujoco: these generated files disagree with the headers:

          #{Enum.join(stale, "\n  ")}

        Run `mix ex_mujoco.gen` and commit the result.
        """)
    end
  end
end
