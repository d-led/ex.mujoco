#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>

#include <mujoco/mujoco.h>

// Calling MuJoCo without aborting the VM.
//
// `mju_error` does not return: by default it prints and aborts the process, and
// a NIF that aborts takes the whole BEAM with it — every other process, in every
// other application on that node. MuJoCo offers a log handler precisely so that
// an embedder can decide what an error means, and its own Python bindings do
// what is done here: install a handler once, and while a call is in flight,
// `longjmp` back to the frame that made it.
//
// A C++ exception must not be thrown *through* MuJoCo's C frames — unwinding
// across them is undefined behaviour — which is why the jump is a `longjmp` and
// the exception is thrown on this side of it.
namespace exmujoco {

inline thread_local std::jmp_buf *jump_target = nullptr;

// The handler runs deep inside MuJoCo, and its message is gone by the time we
// are back, so it is copied here first.
inline thread_local char error_buffer[2048] = {0};

// Warnings and info are not ours to swallow: they go to whoever MuJoCo had
// installed before us, which is the console by default.
inline mjfLogHandler previous_handler = nullptr;

inline void log_handler(const mjLogMessage *message) {
  if (message == nullptr) {
    return;
  }

  if (message->level != mjLOG_ERROR) {
    if (previous_handler != nullptr) {
      previous_handler(message);
    }
    return;
  }

  if (message->func != nullptr) {
    std::snprintf(error_buffer, sizeof(error_buffer), "%s: %s", message->func,
                  message->subject);
  } else {
    std::snprintf(error_buffer, sizeof(error_buffer), "%s", message->subject);
  }

  if (jump_target != nullptr) {
    std::longjmp(*jump_target, 1);
  }

  // No guarded call is in flight. MuJoCo's contract is that an error does not
  // return, and codegen sends every entry point through call(), so this is
  // unreachable in practice — but aborting the VM is the one thing we must not
  // do, so say what happened and carry on.
  std::fprintf(stderr, "ex_mujoco: MuJoCo error outside a call: %s\n",
               error_buffer);
}

// Installed once, when the NIF is loaded.
inline void install_error_handler() {
  previous_handler = mju_setLogHandler(&log_handler);
}

// Runs one call into MuJoCo and turns its fatal error into a C++ exception,
// which Fine turns into an Elixir one.
//
// The lambda must not own anything with a destructor that matters: a `longjmp`
// does not unwind, so a `std::string` created inside it would leak. Decoded
// arguments live in the caller's frame, which is not unwound.
template <typename Function>
auto call(Function &&function) -> std::invoke_result_t<Function> {
  using Result = std::invoke_result_t<Function>;

  std::jmp_buf buffer;
  std::jmp_buf *previous = jump_target;

  if (setjmp(buffer) != 0) {
    jump_target = previous;
    throw std::runtime_error(std::string(error_buffer));
  }

  jump_target = &buffer;

  if constexpr (std::is_void_v<Result>) {
    function();
    jump_target = previous;
  } else {
    Result result = function();
    jump_target = previous;
    return result;
  }
}

}  // namespace exmujoco
