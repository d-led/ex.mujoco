defmodule ExMujoco.MixProject do
  use Mix.Project

  @version "0.1.8"
  @source_url "https://github.com/d-led/ex.mujoco"

  # The MuJoCo version this package is built against. The headers of exactly this
  # release are what `mix ex_mujoco.gen` parses into the committed catalogue, and
  # the library of exactly this release is what `scripts/prepare_mujoco.exs`
  # fetches or builds. `ExMujoco.header_version/0` and `ExMujoco.version/0` are
  # compared at load time, so a stale `priv/` library cannot quietly step a
  # different physics.
  @mujoco_version __DIR__
                  |> Path.join("mujoco.version")
                  |> File.read!()
                  |> String.trim()

  # `__DIR__`, not `File.cwd!/0`: a Hex dependency is compiled with its own
  # directory as the working directory, and that must not change where the
  # MuJoCo cache lives.
  @project_dir __DIR__

  def project do
    [
      app: :ex_mujoco,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_executable: make_executable(),
      make_env: &make_env/0,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      name: "ExMujoco",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    # A library, not an application: nothing to start, and the only thing this
    # code calls is `Logger`.
    [extra_applications: [:logger]]
  end

  # `Makefile` and `Makefile.win` are two files, not one file with `if`s: the
  # Windows one is `cl` and `nmake`, which is the toolchain an Elixir install on
  # Windows already has.
  defp make_executable do
    case :os.type() do
      {:win32, _} -> "nmake"
      _ -> "make"
    end
  end

  defp deps do
    [
      # The NIF is C++ over MuJoCo; Fine supplies the encoders, the resource
      # type and the NIF registration, elixir_make runs the compiler.
      {:fine, "~> 0.2.0", runtime: false},
      {:elixir_make, "~> 0.10", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  # Everything the Makefile needs to know, decided once, here.
  #
  # `MUJOCO_DIR` is either the caller's own install — Conan, vcpkg, a build of
  # their own — or the directory `scripts/prepare_mujoco.exs` fills. The script
  # answers where that is, so there is one implementation of the rule and no
  # second copy of it in `mix.exs` to drift. `--print-dir` only reads
  # `mujoco.version` and the environment: asking it is not a side effect.
  defp make_env do
    %{
      "FINE_INCLUDE_DIR" => Fine.include_dir(),
      "EX_MUJOCO_PROJECT_DIR" => @project_dir,
      "EX_MUJOCO_VERSION" => @mujoco_version,
      "MUJOCO_DIR" => mujoco_dir()
    }
  end

  defp mujoco_dir do
    {dir, 0} =
      System.cmd("elixir", [Path.join(@project_dir, "scripts/prepare_mujoco.exs"), "--print-dir"])

    String.trim(dir)
  end

  defp description do
    "MuJoCo physics from Elixir: models, data, the state and every field of " <>
      "them, through a compile-time generated Fine NIF. PyTorch-free, Python-free."
  end

  defp package do
    [
      # `mujoco.version` ships because the build reads it, both here and in
      # `scripts/prepare_mujoco.exs`; without it a dependency cannot compile.
      files: ~w(lib c_src Makefile Makefile.win scripts docs mix.exs VERSION
                mujoco.version README.md CHANGELOG.md LICENSE NOTICE .formatter.exs),
      licenses: ["MPL-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Dmitry Ledentsov"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/plan.md",
        "docs/building.md",
        "docs/coverage.md",
        "docs/development.md"
      ],
      # A group per thing a reader came for. The two patterns are regular
      # expressions on the module's own name: eighty-odd `ExMujoco.Types.*`
      # modules are one group, and the generator's modules are not loose among
      # the API a caller came for.
      groups_for_modules: [
        Physics: [ExMujoco, ExMujoco.Model, ExMujoco.Data, ExMujoco.Tensor],
        "The C API": [ExMujoco.Api],
        Types: ~r/^ExMujoco\.Types(\.|$)/,
        Errors: [ExMujoco.Error, ExMujoco.Loader],
        "Generating the bindings": ~r/^ExMujoco\.Gen(\.|$)/
      ]
    ]
  end
end
