defmodule ExMujoco.RendererAvailabilityTest do
  use ExUnit.Case, async: true

  alias ExMujoco.Renderer

  # The two answers a caller checks before it draws anything. This file is
  # separate from `renderer_test.exs` on purpose: that one skips where there is
  # no OpenGL, and these are the cases a machine without it must still pass.
  test "it answers a boolean, and a sentence exactly when the answer is no" do
    assert is_boolean(Renderer.available?())

    reason = Renderer.unavailable_reason()

    assert is_binary(reason)
    assert Renderer.available?() == (reason == "")
  end
end
