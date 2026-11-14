defmodule ExMujoco.Tensor do
  @moduledoc """
  A field of an `mjModel` or `mjData`, as a value: the elements, their type, and
  the shape MuJoCo declared them with.

      iex> model |> ExMujoco.Model.geom_pos() |> ExMujoco.Tensor.to_list()
      [[0.0, 0.0, 0.0], [0.0, 0.0, 0.05], ...]

  The data is one binary of elements in the machine's native order — MuJoCo's own
  layout, copied straight out of the struct — so `Nx.from_binary/2` takes it as it
  is, and so does `<<x::float-64-native>>`.

  A shape of `{3}` is a vector (MuJoCo's `(n × 1)`), `{n, 3}` is a matrix, and
  `{}` is a single value. Reading a field copies it, so what you hold does not
  change when the next step runs — which is the whole reason not to hand out a
  binary that aliases live `mjData`.
  """

  @typedoc "The element type, as MuJoCo declares it."
  @type element_type :: :f64 | :f32 | :i32 | :u8

  @type t :: %__MODULE__{
          type: element_type(),
          shape: tuple(),
          data: binary()
        }

  @enforce_keys [:type, :shape, :data]
  defstruct [:type, :shape, :data]

  @doc false
  def new(type, {rows, 1}, data), do: %__MODULE__{type: type, shape: {rows}, data: data}
  def new(type, {1, 1}, data), do: %__MODULE__{type: type, shape: {}, data: data}
  def new(type, shape, data), do: %__MODULE__{type: type, shape: shape, data: data}

  @doc """
  The elements as an Elixir list, nested to the shape.

  Convenient and slow: it allocates a term per element. For anything on a hot
  path, keep the binary and read it with a bitstring pattern.
  """
  @spec to_list(t()) :: list()
  def to_list(%__MODULE__{type: type, shape: shape, data: data}) do
    elements = elements(type, data)

    case shape do
      {} -> List.first(elements)
      {_rows} -> elements
      {rows, cols} -> Enum.chunk_every(elements, cols) |> Enum.take(rows)
    end
  end

  defp elements(:f64, data), do: for(<<value::float-64-native <- data>>, do: value)
  defp elements(:f32, data), do: for(<<value::float-32-native <- data>>, do: value)
  defp elements(:i32, data), do: for(<<value::signed-32-native <- data>>, do: value)
  defp elements(:u8, data), do: for(<<value::unsigned-8 <- data>>, do: value)

  @doc """
  The number of elements, whatever the shape.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{shape: {}}), do: 1
  def size(%__MODULE__{shape: {rows}}), do: rows
  def size(%__MODULE__{shape: {rows, cols}}), do: rows * cols

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{shape: shape, type: type, data: data}, opts) do
      count = div(byte_size(data), if(type == :u8, do: 1, else: if(type == :f32, do: 4, else: 8)))

      concat([
        "#ExMujoco.Tensor<",
        to_doc(shape, opts),
        " ",
        to_doc(type, opts),
        " ",
        to_doc(count, opts),
        " values>"
      ])
    end
  end
end
