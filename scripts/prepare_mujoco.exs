# Prepare MuJoCo, the three ways there are.
#
#   elixir scripts/prepare_mujoco.exs --print-dir
#   elixir scripts/prepare_mujoco.exs --ensure [--priv DIR]
#
# `--print-dir` answers one question and touches nothing: which directory holds
# the MuJoCo this build compiles and links against. The Makefiles ask it at parse
# time to fill `MUJOCO_DIR`.
#
# `--ensure` makes that directory complete, then copies the shared library into
# `--priv` so the NIF finds it at run time. It is idempotent and cheap when
# everything is already in place, which is why the Makefiles run it on every
# build.
#
# Where MuJoCo comes from, in this order:
#
#   1. `MUJOCO_DIR` — the caller's own install: Conan, vcpkg, a system package, a
#      build of their own. Taken as is; nothing is downloaded or built.
#   2. `EX_MUJOCO_SOURCE_DIR` — a MuJoCo checkout on disk, built with CMake.
#   3. `EX_MUJOCO_SOURCE_REF`, or `EX_MUJOCO_BUILD` — the source at that ref
#      (`main` for latest, or any tag or commit), downloaded and built with
#      CMake. This is the "build latest" path.
#   4. otherwise the official release artifact for this machine, at the version
#      in `mujoco.version`, checked against the checksum published beside it.
#
# Nothing here needs Mix: the Makefiles call this with plain `elixir`.
defmodule PrepareMujoco do
  # The checksums MuJoCo publishes beside each artifact. A version that is not
  # in this table cannot be downloaded — pinning a release you have not checked
  # is not pinning. Adopting a release is two edits: `mujoco.version`, and the
  # numbers here. Or build from source, which needs no checksum because it builds
  # what it fetched.
  @releases %{
    "4.0.1" => %{
      {"linux", "x86_64"} => %{
        name: "mujoco-4.0.1-linux-x86_64.tar.gz",
        sha256: "8df1308b2900a4ed6c18717ebbc9d66d53ab3fe7a4da860a7d5b21f94607299d"
      },
      {"linux", "arm64"} => %{
        name: "mujoco-4.0.1-linux-aarch64.tar.gz",
        sha256: "e16dc0ed24d31279bce674bd03b9f8ef75f209d1189befe67b7c3b366978a6b3"
      },
      {"darwin", "universal"} => %{
        name: "mujoco-4.0.1-macos-universal2.dmg",
        sha256: "2616bb30cf48e5603e09f42ef7898e1302c2f99cdaaea650714f0fcfa3b57722"
      },
      {"win32", "x86_64"} => %{
        name: "mujoco-4.0.1-windows-x86_64.zip",
        sha256: "abe3104a2ae0ca18a4b50fa1e79aaf57699496c7ee78ec7214104a0d1593fc75"
      }
    },
    "3.13.0" => %{
      {"linux", "x86_64"} => %{
        name: "mujoco-3.13.0-linux-x86_64.tar.gz",
        sha256: "a01ab187aa017b3729f01bc2a8c05e56411fa0198a6ef26e7b8b93a3edbdc28e"
      },
      {"linux", "arm64"} => %{
        name: "mujoco-3.13.0-linux-aarch64.tar.gz",
        sha256: "b591c1f4c343f11112be769af89721b5d1cf5488533dcc103a4cf424e9f96fb4"
      },
      {"darwin", "universal"} => %{
        name: "mujoco-3.13.0-macos-universal2.dmg",
        sha256: "623bb99cdfdeb5a53ebb142e1c100b1cb548277c310a1d0f7d475e9447d7656c"
      },
      {"win32", "x86_64"} => %{
        name: "mujoco-3.13.0-windows-x86_64.zip",
        sha256: "333cc18cd471aa58442f27c347637540e5382b1970c4db1cab3e9283cf37f40a"
      }
    }
  }

  @release_base "https://github.com/google-deepmind/mujoco/releases/download"
  @source_base "https://github.com/google-deepmind/mujoco/archive/refs"

  # What the smallest useful MuJoCo build is: the library, and nothing that wants
  # a window. Turning studio off also keeps Filament, a long pinned dependency,
  # out of the build.
  @cmake_configure [
    "-DCMAKE_BUILD_TYPE=Release",
    "-DMUJOCO_BUILD_EXAMPLES=OFF",
    "-DMUJOCO_BUILD_TESTS=OFF",
    "-DMUJOCO_BUILD_SIMULATE=OFF",
    "-DMUJOCO_BUILD_STUDIO=OFF",
    "-DMUJOCO_TEST_PYTHON_UTIL=OFF",
    "-DMUJOCO_WITH_USD=OFF"
  ]

  def main(["--print-dir"]) do
    IO.puts(dir!())
  end

  def main(["--ensure" | rest]) do
    ensure!(dir!(), parse_priv(rest))
  end

  def main(_) do
    IO.puts(:stderr, """
    usage: elixir scripts/prepare_mujoco.exs --print-dir
           elixir scripts/prepare_mujoco.exs --ensure [--priv DIR]
    """)

    System.halt(2)
  end

  defp parse_priv(["--priv", dir]), do: dir
  defp parse_priv([]), do: nil
  defp parse_priv(_), do: main([])

  # ---------------------------------------------------------------- where

  defp dir! do
    managed = managed_dir!()

    case env("MUJOCO_DIR") do
      # `mix` reads this back out of us and hands it to the Makefile, which hands
      # it back here through the environment. A path that is ours stays ours to
      # fill; a path that is not is the caller's install, and is never written to.
      "" -> managed
      ^managed -> managed
      own -> Path.expand(own)
    end
  end

  defp caller_owned?(dir), do: dir != managed_dir!()

  defp managed_dir!, do: Path.join(cache_root!(), cache_key())

  defp cache_root! do
    case env("EX_MUJOCO_CACHE_DIR") do
      "" -> Path.join(project_dir!(), "_build/mujoco")
      dir -> Path.expand(dir)
    end
  end

  defp cache_key do
    base = "#{version!()}-#{platform()}-#{arch()}"

    if build_from_source?(),
      do: base <> "-" <> sanitise(source_ref() || version!()),
      else: base
  end

  defp sanitise(text), do: String.replace(text, ~r/[^A-Za-z0-9._-]/, "-")

  defp build_from_source? do
    env("EX_MUJOCO_SOURCE_DIR") != "" or env("EX_MUJOCO_SOURCE_REF") != "" or
      env("EX_MUJOCO_BUILD") != ""
  end

  defp source_ref do
    flag(env("EX_MUJOCO_SOURCE_REF")) || flag(env("EX_MUJOCO_BUILD"))
  end

  # A flag that can also carry a value: `EX_MUJOCO_SOURCE_REF=main`, and
  # `EX_MUJOCO_BUILD=1` meaning "build the pinned version".
  defp flag(""), do: nil
  defp flag("0"), do: nil
  defp flag("false"), do: nil
  defp flag("1"), do: nil
  defp flag("true"), do: nil
  defp flag(value), do: value

  defp version! do
    # `mujoco.version` is the single statement of the pin: `mix.exs` reads it for
    # the catalogue's provenance, this script reads it for the artifact, so a
    # bump is one edit.
    Path.join(project_dir!(), "mujoco.version") |> File.read!() |> String.trim()
  end

  defp platform do
    case :os.type() do
      {:unix, :darwin} ->
        "darwin"

      {:unix, :linux} ->
        "linux"

      {:win32, _} ->
        "win32"

      other ->
        raise """
        there is no MuJoCo release artifact for #{inspect(other)}.

        Set MUJOCO_DIR to a MuJoCo you built, or EX_MUJOCO_SOURCE_DIR to its source.
        """
    end
  end

  # The NIF is built for the Erlang running this, so Erlang's architecture is the
  # one that decides. An x86_64 Erlang under Rosetta takes the x86_64 slices, and
  # the macOS artifact is universal, so both work.
  defp arch do
    case :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd() do
      arch when arch in ["aarch64", "arm64", "arm64e"] -> "arm64"
      arch when arch in ["x86_64", "amd64"] -> "x86_64"
      other -> other
    end
  end

  defp project_dir!, do: Path.expand("..", __DIR__)

  # ---------------------------------------------------------------- ensure

  defp ensure!(dir, priv) do
    if complete?(dir) do
      note("MuJoCo at #{dir}")
    else
      cond do
        caller_owned?(dir) ->
          raise """
          MUJOCO_DIR is #{dir}, and it does not hold a MuJoCo to build against.

          It needs `include/mujoco/mujoco.h` and a library under `lib/`. Point it at a
          MuJoCo you built or installed, or leave MUJOCO_DIR unset and let this script
          obtain one.
          """

        build_from_source?() ->
          build_source!(dir)

        true ->
          install_release!(dir)
      end
    end

    if priv, do: stage(dir, priv)
    write_provenance(dir)
    :ok
  end

  defp complete?(dir) do
    File.exists?(Path.join(dir, "include/mujoco/mujoco.h")) and library?(dir)
  end

  defp library?(dir) do
    case platform() do
      "win32" -> File.exists?(Path.join(dir, "lib/mujoco.lib"))
      _ -> match?([_ | _], Path.wildcard(Path.join(dir, "lib/libmujoco.*")))
    end
  end

  # ---------------------------------------------------------------- releases

  defp install_release!(dir) do
    version = version!()
    label = release_target() |> Tuple.to_list() |> Enum.join("-")

    case release_artifact() do
      # A release this table has not checked cannot be downloaded — and a pin
      # with no artifact is not a reason to refuse to build: it is a release
      # MuJoCo publishes no binary for on this platform, so the source at that
      # tag is the same MuJoCo. Asking for an env var to say so made a pinned
      # version unbuildable in CI, which is where it matters.
      nil ->
        note("MuJoCo #{version} publishes no artifact for #{label}; building it from source")
        build_source!(dir)

      artifact ->
        fetch_release!(dir, version, label, artifact)
    end
  end

  defp fetch_release!(dir, version, label, artifact) do
    note("Fetching MuJoCo #{version} for #{label}")
    File.mkdir_p!(dir)
    work = work_dir!("release")
    archive = Path.join(work, artifact.name)

    try do
      download!("#{@release_base}/#{version}/#{artifact.name}", archive)
      verify!(archive, artifact.sha256, artifact.name)
      unpack!(archive, dir)
    after
      File.rm_rf!(work)
    end

    unless complete?(dir) do
      raise "the #{artifact.name} archive did not have the layout expected of it"
    end

    note("MuJoCo #{version} is in #{dir}")
  end

  defp unpack!(archive, dir) do
    case Path.extname(archive) do
      ".gz" -> unpack_tarball!(archive, dir)
      ".zip" -> unpack_zip!(archive, dir)
      ".dmg" -> unpack_dmg!(archive, dir)
      other -> raise "do not know how to unpack a #{other} archive"
    end
  end

  defp unpack_zip!(archive, dir) do
    unpack = archive |> Path.dirname() |> Path.join("unpack")
    File.rm_rf!(unpack)
    File.mkdir_p!(unpack)
    unzip!(archive, unpack)
    root = archive_root(unpack)
    copy_tree!(Path.join(root, "include"), Path.join(dir, "include"))
    copy_tree!(Path.join(root, "lib"), Path.join(dir, "lib"))
    copy_tree!(Path.join(root, "bin"), Path.join(dir, "bin"))
    File.rm_rf!(unpack)
  end

  defp unpack_tarball!(archive, dir) do
    root = extract_tarball!(archive)
    copy_tree!(Path.join(root, "include"), Path.join(dir, "include"))
    copy_tree!(Path.join(root, "lib"), Path.join(dir, "lib"))
    File.rm_rf!(archive |> Path.dirname() |> Path.join("unpack"))
  end

  # Unpacks beside the archive and answers the one directory the tree is in.
  defp extract_tarball!(archive) do
    into = archive |> Path.dirname() |> Path.join("unpack")
    File.rm_rf!(into)
    File.mkdir_p!(into)
    run!(tar(), ["xf", archive, "-C", into])
    Path.join(into, hd(File.ls!(into)))
  end

  # An archive may hold one directory, or its contents directly: MuJoCo's
  # tarballs wrap everything in `mujoco-<version>/`, and its Windows zip does not
  # wrap at all.
  defp archive_root(into) do
    case File.ls!(into) do
      [only] ->
        candidate = Path.join(into, only)
        if File.dir?(candidate), do: candidate, else: into

      _several ->
        into
    end
  end

  defp unzip!(archive, into) do
    case :os.type() do
      # `tar` on Windows is bsdtar, which reads zip; `Expand-Archive` is slower
      # and says less when it fails.
      {:win32, _} -> run!(tar(), ["xf", archive, "-C", into])
      _ -> run!("unzip", ["-q", archive, "-d", into])
    end
  end

  # The macOS release is a disk image holding `mujoco.framework` and the simulator
  # app. The framework is what we want: its `Headers` are MuJoCo's flat header
  # set, and its dylib is signed with an `@rpath/mujoco.framework/...` install
  # name, which we keep — rewriting the id of a signed dylib is exactly what makes
  # it refuse to load on Apple Silicon.
  defp unpack_dmg!(archive, dir) do
    mount = Path.join(Path.dirname(archive), "mount")
    File.mkdir_p!(mount)

    try do
      run!("hdiutil", [
        "attach",
        "-nobrowse",
        "-readonly",
        "-mountpoint",
        mount,
        archive,
        "-quiet"
      ])

      framework = Path.join(mount, "mujoco.framework")
      unless File.dir?(framework), do: raise("#{archive} holds no mujoco.framework")

      # `Versions/A` is the whole framework: the dylib, its Resources, its headers.
      copy_tree!(Path.join(framework, "Versions"), Path.join(dir, "framework/Versions"))

      # `#include <mujoco/mjmodel.h>` has to resolve, and a framework keeps its
      # headers flat in `Versions/A/Headers`. One symlink serves both spellings.
      File.mkdir_p!(Path.join(dir, "include"))
      File.ln_s!(Path.join(dir, "framework/Versions/A/Headers"), Path.join(dir, "include/mujoco"))

      File.mkdir_p!(Path.join(dir, "lib"))

      for dylib <- Path.wildcard(Path.join(dir, "framework/Versions/A/libmujoco.*.dylib")) do
        File.ln_s!(dylib, Path.join([dir, "lib", Path.basename(dylib)]))

        # `-lmujoco` looks for `libmujoco.dylib`; the file it finds records its
        # own `@rpath/mujoco.framework/...` name in whatever links against it,
        # which is the name we then have to satisfy at run time.
        File.ln_s!(Path.basename(dylib), Path.join([dir, "lib", "libmujoco.dylib"]))
      end
    after
      System.cmd("hdiutil", ["detach", mount], stderr_to_stdout: true)
      File.rm_rf!(Path.dirname(mount))
    end
  end

  # ---------------------------------------------------------------- source

  defp build_source!(dir) do
    work = work_dir!("source")
    build = Path.join(work, "build")

    note("Building MuJoCo from #{source_description!()} (a few minutes)")

    try do
      source = source_dir!(work)
      config = if platform() == "win32", do: ["--config", "Release"], else: []

      run!(
        "cmake",
        ["-S", source, "-B", build, "-DCMAKE_INSTALL_PREFIX=#{dir}" | @cmake_configure],
        clean_build_env()
      )

      run!(
        "cmake",
        ["--build", build, "--target", "mujoco", "--parallel", jobs() | config],
        clean_build_env()
      )

      run!("cmake", ["--install", build | config], clean_build_env())
    after
      File.rm_rf!(work)
    end

    unless complete?(dir) do
      raise "the CMake build installed no MuJoCo into #{dir}"
    end

    note("MuJoCo from source is in #{dir}")
  end

  defp source_description! do
    case env("EX_MUJOCO_SOURCE_DIR") do
      "" -> "mujoco/#{source_ref() || version!()}"
      dir -> dir
    end
  end

  defp source_dir!(work) do
    case env("EX_MUJOCO_SOURCE_DIR") do
      "" ->
        ref = source_ref() || version!()
        archive = Path.join(work, "source.tar.gz")

        url =
          if tag?(ref),
            do: "#{@source_base}/tags/#{ref}.tar.gz",
            else: "#{@source_base}/heads/#{ref}.tar.gz"

        download!(url, archive)
        extract_tarball!(archive)

      checkout ->
        unless File.exists?(Path.join(checkout, "CMakeLists.txt")) do
          raise "EX_MUJOCO_SOURCE_DIR is #{checkout}, and that is no MuJoCo source tree"
        end

        checkout
    end
  end

  defp tag?(ref), do: Regex.match?(~r/^\d+\.\d+\.\d+/, ref)

  defp jobs do
    case :erlang.system_info(:logical_processors_available) do
      :unknown -> "4"
      count -> to_string(max(1, count))
    end
  end

  defp work_dir!(kind) do
    dir = Path.join(System.tmp_dir!(), "ex_mujoco_#{kind}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  # ---------------------------------------------------------------- priv

  # The NIF records the library's own name as the thing to load, and that name
  # decides where the copy in `priv/` has to sit: `$ORIGIN` on Linux,
  # `@loader_path` on macOS, and on Windows the NIF's own directory, which OTP
  # searches because it loads NIFs with LOAD_WITH_ALTERED_SEARCH_PATH.
  defp stage(dir, priv) do
    File.mkdir_p!(priv)

    case platform() do
      "win32" -> copy!(Path.join(dir, "bin/mujoco.dll"), Path.join(priv, "mujoco.dll"))
      "darwin" -> stage_darwin(dir, priv)
      "linux" -> stage_linux(dir, priv)
    end
  end

  defp stage_linux(dir, priv) do
    files = Path.wildcard(Path.join(dir, "lib/libmujoco.so*"))
    real = Enum.reject(files, &symlink?/1)

    Enum.each(real, fn file -> copy!(file, Path.join(priv, Path.basename(file))) end)

    # `libmujoco.so` is a link to the versioned file in the release; keep it a
    # link rather than a second copy of the library.
    for link <- Enum.filter(files, &symlink?/1), real != [] do
      target = Path.join(priv, Path.basename(link))

      unless File.exists?(target) or symlink?(target),
        do: File.ln_s!(Path.basename(hd(real)), target)
    end
  end

  defp stage_darwin(dir, priv) do
    framework = Path.join(dir, "framework")

    if File.dir?(framework) do
      # The dylib keeps the install name it was signed with, so it has to keep
      # the path that name describes. Nothing else in the framework is needed to
      # load it.
      [dylib] = Path.wildcard(Path.join(framework, "Versions/A/libmujoco.*.dylib"))
      target = Path.join(priv, "mujoco.framework/Versions/A")
      copy!(dylib, Path.join(target, Path.basename(dylib)))

      resources = Path.join(framework, "Versions/A/Resources")

      unless File.dir?(Path.join(target, "Resources")),
        do: File.cp_r!(resources, Path.join(target, "Resources"))
    else
      # A source build names itself `@rpath/libmujoco.<v>.dylib`, so the file sits
      # directly in priv and `@loader_path` finds it.
      [dylib] = Path.wildcard(Path.join(dir, "lib/libmujoco.*.dylib"))
      copy!(dylib, Path.join(priv, install_name!(dylib)))
    end
  end

  # `@rpath/libmujoco.4.0.2.dylib` -> `libmujoco.4.0.2.dylib`.
  defp install_name!(dylib) do
    {out, 0} = System.cmd("otool", ["-D", dylib])
    out |> String.split("\n") |> Enum.at(1) |> String.trim() |> Path.basename()
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  defp copy!(from, to) do
    File.mkdir_p!(Path.dirname(to))
    unless File.exists?(to), do: File.cp!(from, to)
  end

  defp copy_tree!(from, to) do
    File.mkdir_p!(Path.dirname(to))

    case File.cp_r(from, to) do
      {:ok, _files} -> :ok
      {:error, reason, file} -> raise "could not copy #{file}: #{:file.format_error(reason)}"
    end
  end

  # ---------------------------------------------------------------- provenance

  # Where the physics came from, in a file, so the next person does not have to
  # read this script to find out.
  defp write_provenance(dir) do
    provider = provider(dir)

    lines =
      [
        "version=#{version!()}",
        "header_version=#{header_version!(dir)}",
        "platform=#{platform()}",
        "arch=#{arch()}",
        "provider=#{provider}"
      ] ++
        artifact_lines(provider) ++ ["prepared_at=#{DateTime.utc_now() |> DateTime.to_iso8601()}"]

    File.write!(Path.join(dir, ".provider"), Enum.join(lines, "\n") <> "\n")
  end

  # A version and a checksum, because for a binary nobody here built, the
  # checksum is the claim that can be checked: it names the bytes. There is
  # nothing to name when MuJoCo came from a checkout or from source.
  defp artifact_lines("release=" <> _) do
    case release_artifact() do
      nil -> []
      artifact -> ["artifact=#{artifact.name}", "artifact_sha256=#{artifact.sha256}"]
    end
  end

  defp artifact_lines(_provider), do: []

  # The platform MuJoCo publishes for: macOS ships one universal build.
  defp release_target do
    {platform(), if(platform() == "darwin", do: "universal", else: arch())}
  end

  defp release_artifact do
    @releases |> Map.get(version!(), %{}) |> Map.get(release_target())
  end

  defp provider(dir) do
    cond do
      caller_owned?(dir) -> "MUJOCO_DIR=#{dir}"
      env("EX_MUJOCO_SOURCE_DIR") != "" -> "source=#{Path.expand(env("EX_MUJOCO_SOURCE_DIR"))}"
      build_from_source?() -> "source=mujoco/#{source_ref() || version!()}"
      true -> "release=#{version!()}"
    end
  end

  defp header_version!(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "include/mujoco/mujoco.h")),
         [_, number] <- Regex.run(~r/#define mjVERSION_HEADER (\d+)/, text) do
      number
    else
      _ -> "unknown"
    end
  end

  # ---------------------------------------------------------------- plumbing

  defp env(name), do: System.get_env(name) || ""

  defp note(message), do: IO.puts("ex_mujoco: #{message}")

  defp download!(url, path) do
    note("Downloading #{url}")

    if curl?() do
      run!("curl", ["-fL", "--retry", "3", "--silent", "--show-error", "-o", path, url])
    else
      download_with_httpc!(url, path)
    end

    unless File.exists?(path) and File.stat!(path).size > 0 do
      raise "downloading #{url} produced no file"
    end
  end

  defp curl? do
    match?({_, 0}, System.cmd("curl", ["--version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp download_with_httpc!(url, path) do
    Enum.each([:inets, :ssl], fn app ->
      {:ok, _} = Application.ensure_all_started(app)
    end)

    options = [
      autoredirect: true,
      stream: {:file, String.to_charlist(path)},
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    case :httpc.request(:get, {String.to_charlist(url), []}, [], options) do
      {:ok, :saved_to_file} -> :ok
      {:ok, other} -> raise "downloading #{url}: unexpected #{inspect(other)}"
      {:error, reason} -> raise "downloading #{url}: #{inspect(reason)}"
    end
  end

  defp verify!(path, expected, name) do
    actual = sha256!(path)

    unless actual == expected do
      raise """
      #{name} does not match the checksum published beside it.

        expected #{expected}
        actual   #{actual}

      The download is not what MuJoCo released. Nothing was built.
      """
    end
  end

  defp sha256!(path) do
    digest =
      path
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    Base.encode16(digest, case: :lower)
  end

  # Windows ships a `tar` of its own — bsdtar, which reads zip — and Git for
  # Windows puts a GNU `tar` ahead of it on PATH. GNU tar reads `C:\...` as a
  # remote host and answers "Cannot connect to C: resolve failed", so the one
  # Windows ships is named, and PATH is the fallback.
  defp tar do
    case :os.type() do
      {:win32, _} ->
        system = Path.join(System.get_env("SystemRoot") || "C:\\Windows", "System32/tar.exe")
        if File.exists?(system), do: system, else: "tar"

      _ ->
        "tar"
    end
  end

  defp run!(command, args, options \\ []) do
    case System.cmd(command, args, [stderr_to_stdout: true] ++ options) do
      {_out, 0} ->
        :ok

      {out, code} ->
        raise "#{command} exited with #{code}\n\n#{out}"
    end
  rescue
    error in ErlangError ->
      missing!(command, error, __STACKTRACE__)
  end

  # MuJoCo's own build is not the NIF's build. ElixirMake exports `CFLAGS`,
  # `CPPFLAGS` and `LDFLAGS` — with this project's `-lmujoco` among them — for
  # the Makefile that compiles the bindings, and a `cmake` started underneath
  # inherits them: CMake's first test compile is handed `-L<mujoco-dir> -lmujoco`
  # before any MuJoCo exists, and the configure step fails with `ld: library
  # 'mujoco' not found`. A source build therefore never worked through `mix`,
  # only by hand from a shell that had not exported them.
  defp clean_build_env do
    [env: [{"CFLAGS", ""}, {"CPPFLAGS", ""}, {"CXXFLAGS", ""}, {"LDFLAGS", ""}]]
  end

  # A tool that is not installed is a sentence, not a stack trace.
  defp missing!(command, %ErlangError{original: :enoent}, _stacktrace) do
    raise """
    `#{command}` is not on PATH, and it is needed to #{needs(command)}.

    Install it, or point MUJOCO_DIR at a MuJoCo you already have.
    """
  end

  defp missing!(_command, error, stacktrace), do: reraise(error, stacktrace)

  defp needs("cmake"), do: "build MuJoCo from source"
  defp needs("tar"), do: "unpack the MuJoCo release"
  defp needs("unzip"), do: "unpack the MuJoCo release"
  defp needs("hdiutil"), do: "mount the MuJoCo disk image"
  defp needs("curl"), do: "download the MuJoCo release"
  defp needs(_), do: "prepare MuJoCo"
end

PrepareMujoco.main(System.argv())
