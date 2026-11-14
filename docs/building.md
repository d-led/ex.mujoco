# Building

The library this package calls is a shared object the NIF loads, so building `ex_mujoco`
means three things: get a MuJoCo, compile the NIF against its headers, and put the library
where the NIF will look for it at run time. One script does all three, and one directory is
the answer to all three.

## The directory

```
<MUJOCO_DIR>/include/mujoco/*.h          the headers every binding is generated from
<MUJOCO_DIR>/lib/libmujoco.so.4.0.1     linux             (and the libmujoco.so link)
<MUJOCO_DIR>/lib/libmujoco.4.0.1.dylib  macOS source build
<MUJOCO_DIR>/framework/Versions/A/…     macOS release (mujoco.framework)
<MUJOCO_DIR>/lib/mujoco.lib             windows           (import library)
<MUJOCO_DIR>/bin/mujoco.dll             windows           (the runtime DLL)
```

`scripts/prepare_mujoco.exs` fills it, and `elixir scripts/prepare_mujoco.exs --print-dir`
says where it is. `mix.exs` asks the same script, so the Makefile and the generator cannot
disagree about it.

## The four ways to fill it

Tried in this order.

### 1. `MUJOCO_DIR` — your own

`MUJOCO_DIR=/opt/mujoco mix compile`. Nothing is downloaded, nothing is built, and nothing
inside your directory is written to. Use it for Conan, vcpkg, a system package, a build of
your own, or an air-gapped CI. If the directory does not hold a MuJoCo, the build stops and
says what it wanted to find.

Neither Conan Center nor vcpkg ships current MuJoCo — at the time of writing they are 3.14
and 3.10 against upstream's 4.0.1, and both patch the tree to externalise vendored
dependencies, so neither is an upstream build. That is why they are an escape hatch here and
not a default.

### 2. `EX_MUJOCO_SOURCE_DIR` — a checkout

`EX_MUJOCO_SOURCE_DIR=~/src/mujoco mix compile`, for when you are working on MuJoCo itself or
have a clone you trust. It is built with CMake like the next case.

### 3. `EX_MUJOCO_SOURCE_REF` — build the latest

```console
$ EX_MUJOCO_SOURCE_REF=main mix compile
$ EX_MUJOCO_SOURCE_REF=4.0.2 mix compile
```

This is how to bind a MuJoCo that this package does not pin. The source archive comes from
`github.com/google-deepmind/mujoco/archive/refs/{heads,tags}/<ref>.tar.gz`, and is built with:

```console
cmake -S <source> -B <build> -DCMAKE_BUILD_TYPE=Release \
  -DMUJOCO_BUILD_EXAMPLES=OFF -DMUJOCO_BUILD_TESTS=OFF \
  -DMUJOCO_BUILD_SIMULATE=OFF -DMUJOCO_BUILD_STUDIO=OFF \
  -DMUJOCO_TEST_PYTHON_UTIL=OFF -DMUJOCO_WITH_USD=OFF
cmake --build <build> --target mujoco --parallel <n>
cmake --install <build>
```

Studio off also keeps Filament — a long, pinned dependency — out of the build. On this machine
a clean build is about a minute of configuration and three of compilation; the result is
cached in `_build/mujoco/<version>-<platform>-<arch>-source-<ref>/` and not rebuilt.

A source build needs CMake on `PATH`. Nothing else beyond the C++ compiler the NIF wants.

### 4. the pinned release — the default

```console
$ mix compile
ex_mujoco: Fetching MuJoCo 4.0.1 for darwin-universal
```

The official artifact for the host, verified against the `.sha256` MuJoCo publishes beside it:

| platform | artifact | contains |
| --- | --- | --- |
| linux x86_64, aarch64 | `mujoco-<v>-linux-<arch>.tar.gz` | `include/`, `lib/libmujoco.so*` |
| macOS universal2 | `mujoco-<v>-macos-universal2.dmg` | `mujoco.framework` |
| windows x86_64 | `mujoco-<v>-windows-x86_64.zip` | `include/`, `lib/mujoco.lib`, `bin/mujoco.dll` |

A version that is not in the checksum table in `scripts/prepare_mujoco.exs` cannot be
downloaded on purpose: pinning a release nobody checked is not pinning. Adopting one is two
edits — `mujoco.version`, and the published checksum — or a source build, which needs no
checksum because it compiles what it fetched.

The download goes to `<project>/_build/mujoco/<version>-<platform>-<arch>/`; set
`EX_MUJOCO_CACHE_DIR` to keep it somewhere shared.

## Where the shared library goes, and why there

The NIF records the library's own name as the thing to load, so the copy in `priv/` has to sit
where the loader will look:

* **Linux** — `priv/libmujoco.so.4.0.1`, found through `-Wl,-rpath,'$ORIGIN'`: the NIF's own
  directory.
* **macOS** — the release dylib's install name is
  `@rpath/mujoco.framework/Versions/A/libmujoco.4.0.1.dylib` and it is code-signed. Rewriting
  the id of a signed dylib is what makes it refuse to load on Apple Silicon, so the path is
  kept: the file is copied to `priv/mujoco.framework/Versions/A/`, and `@loader_path` supplies
  the `@rpath`. A source build names itself `@rpath/libmujoco.<v>.dylib` and sits directly in
  `priv/`.
* **Windows** — `priv/mujoco.dll`, and being in `priv/` is not enough on its own. Windows
  resolves a library's imports against the modules already in the process and against the
  search path, never against the directory of the library doing the importing, so
  `ex_mujoco_nif.dll` reported "the specified module could not be found" with `mujoco.dll`
  sitting right beside it. `priv/ex_mujoco_preload.dll` is the answer: it imports nothing but
  the C runtime, so it always loads, and `ExMujoco.Preload` calls it with the full path before
  `ExMujoco.Native` asks for the NIF. Nothing has to be on `PATH`, and no environment variable
  has to be set before the virtual machine starts.

  `mujoco.dll` itself imports the Visual C++ runtime — `MSVCP140.dll`, `VCRUNTIME140.dll` and
  the Universal CRT — which is MuJoCo's own requirement on Windows and ships with Visual Studio
  and with the [Microsoft Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe).
  A machine without it says so now, naming the DLL and the loader's error code.

## The version check

`mjVERSION_HEADER` is baked into the NIF; `mj_version()` is what the library answers. They are
compared on first use, and a mismatch raises rather than stepping a different physics:

```
ex_mujoco: the MuJoCo library in priv/ is 4.0.0 (4000000), and the headers the NIF was
generated from are 4.0.1 (4000001).
```

It is asked on first use rather than at load because `:erlang.load_nif` happens inside
`ExMujoco.Native`'s `@on_load`, and a module cannot call itself while it is loading.

## Tools

| | |
| --- | --- |
| `make` / `nmake` | the NIF, from `Makefile` / `Makefile.win` |
| `elixir` | `scripts/prepare_mujoco.exs`, the fetch and the CMake build |
| `curl` | the download (falls back to `:httpc` when it is absent) |
| `tar`, `unzip`, `hdiutil` | unpacking, per platform |
| `cmake` | only for a source build |

Windows uses MSVC through `nmake`, which is what an Elixir install on Windows already has.
`Makefile.win` is Fine's own example with the MuJoCo link added.

## Regenerating the bindings

```console
$ mix ex_mujoco.gen          # rewrite the generated files
$ mix ex_mujoco.gen --check  # exit non-zero when they disagree with the headers
```

The generated files are committed. A package that generated its bindings at build time would
need the generator on the machine that builds it, and two builds of the same version could
differ. `--check` is what CI runs, so a hand-edited generated file — or a MuJoCo bump without a
regeneration — fails the build instead of drifting.
