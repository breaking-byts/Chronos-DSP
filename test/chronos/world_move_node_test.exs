defmodule Chronos.WorldMoveNodeTest do
  use ExUnit.Case, async: true

  alias Chronos.World

  test "move_node updates only the requested node kinematics" do
    original =
      World.new()
      |> World.add_node(node(:tx1, :tx, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}))
      |> World.add_node(node(:rx1, :rx, {1.0, 2.0, 0.0}, {0.0, -1.0, 0.0}))

    assert {:ok, moved} =
             World.move_node(original, :rx1, {4.0, 5.0, 6.0}, {0.5, 0.0, -0.5})

    assert World.node(moved, :rx1).pos == {4.0, 5.0, 6.0}
    assert World.node(moved, :rx1).vel == {0.5, 0.0, -0.5}
    assert World.node(moved, :tx1) == World.node(original, :tx1)
    assert moved.time_s == original.time_s
    assert map_size(moved.nodes) == map_size(original.nodes)

    # The original world is immutable and untouched.
    assert World.node(original, :rx1).pos == {1.0, 2.0, 0.0}
  end

  test "move_node returns unknown_node and leaves the world unchanged" do
    world = World.new() |> World.add_node(node(:rx1, :rx, {1.0, 2.0, 0.0}, {0.0, 0.0, 0.0}))

    assert {:error, :unknown_node} =
             World.move_node(world, :typo, {9.0, 9.0, 9.0}, {0.0, 0.0, 0.0})

    assert World.node(world, :typo) == nil
    assert World.node(world, :rx1).pos == {1.0, 2.0, 0.0}
  end

  test "move_node does not create a node for an unknown id" do
    world = World.new()

    assert {:error, :unknown_node} =
             World.move_node(world, :created_by_accident, {1.0, 0.0, 0.0}, {0.0, 0.0, 0.0})

    assert world.nodes == %{}
  end

  test "move_node keys match exactly" do
    world = World.new() |> World.add_node(node(:rx1, :rx, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}))

    assert {:error, :unknown_node} =
             World.move_node(world, "rx1", {1.0, 0.0, 0.0}, {0.0, 0.0, 0.0})
  end

  test "move_node can be chained through World.step/2" do
    world = World.new() |> World.add_node(node(:rx1, :rx, {0.0, 0.0, 0.0}, {1.0, 1.0, 0.0}))

    {:ok, moved} = World.move_node(world, :rx1, {0.0, 0.0, 0.0}, {2.0, 0.0, 0.0})
    stepped = World.step(moved, 0.5)

    assert World.node(stepped, :rx1).pos == {1.0, 0.0, 0.0}
    assert stepped.time_s == 0.5
  end

  defp node(id, type, pos, vel) do
    %World.Node{id: id, type: type, pos: pos, vel: vel}
  end
end
