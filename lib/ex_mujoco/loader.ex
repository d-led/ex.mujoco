defmodule ExMujoco.Loader do
  @moduledoc """
  Loading the NIF, and refusing to go on if it does not match the headers it was
  generated from.

  Called from the NIF module's `@on_load` after the library is in, so a mismatch is
  a module that will not load — which is loud — rather than a physics run that is
  quietly a different version.

  The loading itself has to happen in the module that names the library: `:erlang.load_nif` only
  loads a library whose `ERL_NIF_INIT` name is the calling module's.
  """

  @doc """
  Whether the library and the headers agree.

  Both numbers are `mjVERSION_HEADER`-shaped: `4000001` is 4.0.1.
  """
  @spec check() :: :ok | {:error, String.t()}
  def check do
    library = ExMujoco.Native.version()
    headers = ExMujoco.Native.header_version()

    if library == headers do
      :ok
    else
      {:error,
       """
       ex_mujoco: the MuJoCo library in priv/ is #{version(library)}, and the \
       headers the NIF was generated from are #{version(headers)}.

       Two versions of one physics is not a difference of behaviour, it is a \
       difference of answer. Rebuild: `mix deps.clean ex_mujoco && mix compile`.
       """}
    end
  end

  defp version(number) do
    "#{div(number, 1_000_000)}.#{div(rem(number, 1_000_000), 1_000)}.#{rem(number, 1_000)} (#{number})"
  end
end
