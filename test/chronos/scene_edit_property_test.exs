defmodule Chronos.SceneEditPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chronos.SceneEdit
  alias Chronos.World

  @bounds %{min: {-3.0, -3.0}, max: {3.0, 3.0}}

  defp coord(min, max), do: StreamData.float(min: min, max: max)

  property "wall_vertex commits always keep endpoint in bounds+margin and edges >= min_wall_edge" do
    margin = SceneEdit.bounds_margin()
    min_edge = SceneEdit.min_wall_edge()

    check all(
            x <- coord(-10.0, 10.0),
            y <- coord(-10.0, 10.0),
            ax <- coord(-2.5, 2.5),
            ay <- coord(-2.5, 2.5),
            bx <- coord(-2.5, 2.5),
            by <- coord(-2.5, 2.5),
            :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2) >= min_edge
          ) do
      wall = %World.Wall{
        id: :w1,
        vertices: [{0.0, 0.0, 0.0}, {ax, ay, 0.0}, {bx, by, 0.0}],
        normal: {0.0, 0.0, 1.0}
      }

      world = World.add_wall(World.new(), wall)
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 0, "pos" => [x, y]}

      case SceneEdit.apply(world, @bounds, payload) do
        {:ok, updated} ->
          [{px, py, _}, {n1x, n1y, _}, {n2x, n2y, _}] = World.wall(updated, :w1).vertices
          assert px >= -3.0 - margin and px <= 3.0 + margin
          assert py >= -3.0 - margin and py <= 3.0 + margin
          assert :math.sqrt((px - n1x) ** 2 + (py - n1y) ** 2) >= min_edge - 1.0e-9
          assert :math.sqrt((px - n2x) ** 2 + (py - n2y) ** 2) >= min_edge - 1.0e-9

        {:error, :invalid_payload} ->
          :ok
      end
    end
  end

  property "whole-wall drags on zero-vertex walls always return invalid_payload" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)) do
      wall = %World.Wall{id: id, vertices: [], normal: {0.0, 0.0, 1.0}}
      world = World.add_wall(World.new(), wall)

      assert {:error, :invalid_payload} =
               SceneEdit.apply(world, @bounds, %{"kind" => "wall", "id" => id, "vertices" => []})
    end
  end
end
