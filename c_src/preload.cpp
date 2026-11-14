// The one thing that has to happen before the NIF that wraps MuJoCo can be
// loaded, on Windows.
//
// Windows resolves a library's imports against the modules already in the
// process and against the search path — never against the directory of the
// library doing the importing. `mujoco.dll` sits beside `ex_mujoco_nif.dll` and
// is still reported as "the specified module could not be found".
//
// This library imports nothing but the C runtime, so it always loads; loading
// MuJoCo from it, by the full path `priv` gives it, is what puts MuJoCo on the
// list the next load consults. Nowhere else needs the help: a shared library on
// macOS or Linux names its own dependencies, and finds them beside itself.
//
// It is a separate library rather than a NIF in the main one because the main
// one cannot be loaded before this has run.

#include <fine.hpp>

#include <string>

#ifdef _WIN32
#include <windows.h>
#endif

namespace exmujoco {

namespace {

#ifdef _WIN32

// Paths reach a NIF as UTF-8 and reach Win32 as UTF-16. A directory name is
// allowed to be anything the user's language can spell.
std::wstring widen(const std::string &utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }

  const int size = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);

  if (size <= 0) {
    return std::wstring();
  }

  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), size);

  return wide;
}

#endif

}  // namespace

// Answers with what went wrong, or with an empty string when MuJoCo is in the
// process. A message rather than a raised exception, because this runs from
// `@on_load`: raising there leaves the caller with no module and no reason.
std::string load_mujoco(ErlNifEnv *env, std::string path) {
  (void)env;

#ifdef _WIN32
  if (::LoadLibraryW(widen(path).c_str()) == nullptr) {
    return "could not load " + path + ": error " +
           std::to_string(::GetLastError());
  }
#else
  (void)path;
#endif

  return "";
}

FINE_NIF(load_mujoco, 0);

}  // namespace exmujoco

FINE_INIT("Elixir.ExMujoco.Preload");
