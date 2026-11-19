defmodule Chronos.ScenePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chronos.Scene
  alias Chronos.World

  defp position do
    StreamData.tuple(
      {StreamData.float(min: -1000.0, max: 1000.0), StreamData.float(min: -1000.0, max: 1000.0),
       StreamData.float(min: -1000.0, max: 1000.0)}
    )
  end

  defp world_with_nodes(positions) do
    positions
    |> Enum.with_index()
    |> Enum.reduce(World.new(), fn {pos, index}, world ->
      type = if rem(index, 2) == 0, do: :tx, else: :rx

      World.add_node(world, %World.Node{
        id: {:node, index},
        type: type,
        pos: pos,
        vel: {0.0, 0.0, 0.0}
      })
    end)
  end

  property "bounds min <= max on every axis and contain every node position" do
    check all(
            positions <- StreamData.list_of(position(), max_length: 12),
            padding <- StreamData.float(min: 0.0, max: 10.0)
          ) do
      world = world_with_nodes(positions)
      %{min: {min_x, min_y}, max: {max_x, max_y}} = Scene.bounds(world, padding: padding)

      assert min_x <= max_x
      assert min_y <= max_y

      for {x, y, _z} <- positions do
        assert x >= min_x and x <= max_x
        assert y >= min_y and y <= max_y
      end
    end
  end

  property "bounds also contain every wall vertex" do
    check all(
            positions <- StreamData.list_of(position(), min_length: 1, max_length: 6),
            {wx, wy, _wz} <- position(),
            half <- StreamData.float(min: 0.1, max: 100.0)
          ) do
      vertices = [
        {wx - half, wy - half, 0.0},
        {wx + half, wy - half, 0.0},
        {wx + half, wy + half, 0.0},
        {wx - half, wy + half, 0.0}
      ]

      world =
        positions
        |> world_with_nodes()
        |> World.add_wall(%World.Wall{id: :wall, vertices: vertices, normal: {0.0, 0.0, 1.0}})

      %{min: {min_x, min_y}, max: {max_x, max_y}} = Scene.bounds(world)
      assert min_x <= max_x and min_y <= max_y

      for {x, y, _z} <- vertices do
        assert x >= min_x and x <= max_x
        assert y >= min_y and y <= max_y
      end
    end
  end

  property "an empty world falls back to the centered default box" do
    check all(padding <- StreamData.float(min: 0.0, max: 10.0)) do
      assert Scene.bounds(World.new(), padding: padding) == %{min: {-5.0, -5.0}, max: {5.0, 5.0}}
    end
  end

  property "a single-node world still has non-zero span on both axes" do
    check all(pos <- position()) do
      world = world_with_nodes([pos])
      %{min: {min_x, min_y}, max: {max_x, max_y}} = Scene.bounds(world)
      assert max_x > min_x
      assert max_y > min_y
    end
  end
end
