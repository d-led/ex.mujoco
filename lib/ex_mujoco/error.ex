defmodule ExMujoco.Error do
  @moduledoc """
  What MuJoCo says when it refuses.

  MuJoCo reports a fatal error by printing a message and not returning; inside a
  NIF that would abort the VM. `c_src/mj_call.hpp` intercepts it and re-throws it
  on the Elixir side, where it arrives as this exception — the message is
  MuJoCo's own, with the function that raised it in front of it
  (`mj_step: qpos is not finite`).

  A `RuntimeError` escaping from the NIF is the same thing before
  `ExMujoco` has re-raised it; call the typed functions instead.
  """
  defexception [:message]

  @typedoc "MuJoCo's message, with the function that raised it in front of it."
  @type t :: %__MODULE__{message: String.t()}
end
