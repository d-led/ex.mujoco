// An offscreen OpenGL context, when the machine has one.
//
// MuJoCo's renderer (`mjr_*`) draws into whatever OpenGL context is current, and
// it makes no context of its own — its own Python bindings create one through
// CGL on macOS, EGL or OSMesa on Linux and WGL on Windows. This is the same job
// done here: one context per process, held for the length of a render.
//
// Nothing is linked. The platform's OpenGL library is opened with `dlopen` when
// a renderer is first asked for, so a machine with no GL — a container, a CI
// runner without EGL, a platform this file does not carry — still loads this
// package and runs everything that does not render. MuJoCo's own glad loader
// then finds the same library by itself, which is how `mjr_makeContext` works at
// all when nothing links OpenGL.
//
// A GL context belongs to the thread that made it current, and the BEAM runs
// successive NIF calls on whichever scheduler is free — so every render makes it
// current again. Two renderers stepping at once would otherwise share one
// context, which is why a `Session` is a lock as well as a context: it is held
// from the first GL call to the last.

#pragma once

#include <mutex>
#include <string>

namespace exmujoco {
namespace gl {

// Whether an offscreen context can be made. The answer is memoised: the platform
// library is opened once, and a machine without one will not grow one while the
// VM runs.
//
// `reason` is filled in when the answer is false, in words a caller can show.
bool available(std::string *reason);

// One render's use of the context: it is current on this thread for as long as
// the session lives, and nothing else renders meanwhile. Throws
// `std::runtime_error` naming what is missing when there is no context.
class Session {
 public:
  Session();
  ~Session();

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

 private:
  std::unique_lock<std::mutex> lock_;
};

}  // namespace gl
}  // namespace exmujoco
