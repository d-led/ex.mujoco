defmodule ExMujoco.PackageTest do
  use ExUnit.Case, async: true

  # Everything the build reads out of the package directory. `mujoco.version` was
  # the one left out, and a dependency that cannot compile is not a package.
  @read_by_the_build %{
    "the project" => "mix.exs",
    "the pin" => "mujoco.version",
    "the version" => "VERSION",
    "the unix build" => "Makefile",
    "the windows build" => "Makefile.win"
  }

  @directories_the_build_needs ~w(lib c_src scripts)

  test "the package ships every file the build reads" do
    entries = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

    for {what, file} <- @read_by_the_build do
      assert file in entries, "#{what} is read by the build, and #{file} is not in package files"
    end

    for directory <- @directories_the_build_needs do
      assert directory in entries, "#{directory} is built from, and it is not in package files"
    end
  end
end
