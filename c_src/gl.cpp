// An offscreen OpenGL context: CGL on macOS, EGL on Linux, and a sentence on
// everything else. See `gl.hpp` for why nothing is linked and why the context is
// made current, and held, for the length of a render.

#include "gl.hpp"

#include <dlfcn.h>

#include <mutex>
#include <stdexcept>

namespace exmujoco {
namespace gl {
namespace {

#if defined(__APPLE__)

// Apple's CGL, declared here rather than included: `<OpenGL/OpenGL.h>` would tie
// the build to an SDK path, and there is nothing in it this file needs that is
// not a pointer and an int. These are the same declarations MuJoCo's own Python
// bindings make (`python/mujoco/cgl/`), and the same attributes.
using CGLPixelFormatObj = void *;
using CGLContextObj = void *;
using CGLError = int;
using GLint = int;

constexpr int kOpenGLProfile = 99;   // CGLPFAOpenGLProfile
constexpr int kProfileLegacy = 0x1000;  // CGLOGLPVersion_Legacy
constexpr int kColorSize = 8;        // CGLPFAColorSize
constexpr int kAlphaSize = 11;       // CGLPFAAlphaSize
constexpr int kDepthSize = 12;       // CGLPFADepthSize
constexpr int kStencilSize = 13;     // CGLPFAStencilSize
constexpr int kMultisample = 59;     // CGLPFAMultisample
constexpr int kSampleBuffers = 55;   // CGLPFASampleBuffers
constexpr int kSample = 56;          // CGLPFASample
constexpr int kAccelerated = 73;     // CGLPFAAccelerated

struct Platform {
  void *library = nullptr;
  CGLError (*choose_pixel_format)(const int *, CGLPixelFormatObj *, GLint *) = nullptr;
  CGLError (*create_context)(CGLPixelFormatObj, CGLContextObj, CGLContextObj *) = nullptr;
  CGLError (*set_current)(CGLContextObj) = nullptr;

  bool open(std::string *reason) {
    library =
        ::dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW | RTLD_LOCAL);

    if (library == nullptr) {
      *reason = "this machine has no OpenGL framework: " + std::string(::dlerror());
      return false;
    }

    choose_pixel_format = reinterpret_cast<decltype(choose_pixel_format)>(
        ::dlsym(library, "CGLChoosePixelFormat"));
    create_context =
        reinterpret_cast<decltype(create_context)>(::dlsym(library, "CGLCreateContext"));
    set_current = reinterpret_cast<decltype(set_current)>(::dlsym(library, "CGLSetCurrentContext"));

    if (choose_pixel_format == nullptr || create_context == nullptr || set_current == nullptr) {
      *reason = "the OpenGL framework carries no CGL context calls";
      return false;
    }

    return true;
  }

  CGLContextObj make(std::string *reason) {
    const int attributes[] = {
        kOpenGLProfile, kProfileLegacy, kColorSize,     24,           kAlphaSize,
        8,              kDepthSize,    24,             kStencilSize, 8,
        kMultisample,   kSampleBuffers, 1,              kSample,      4,
        kAccelerated,   0,
    };

    CGLPixelFormatObj format = nullptr;
    GLint formats = 0;

    if (choose_pixel_format(attributes, &format, &formats) != 0 || format == nullptr) {
      *reason = "no accelerated OpenGL pixel format is available here";
      return nullptr;
    }

    CGLContextObj context = nullptr;

    if (create_context(format, nullptr, &context) != 0 || context == nullptr) {
      *reason = "an OpenGL context could not be created here";
      return nullptr;
    }

    return context;
  }

  void current(CGLContextObj context) { set_current(context); }
};

#elif defined(__linux__)

// EGL, declared here for the same reason: `<EGL/egl.h>` is a package a machine
// that never renders should not need.
using EGLDisplay = void *;
using EGLConfig = void *;
using EGLContext = void *;
using EGLSurface = void *;
using EGLint = int;
using EGLBoolean = unsigned int;
using EGLenum = unsigned int;

constexpr EGLint kNone = 0x3038;
constexpr EGLint kSurfaceType = 0x3033;
constexpr EGLint kPbufferBit = 0x0001;
constexpr EGLint kRenderableType = 0x3040;
constexpr EGLint kOpenGLBit = 0x0008;
constexpr EGLint kWidth = 0x3057;
constexpr EGLint kHeight = 0x3056;
constexpr EGLenum kOpenGLApi = 0x30A2;
constexpr EGLint kPlatformSurfacelessMesa = 0x31DD;

struct Platform {
  void *library = nullptr;
  EGLDisplay display = nullptr;
  EGLSurface surface = nullptr;

  EGLDisplay (*get_display)(void *) = nullptr;
  EGLDisplay (*get_platform_display)(EGLenum, void *, const EGLint *) = nullptr;
  EGLBoolean (*initialize)(EGLDisplay, EGLint *, EGLint *) = nullptr;
  EGLBoolean (*bind_api)(EGLenum) = nullptr;
  EGLBoolean (*choose_config)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *) = nullptr;
  EGLContext (*create_context)(EGLDisplay, EGLConfig, EGLContext, const EGLint *) = nullptr;
  EGLSurface (*create_pbuffer)(EGLDisplay, EGLConfig, const EGLint *) = nullptr;
  EGLBoolean (*make_current)(EGLDisplay, EGLSurface, EGLSurface, EGLContext) = nullptr;
  void *(*get_proc_address)(const char *) = nullptr;

  bool open(std::string *reason) {
    for (const char *name : {"libEGL.so.1", "libEGL.so"}) {
      library = ::dlopen(name, RTLD_NOW | RTLD_LOCAL);

      if (library != nullptr) {
        break;
      }
    }

    if (library == nullptr) {
      *reason = "this machine has no libEGL: " + std::string(::dlerror());
      return false;
    }

    get_display = reinterpret_cast<decltype(get_display)>(::dlsym(library, "eglGetDisplay"));
    initialize = reinterpret_cast<decltype(initialize)>(::dlsym(library, "eglInitialize"));
    bind_api = reinterpret_cast<decltype(bind_api)>(::dlsym(library, "eglBindAPI"));
    choose_config = reinterpret_cast<decltype(choose_config)>(::dlsym(library, "eglChooseConfig"));
    create_context = reinterpret_cast<decltype(create_context)>(::dlsym(library, "eglCreateContext"));
    create_pbuffer =
        reinterpret_cast<decltype(create_pbuffer)>(::dlsym(library, "eglCreatePbufferSurface"));
    make_current = reinterpret_cast<decltype(make_current)>(::dlsym(library, "eglMakeCurrent"));
    get_proc_address =
        reinterpret_cast<decltype(get_proc_address)>(::dlsym(library, "eglGetProcAddress"));

    if (get_display == nullptr || initialize == nullptr || bind_api == nullptr ||
        choose_config == nullptr || create_context == nullptr || create_pbuffer == nullptr ||
        make_current == nullptr) {
      *reason = "libEGL carries no offscreen rendering calls";
      return false;
    }

    // The surfaceless platform is what a machine with no display server has; it
    // comes through an extension, so it is asked for by name, and the default
    // display is the fallback for a desktop machine that lacks it.
    if (get_proc_address != nullptr) {
      get_platform_display = reinterpret_cast<decltype(get_platform_display)>(
          get_proc_address("eglGetPlatformDisplayEXT"));
    }

    if (get_platform_display != nullptr) {
      display = get_platform_display(kPlatformSurfacelessMesa, nullptr, nullptr);
    }

    if (display == nullptr) {
      display = get_display(nullptr);
    }

    EGLint major = 0;
    EGLint minor = 0;

    if (display == nullptr || !initialize(display, &major, &minor)) {
      *reason = "EGL could not open a display here";
      return false;
    }

    return true;
  }

  EGLContext make(std::string *reason) {
    if (!bind_api(kOpenGLApi)) {
      *reason = "EGL has no OpenGL API here";
      return nullptr;
    }

    const EGLint config_attributes[] = {kSurfaceType, kPbufferBit, kRenderableType, kOpenGLBit,
                                        kNone};
    EGLConfig config = nullptr;
    EGLint configs = 0;

    if (!choose_config(display, config_attributes, &config, 1, &configs) || configs == 0) {
      *reason = "EGL has no offscreen OpenGL configuration here";
      return nullptr;
    }

    EGLContext context = create_context(display, config, nullptr, nullptr);

    if (context == nullptr) {
      *reason = "EGL could not create an OpenGL context here";
      return nullptr;
    }

    // A context is made current against a surface; MuJoCo renders into its own
    // framebuffer, so the smallest one that will hold it is enough.
    const EGLint surface_attributes[] = {kWidth, 1, kHeight, 1, kNone};
    surface = create_pbuffer(display, config, surface_attributes);

    if (surface == nullptr) {
      *reason = "EGL could not create an offscreen surface here";
      return nullptr;
    }

    return context;
  }

  void current(EGLContext context) { make_current(display, surface, surface, context); }
};

#else

struct Platform {
  bool open(std::string *reason) {
    *reason = "offscreen rendering is carried on macOS and Linux, not on this platform";
    return false;
  }

  void *make(std::string *reason) {
    *reason = "offscreen rendering is carried on macOS and Linux, not on this platform";
    return nullptr;
  }

  void current(void *) {}
};

#endif

// The one context this process has. Created on the first renderer and kept for
// the life of the VM: a context is expensive to make, and GL objects — MuJoCo's
// textures and buffers among them — belong to the context that made them, so a
// second one would not see the first's.
struct Singleton {
  std::mutex lock;
  bool tried = false;
  bool ok = false;
  std::string reason;
  Platform platform;
  void *context = nullptr;
};

Singleton &singleton() {
  static Singleton one;
  return one;
}

}  // namespace

bool available(std::string *reason) {
  Singleton &one = singleton();

  std::lock_guard<std::mutex> guard(one.lock);

  if (!one.tried) {
    one.tried = true;

    if (one.platform.open(&one.reason)) {
      one.context = one.platform.make(&one.reason);
      one.ok = one.context != nullptr;
    }
  }

  if (!one.ok && reason != nullptr) {
    *reason = one.reason;
  }

  return one.ok;
}

Session::Session() : lock_(singleton().lock) {
  Singleton &one = singleton();

  if (!one.ok) {
    throw std::runtime_error(one.reason.empty() ? "no offscreen OpenGL context" : one.reason);
  }

  one.platform.current(one.context);
}

Session::~Session() = default;

}  // namespace gl
}  // namespace exmujoco
