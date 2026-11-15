defmodule ExMujoco.Application do
  # Nothing here to supervise: what this application does is load a library, and
  # it has to do it at the only moment that is both late enough and early enough.
  #
  # `ExMujoco.Native` has an `@on_load` hook, which is what loads MuJoCo and then
  # the NIF — and a **release** runs that hook while the kernel is still starting,
  # because every module carrying one is in its boot script. A library cannot be
  # loaded there (the module that does the preloading is itself not reachable
  # yet), so the hook answers `:later` and this process, which starts a moment
  # after the kernel is up, loads it before any caller can reach a stub that is
  # not a NIF yet. Without this, a host's release dies at boot with
  # `on_load_function_failed` and never serves a page — which is how it was found.
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    load()

    Supervisor.start_link([], strategy: :one_for_one, name: ExMujoco.Supervisor)
  end

  defp load do
    # Loaded already by the hook, the usual case outside a release: asking again
    # would be `:erlang.load_nif` twice, which Erlang refuses.
    if ExMujoco.Native.loaded?() do
      :ok
    else
      case ExMujoco.Native.load() do
        :ok ->
          :ok

        {:error, complaint} ->
          # Said once, here, and not raised: whether the library this build is
          # beside is usable is `ExMujoco.Loader`'s question, asked by the call
          # that needs it, and a host that never steps a model is not a host this
          # should refuse to start.
          Logger.warning(complaint <> " — anything that steps a model will refuse")
      end
    end
  end
end
