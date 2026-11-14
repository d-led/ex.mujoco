defmodule ExMujoco.Renderer do
  @moduledoc """
  Offscreen rendering: the images a scene has, through a camera in it.

  A renderer belongs to a model — it uploads the model's meshes and textures into
  OpenGL objects — so it is made once per model and kept. It also belongs to a
  *resolution*: MuJoCo's colour and depth buffers are one size, and a second size
  is a second renderer.

      {:ok, model} = ExMujoco.load_string("<mujoco>…</mujoco>")
      data = ExMujoco.data(model)
      ExMujoco.forward(data)

      renderer = ExMujoco.Renderer.new(model, 64, 64)
      [rgb, depth, segmentation] = ExMujoco.Renderer.read(renderer, data, "cam", [:rgb, :depth, :segmentation])

  ## What comes back

  One binary per pass, top row first:

  | pass | shape | holds |
  |---|---|---|
  | `:rgb` | `width * height * 3` bytes | red, green, blue, in 0..255 |
  | `:depth` | `width * height * 4` bytes | float32 metres from the camera |
  | `:segmentation` | `width * height * 4` bytes | int32 geom id, `-1` where nothing was drawn |

  `ExMujoco.Tensor` turns a binary into numbers; these are plain binaries because
  a picture is one and a tensor of 4096 values is a list of 4096 floats.

  ## Where it works

  Rendering needs an OpenGL context, and this package makes one itself: CGL on
  macOS, EGL on Linux, and nowhere else yet. Nothing is linked — the platform's
  library is opened when the first renderer is asked for — so a machine without
  one still loads this package and runs everything that does not draw.
  `available?/0` answers whether this machine draws, and `unavailable_reason/0`
  says why not in words.

  ## The resolution is the model's to allow

  MuJoCo renders into an offscreen buffer whose size the *model* declares
  (`<visual><global offwidth=… offheight=…/>`, 640×480 by default). An image
  larger than that is refused here rather than rendered black.
  """

  alias ExMujoco.{Error, Native}

  @enforce_keys [:model, :resource, :width, :height]
  defstruct [:model, :resource, :width, :height]

  @typedoc """
  A renderer for one model at one resolution.

  It holds the model it was made for, so the model cannot be freed underneath a
  context that has uploaded it.
  """
  @type t :: %__MODULE__{
          model: ExMujoco.model(),
          resource: term(),
          width: pos_integer(),
          height: pos_integer()
        }

  @typedoc "A pass to draw, and the shape of the binary it answers."
  @type pass :: :rgb | :depth | :segmentation

  @doc """
  Whether this machine can render offscreen at all.

  The answer is memoised by the NIF: the platform's OpenGL library is opened once.
  """
  @spec available?() :: boolean()
  def available?, do: Native.renderer_available()

  @doc """
  Why this machine cannot render, in words — empty when it can.
  """
  @spec unavailable_reason() :: String.t()
  def unavailable_reason, do: Native.renderer_unavailable_reason()

  @doc """
  A renderer for `model`, drawing `width` by `height` images.

  Raises `ExMujoco.Error` when the machine has no OpenGL context, or when the
  model's offscreen buffer is smaller than the image asked for.
  """
  @spec new(ExMujoco.model(), pos_integer(), pos_integer()) :: t()
  def new(model, width, height) when is_integer(width) and is_integer(height) do
    %__MODULE__{
      model: model,
      resource: guarded(fn -> Native.renderer_new(model, width, height) end),
      width: width,
      height: height
    }
  end

  @doc """
  Draws `passes` through the camera `camera` names, and answers one binary per
  pass, in the order asked for.

  `data` has to be stepped or forwarded first: a render reads the model's
  kinematics, and what it reads is whatever `mj_forward` last computed.
  """
  @spec read(t(), ExMujoco.data(), String.t(), [pass(), ...]) :: [binary()]
  def read(%__MODULE__{resource: resource}, data, camera, passes)
      when is_binary(camera) and is_list(passes) do
    guarded(fn -> Native.renderer_render(resource, data, camera, passes) end)
  end

  @doc """
  The camera and the image size a renderer was made for.
  """
  @spec size(t()) :: {pos_integer(), pos_integer()}
  def size(%__MODULE__{width: width, height: height}), do: {width, height}

  defp guarded(fun) do
    fun.()
  rescue
    error in RuntimeError ->
      reraise Error, [message: error.message], __STACKTRACE__

    error in ErlangError ->
      complaint(error, __STACKTRACE__)
  end

  defp complaint(%ErlangError{original: text}, stacktrace) when is_binary(text) do
    reraise Error, [message: text], stacktrace
  end

  defp complaint(error, stacktrace), do: reraise(error, stacktrace)
end
