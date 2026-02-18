defmodule Chronos.WorldTest do
  use ExUnit.Case, async: true

  alias Chronos.World

  test "new world starts empty" do
    world = World.new()
    assert world.time_s == 0.0
    assert world.nodes == %{}
    assert world.walls == %{}
  end

  test "add_node and node lookup" do
    world = World.new()
    node = %World.Node{id: :tx1, type: :tx, pos: {0.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}}
    world = World.add_node(world, node)
    assert World.node(world, :tx1) == node
  end

  test "add_wall and wall lookup" do
    world = World.new()

    wall = %World.Wall{
      id: :w1,
      vertices: [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0}, {0.0, 1.0, 0.0}],
      normal: {0.0, 0.0, 1.0},
      attenuation_db: 3.0
    }

    world = World.add_wall(world, wall)
    assert World.wall(world, :w1) == wall
  end

  test "nodes_by_type returns matching nodes" do
    world =
      World.new()
      |> World.add_node(%World.Node{
        id: :tx1,
        type: :tx,
        pos: {0.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })
      |> World.add_node(%World.Node{
        id: :rx1,
        type: :rx,
        pos: {1.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })

    assert [tx] = World.nodes_by_type(world, :tx)
    assert tx.id == :tx1
  end

  test "step updates positions and time" do
    world =
      World.new()
      |> World.add_node(%World.Node{
        id: :rx1,
        type: :rx,
        pos: {0.0, 0.0, 0.0},
        vel: {1.0, 2.0, -1.0}
      })

    world = World.step(world, 0.5)
    assert %{pos: {0.5, 1.0, -0.5}} = World.node(world, :rx1)
    assert world.time_s == 0.5
  end

  test "update_node updates position" do
    node = %World.Node{id: :n1, type: :rx, pos: {1.0, 1.0, 1.0}, vel: {1.0, -1.0, 0.5}}
    updated = World.update_node(node, 2.0)
    assert updated.pos == {3.0, -1.0, 2.0}
  end
end
