defmodule ExMujoco do
  @moduledoc """
  MuJoCo, from Elixir.

      {:ok, model} = ExMujoco.load_xml("model/scene.xml")
      data = ExMujoco.data(model)

      ExMujoco.forward(data)
      ExMujoco.step(data)

      ExMujoco.Data.qpos(data) |> ExMujoco.Tensor.to_list()
      ExMujoco.Model.geom_size(model) |> ExMujoco.Tensor.to_list()

  A model is compiled and immutable; a data block is the state that moves. Both
  are resources, released by the garbage collector, so there is no lifetime to get
  wrong: a `Data` holds the `Model` it came from, and neither outlives its user.

  Fields are read one at a time — `ExMujoco.Model` and `ExMujoco.Data` have a
  function per field of `mjModel` and `mjData`, named as MuJoCo names them, and
  answering either a number or an `ExMujoco.Tensor`. Reading copies, so what you
  hold does not change when the next step runs.

  ## Where the code comes from

  The NIF is generated from MuJoCo's own headers: one binding per field and per
  C function in `c_src/manifest.exs`. `docs/coverage.md` says what is bound and
  what is not, and why. The hand-written half —
  [`c_src/ex_mujoco_nif.cpp`](https://github.com/d-led/ex.mujoco) — is the part
  where each call needs a decision: which buffer, whose lifetime.

  ## What is not here yet

  `mjSpec` — building a model in memory, rather than compiling XML — and offscreen
  rendering. Both are in `docs/plan.md` with the reason they are their own
  phase: a scene needs a GL context per platform, and that is a different job
  from stepping physics.

  ## Errors

  MuJoCo reports a fatal error by not returning, which inside a NIF would abort
  the VM. It is intercepted and arrives as `ExMujoco.Error` with MuJoCo's own
  message, so a bad model is an exception in one process and not a dead node.
  """

  alias ExMujoco.{Data, Error, Model, Native, Tensor, Types}

  @typedoc "A compiled `mjModel`."
  @type model :: Model.t()

  @typedoc "An `mjData` and the model it belongs to."
  @type data :: Data.t()

  @doc """
  Compiles a model from an MJCF file.

  Every file it includes is resolved relative to its own directory, as MuJoCo
  does.
  """
  @spec load_xml(Path.t()) :: {:ok, model()} | {:error, Error.t()}
  def load_xml(path) when is_binary(path) do
    ensure_compatible!()
    {:ok, guarded(fn -> Native.load_xml(path) end)}
  rescue
    error in Error -> {:error, error}
  end

  @doc """
  Compiles a model from MJCF in memory.

  `load_xml/1` is the better choice when the model can name its own files; this
  one has no directory to resolve includes against.
  """
  @spec load_string(String.t()) :: {:ok, model()} | {:error, Error.t()}
  def load_string(xml) when is_binary(xml) do
    ensure_compatible!()
    {:ok, guarded(fn -> Native.load_xml_string(xml) end)}
  rescue
    error in Error -> {:error, error}
  end

  @doc """
  A fresh `mjData` for a model, at the model's initial state.
  """
  @spec data(model()) :: data()
  def data(model) do
    ensure_compatible!()
    guarded(fn -> Native.data(model) end)
  end

  @doc """
  Puts the data back to the model's initial state.
  """
  @spec reset(data()) :: :ok
  def reset(data), do: guarded(fn -> Native.reset(data) end)

  @doc """
  Position and velocity kinematics without stepping — `mj_forward`.

  What to call after writing `qpos`, `qvel` or `ctrl` and before reading anything
  that depends on them.
  """
  @spec forward(data()) :: :ok
  def forward(data), do: guarded(fn -> Native.forward(data) end)

  @doc """
  One simulation step — `mj_step`.
  """
  @spec step(data()) :: :ok
  def step(data), do: guarded(fn -> Native.step(data) end)

  @doc """
  The whole integration state, as a binary of float64.

  The default signature is `mjSTATE_INTEGRATION`, which is every element MuJoCo
  has a slot for; `state/2` takes any other `mjtState` combination, e.g.
  `ExMujoco.Types.State.physics()` for just the generalized coordinates.
  """
  @spec state(data(), integer()) :: binary()
  def state(data, signature \\ Types.State.integration()) do
    guarded(fn -> Native.get_state(data, signature) end)
  end

  @doc """
  Writes a state read by `state/2` back into the data.

  The binary has to be the size that signature implies; anything else is refused
  rather than written past the end of it.
  """
  @spec put_state(data(), integer(), binary()) :: :ok
  def put_state(data, signature, values) do
    guarded(fn -> Native.set_state(data, signature, values) end)
  end

  @doc """
  How many float64 values a state signature holds.
  """
  @spec state_size(model(), integer()) :: non_neg_integer()
  def state_size(model, signature \\ Types.State.integration()) do
    guarded(fn -> Native.state_size(model, signature) end)
  end

  @doc """
  The six numbers of one contact's force, as an `ExMujoco.Tensor`.

  MuJoCo writes them into an array the caller owns, which is why this is not a
  generated binding: there is no array to hand it.
  """
  @spec contact_force(data(), non_neg_integer()) :: Tensor.t()
  def contact_force(data, index) do
    Tensor.new(:f64, {6}, guarded(fn -> Native.contact_force(data, index) end))
  end

  @doc """
  The MuJoCo library's version, as MuJoCo numbers it: `4000001` is 4.0.1.
  """
  @spec version() :: non_neg_integer()
  def version, do: Native.version()

  @doc """
  The version of the headers this NIF was generated from.

  The two are compared at load; if they disagree the NIF does not load.
  """
  @spec header_version() :: non_neg_integer()
  def header_version, do: Native.header_version()

  # The library and the headers have to be one version: two versions of one
  # physics is not a difference of behaviour, it is a difference of answer. Asked
  # once per node, on the first thing a caller does with a model.
  @compatible {__MODULE__, :compatible}

  defp ensure_compatible! do
    if :persistent_term.get(@compatible, :unknown) == :unknown do
      case ExMujoco.Loader.check() do
        :ok ->
          :persistent_term.put(@compatible, :ok)

        {:error, message} ->
          raise Error, message: message
      end
    end

    :ok
  end

  # MuJoCo's own message, in this package's exception. A NIF error that is not a
  # MuJoCo error — `:nif_not_loaded` from a build that never linked — is left
  # alone, because that is a build problem and should look like one.
  defp guarded(fun) do
    fun.()
  rescue
    error in RuntimeError -> reraise Error, [message: error.message], __STACKTRACE__
  end
end
