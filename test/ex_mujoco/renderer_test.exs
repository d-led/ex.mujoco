defmodule ExMujoco.RendererTest do
  use ExUnit.Case, async: true

  alias ExMujoco.{Api, Renderer, Types}

  # Rendering needs an OpenGL context, which this package makes for itself on a
  # machine that has one. A machine that does not — a container without EGL, a CI
  # runner with no GL — still runs everything else, so these cases say why they
  # did not run rather than failing.
  if not Renderer.available?() do
    @moduletag skip: Renderer.unavailable_reason()
  end

  # A cube on a floor, seen from 40 cm away and 20 cm up: the cube's near face is
  # 35 cm from the camera, and it sits below the camera's axis, so it has to come
  # back in the lower half of the image.
  @scene """
  <mujoco>
    <visual>
      <global offwidth="64" offheight="64"/>
      <map znear="0.005" zfar="500"/>
      <headlight ambient="0.5 0.5 0.5" diffuse="0 0 0" specular="0 0 0"/>
    </visual>
    <option gravity="0 0 0"/>
    <worldbody>
      <light pos="0 0 0.2" diffuse="0.6 0.6 0.6" specular="0.1 0.1 0.1" directional="true"/>
      <geom name="floor" type="plane" size="1 1 0.1" rgba="0.3 0.3 0.3 1"/>
      <body name="cube" pos="0 0 0.05">
        <geom name="cube_geom" type="box" size="0.05 0.05 0.05" rgba="1 0 0 1"/>
      </body>
      <camera name="cam" pos="0 -0.4 0.2" xyaxes="1 0 0 0 0 1"/>
    </worldbody>
  </mujoco>
  """

  setup do
    {:ok, model} = ExMujoco.load_string(@scene)
    data = ExMujoco.data(model)
    :ok = ExMujoco.forward(data)

    # Segmentation answers the geom's own id, so the cube is named rather than
    # counted: the floor is declared first and is geom 0.
    cube = Api.mj_name2id(model, Types.Obj.geom(), "cube_geom")

    %{model: model, data: data, renderer: Renderer.new(model, 64, 64), cube: cube}
  end

  describe "what a pass answers" do
    test "each pass answers one image of the size it was asked for", %{
      renderer: renderer,
      data: data
    } do
      [rgb, depth, segmentation] =
        Renderer.read(renderer, data, "cam", [:rgb, :depth, :segmentation])

      assert byte_size(rgb) == 64 * 64 * 3
      assert byte_size(depth) == 64 * 64 * 4
      assert byte_size(segmentation) == 64 * 64 * 4
    end

    test "passes come back in the order they were asked for", %{renderer: renderer, data: data} do
      [depth, rgb] = Renderer.read(renderer, data, "cam", [:depth, :rgb])

      assert byte_size(depth) == 64 * 64 * 4
      assert byte_size(rgb) == 64 * 64 * 3
    end
  end

  describe "what the camera sees" do
    test "the cube is in the picture, the floor around it, and nothing past them", %{
      renderer: renderer,
      data: data,
      cube: cube
    } do
      [segmentation] = Renderer.read(renderer, data, "cam", [:segmentation])

      assert segmentation |> ids() |> Enum.uniq() |> Enum.sort() == [-1, floor(), cube]
    end

    test "the cube is below the camera's axis, so it is in the lower half of the image", %{
      renderer: renderer,
      data: data,
      cube: cube
    } do
      [segmentation] = Renderer.read(renderer, data, "cam", [:segmentation])

      cube_rows = for {{row, _column}, id} <- pixels(segmentation), id == cube, do: row

      assert cube_rows != []
      assert Enum.min(cube_rows) > 32
    end

    test "the cube's pixels are the red its geom was given", %{
      renderer: renderer,
      data: data,
      cube: cube
    } do
      [rgb, segmentation] = Renderer.read(renderer, data, "cam", [:rgb, :segmentation])

      pixels =
        for {{row, column}, id} <- pixels(segmentation), id == cube do
          pixel(rgb, row, column)
        end

      assert length(pixels) > 100

      assert Enum.any?(pixels, fn {red, green, blue} -> red > 200 and green < 30 and blue < 30 end)
    end

    test "depth is the distance to the cube's near face, in metres", %{
      renderer: renderer,
      data: data
    } do
      [depth] = Renderer.read(renderer, data, "cam", [:depth])

      nearest = depth |> depths() |> Enum.min()

      # The camera is 40 cm from the cube's centre and the face is 5 cm toward it.
      assert_in_delta nearest, 0.35, 0.001
    end

    test "a pixel that hit nothing is the far plane, not a zero", %{
      renderer: renderer,
      data: data
    } do
      [depth] = Renderer.read(renderer, data, "cam", [:depth])

      assert depth |> depths() |> Enum.max() > 1.0
    end
  end

  describe "refusals" do
    test "an image larger than the model's offscreen buffer says so", %{model: model} do
      error = assert_raise ArgumentError, fn -> Renderer.new(model, 128, 64) end

      assert error.message =~ "offscreen buffer"
      assert error.message =~ "64"
    end

    test "a camera the model does not have says which one", %{renderer: renderer, data: data} do
      error =
        assert_raise ArgumentError, fn -> Renderer.read(renderer, data, "elsewhere", [:rgb]) end

      assert error.message =~ "elsewhere"
    end

    test "a pass that is not one of the three is refused by name", %{
      renderer: renderer,
      data: data
    } do
      error =
        assert_raise ArgumentError, fn ->
          Renderer.read(renderer, data, "cam", [:rgb, :lighting])
        end

      assert error.message =~ "lighting"
    end
  end

  describe "the machine" do
    test "says it can render, and has no reason not to" do
      assert Renderer.available?()
      assert Renderer.unavailable_reason() == ""
    end
  end

  # Row and column for every pixel, with the id drawn there.
  defp pixels(segmentation) do
    segmentation
    |> ids()
    |> Enum.with_index()
    |> Enum.map(fn {id, at} -> {{div(at, 64), rem(at, 64)}, id} end)
  end

  # MuJoCo's id for the floor, which is the first geom the scene declares.
  defp floor, do: 0

  defp ids(segmentation) do
    for <<id::signed-little-32 <- segmentation>>, do: id
  end

  defp depths(depth) do
    for <<value::float-32-little <- depth>>, do: value
  end

  defp pixel(rgb, row, column) do
    at = (row * 64 + column) * 3
    <<_::binary-size(^at), red::8, green::8, blue::8, _::binary>> = rgb
    {red, green, blue}
  end
end
