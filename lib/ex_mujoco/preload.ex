defmodule ExMujoco.Preload do
  @moduledoc false

  # Loads MuJoCo itself, before `ExMujoco.Native` loads the library that imports
  # it. Windows resolves an import against the modules already in the process and
  # will not look beside the importing library, so `mujoco.dll` has to be in the
  # process first; `c_src/preload.cpp` has the whole reason.
  #
  # macOS and Linux need none of this — a shared library there finds its
  # dependencies beside itself — so on those platforms the call does nothing and
  # answers `:ok`.

  @on_load :load

  @doc false
  def load do
    path = :filename.join(:code.priv_dir(:ex_mujoco), ~c"ex_mujoco_preload")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, reason} -> {:error, "ex_mujoco: could not load the preloader: #{inspect(reason)}"}
    end
  end

  @doc """
  Brings MuJoCo into the process from `directory`.

  Answers `:ok`, or `{:error, reason}` when the library that `directory` holds
  could not be loaded — which on Windows is the answer to "why is the NIF not
  there".
  """
  @spec mujoco(Path.t()) :: :ok | {:error, String.t()}
  def mujoco(directory) when is_binary(directory) do
    case load_mujoco(directory) do
      "" -> :ok
      complaint -> {:error, complaint}
    end
  end

  defp load_mujoco(_directory), do: :erlang.nif_error(:nif_not_loaded)
end
