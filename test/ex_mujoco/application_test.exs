defmodule ExMujoco.ApplicationTest do
  # A release runs every `@on_load` hook while the kernel is still starting,
  # where a library cannot be loaded: the hook answers `:later` and the
  # application loads it instead. What this asserts is the whole of that promise —
  # by the time the application has started, the stubs are the NIF's — because the
  # version that did not keep it killed a host's VM at boot, with a boot script
  # nobody had written by hand.
  use ExUnit.Case, async: true

  test "the library is loaded by the time the application has started" do
    assert ExMujoco.Native.loaded?()
  end

  test "and a stub answers what only the NIF can answer" do
    assert is_integer(ExMujoco.version())
  end
end
