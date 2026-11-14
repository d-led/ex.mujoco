# The NIF, on Linux and macOS.
#
# `mix` runs this with `MIX_APP_PATH`, `ERTS_INCLUDE_DIR` and `FINE_INCLUDE_DIR`
# already set, and with `MUJOCO_DIR` pointing at a MuJoCo prepared by
# `scripts/prepare_mujoco.exs` (see mix.exs). Run it by hand and the fallbacks
# below apply.
#
# Nothing here is a secret: the flags are the ones Fine's own example uses, plus
# what linking a shared MuJoCo needs.

PRIV_DIR := $(MIX_APP_PATH)/priv
NIF_PATH := $(PRIV_DIR)/ex_mujoco_nif.so

C_SRC := $(EX_MUJOCO_PROJECT_DIR)/c_src
SCRIPT := $(EX_MUJOCO_PROJECT_DIR)/scripts/prepare_mujoco.exs

# `mix` passes MUJOCO_DIR; this is for someone running make directly.
MUJOCO_DIR ?= $(shell elixir "$(SCRIPT)" --print-dir)

CPPFLAGS := -shared -fPIC -fvisibility=hidden -std=c++17 -Wall -Wextra -Wno-unused-parameter
CPPFLAGS += -I"$(ERTS_INCLUDE_DIR)" -I"$(FINE_INCLUDE_DIR)" -I"$(MUJOCO_DIR)/include" -I$(C_SRC)

ifdef DEBUG
	CPPFLAGS += -g -O0
else
	CPPFLAGS += -O3
endif

LDFLAGS := -L"$(MUJOCO_DIR)/lib" -lmujoco

ifndef TARGET_ABI
	TARGET_ABI := $(shell uname -s | tr '[:upper:]' '[:lower:]')
endif

ifeq ($(TARGET_ABI),darwin)
	# NIF symbols resolve against the BEAM at load time. The rpath is where the
	# MuJoCo that priv carries is found: `@rpath/mujoco.framework/...` from the
	# release, `@rpath/libmujoco.<v>.dylib` from a source build — both under
	# priv, because that is where the NIF itself sits.
	CPPFLAGS += -undefined dynamic_lookup -flat_namespace
	LDFLAGS += -Wl,-rpath,@loader_path
else
	LDFLAGS += -Wl,-rpath,'$$ORIGIN'
endif

SOURCES := $(wildcard $(C_SRC)/*.cpp)
GENERATED := $(wildcard $(C_SRC)/generated/*.inc)
FINE_HEADERS := $(wildcard $(FINE_INCLUDE_DIR)/*.hpp)

all: mujoco $(NIF_PATH)
	@ echo > /dev/null # nothing to be done, and nothing to say about it

# Idempotent and quick once the cache is warm: it fetches, or builds, only when
# MUJOCO_DIR does not already hold a MuJoCo, and always keeps priv's copy of the
# shared library current.
mujoco:
	@ elixir "$(SCRIPT)" --ensure --priv "$(PRIV_DIR)"

$(NIF_PATH): $(SOURCES) $(GENERATED) $(FINE_HEADERS)
	@ mkdir -p "$(PRIV_DIR)"
	$(CXX) $(CPPFLAGS) $(SOURCES) $(LDFLAGS) -o $(NIF_PATH)

clean:
	$(RM) $(NIF_PATH)

# `mujoco` has no file of its own — it is a verb. nmake has no .PHONY; for make,
# this makes it explicit that the target above is not a directory.
.PHONY: all mujoco clean
