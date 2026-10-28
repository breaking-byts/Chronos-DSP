defmodule Chronos.Scene do
  @moduledoc """
  2D projection helpers for the top-down scene view.

  The simulator is fully three-dimensional, but the default dashboard presents a
  top-down (XY) view. `bounds/1` derives a stable viewport from the world so the
  browser can fit the scene to the canvas, and `project/3` converts world
  coordinates into viewport pixels.
  """

  @type vec3 :: {float(), float(), float()}
  @type bounds :: %{min: {float(), float()}, max: {float(), float()}}
  @type viewport :: %{width: number(), height: number()}

  @default_bounds %{min: {-5.0, -5.0}, max: {5.0, 5.0}}
  @default_padding 0.5

  @doc """
  Returns a JSON-friendly map for the given bounds.
  """
  @spec to_map(bounds()) :: %{min: [float()], max: [float()]}
  def to_map(%{min: {min_x, min_y}, max: {max_x, max_y}}) do
    %{min: [min_x, min_y], max: [max_x, max_y]}
  end

  @doc """
  Computes axis-aligned XY bounds for every node and wall vertex in the world.

  An empty world falls back to a centered 10x10 box. A degenerate axis (for
  example a world containing a single point) is expanded by one unit so the
  projection never divides by zero.

  Options:

    * `:padding` - world units added around the content (default `0.5`)
  """
  @spec bounds(Chronos.World.t(), keyword()) :: bounds()
  def bounds(world, opts \\ []) do
    padding = Keyword.get(opts, :padding, @default_padding)

    points =
      world.nodes
      |> Map.values()
      |> Enum.map(& &1.pos)
      |> Kernel.++(world.walls |> Map.values() |> Enum.flat_map(& &1.vertices))

    if points == [] do
      @default_bounds
    else
      {min_x, max_x} = min_max(points, 0)
      {min_y, max_y} = min_max(points, 1)

      %{
        min: {min_x - padding, min_y - padding},
        max: {max_x + padding, max_y + padding}
      }
    end
  end

  @doc """
  Projects a 3D point into viewport pixels using the supplied XY bounds.

  Raises `ArgumentError` when the XY bounds have zero span.
  """
  @spec project(vec3(), bounds(), viewport()) :: {float(), float()}
  def project({x, y, _z}, %{min: {min_x, min_y}, max: {max_x, max_y}}, %{width: w, height: h}) do
    if max_x == min_x or max_y == min_y do
      raise ArgumentError,
            "bounds must have non-zero span for x/y: min={#{min_x}, #{min_y}} max={#{max_x}, #{max_y}}"
    end

    nx = (x - min_x) / (max_x - min_x)
    ny = (y - min_y) / (max_y - min_y)
    {nx * w, (1.0 - ny) * h}
  end

  defp min_max(points, index) do
    values = Enum.map(points, &elem(&1, index))
    min = Enum.min(values)
    max = Enum.max(values)

    if min == max do
      {min - 1.0, max + 1.0}
    else
      {min, max}
    end
  end
end
