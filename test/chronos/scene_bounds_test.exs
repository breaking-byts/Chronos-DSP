defmodule Chronos.SceneBoundsTest do
  use ExUnit.Case, async: true

  alias Chronos.Scene
  alias Chronos.World

  test "empty world falls back to a centered ten by ten box" do
    assert Scene.bounds(World.new()) == %{min: {-5.0, -5.0}, max: {5.0, 5.0}}
  end

  test "empty world ignores padding because there is no content to pad" do
    assert Scene.bounds(World.new(), padding: 10.0) == %{
             min: {-5.0, -5.0},
             max: {5.0, 5.0}
           }
  end

  test "bounds cover every node with default padding" do
    world =
      World.new()
      |> World.add_node(node(:tx1, {0.0, 0.0, 0.0}))
      |> World.add_node(node(:rx1, {2.0, 4.0, -1.0}))

    assert Scene.bounds(world) == %{min: {-0.5, -0.5}, max: {2.5, 4.5}}
  end

  test "bounds include wall vertices" do
    wall = %World.Wall{
      id: :wall,
      vertices: [
        {-1.0, -2.0, -1.0},
        {3.0, -2.0, -1.0},
        {3.0, 1.0, 1.0},
        {-1.0, 1.0, 1.0}
      ],
      normal: {0.0, 0.0, 1.0},
      attenuation_db: 3.0
    }

    world =
      World.new()
      |> World.add_node(node(:rx1, {0.0, 0.0, 0.0}))
      |> World.add_wall(wall)

    assert Scene.bounds(world) == %{min: {-1.5, -2.5}, max: {3.5, 1.5}}
  end

  test "custom padding expands the box on both axes" do
    world =
      World.new()
      |> World.add_node(node(:tx1, {0.0, 0.0, 0.0}))
      |> World.add_node(node(:rx1, {2.0, 4.0, 0.0}))

    assert Scene.bounds(world, padding: 2.0) == %{min: {-2.0, -2.0}, max: {4.0, 6.0}}
  end

  test "degenerate axes are expanded by one unit" do
    world = World.new() |> World.add_node(node(:rx1, {1.0, 2.0, 0.0}))

    # {1.0, 2.0} expands to {0.0, 2.0} x {1.0, 3.0}, then padding is applied.
    assert Scene.bounds(world) == %{min: {-0.5, 0.5}, max: {2.5, 3.5}}
  end

  test "z coordinates do not affect XY bounds" do
    low = World.new() |> World.add_node(node(:rx1, {1.0, 2.0, -100.0}))
    high = World.new() |> World.add_node(node(:rx1, {1.0, 2.0, 100.0}))

    assert Scene.bounds(low) == Scene.bounds(high)
  end

  test "bounds are JSON-friendly through to_map/1" do
    world =
      World.new()
      |> World.add_node(node(:tx1, {0.0, 0.0, 0.0}))
      |> World.add_node(node(:rx1, {2.0, 4.0, 0.0}))

    assert Scene.to_map(Scene.bounds(world)) == %{
             min: [-0.5, -0.5],
             max: [2.5, 4.5]
           }
  end

  defp node(id, pos) do
    %World.Node{id: id, type: :rx, pos: pos, vel: {0.0, 0.0, 0.0}}
  end
end
