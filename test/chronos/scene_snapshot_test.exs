defmodule Chronos.SceneSnapshotTest do
  use ExUnit.Case, async: true

  alias Chronos.Scenario
  alias Chronos.SceneSnapshot
  alias Chronos.World

  defp base_world do
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
      pos: {3.0, 0.0, 0.0},
      vel: {0.0, 0.0, 0.0}
    })
    |> World.add_wall(%World.Wall{
      id: :wall_x,
      vertices: [{-1.0, -1.0, -1.0}, {-1.0, 1.0, -1.0}, {-1.0, 1.0, 1.0}, {-1.0, -1.0, 1.0}],
      normal: {1.0, 0.0, 0.0},
      material: :brick
    })
  end

  test "ignores time_s (tick noise)" do
    world = Scenario.world("orbit")
    assert SceneSnapshot.from_world(world) == SceneSnapshot.from_world(%{world | time_s: 123.4})
  end

  test "ignores node velocities (simulation noise, not edits)" do
    a = base_world()
    {:ok, b} = World.move_node(a, :tx1, {0.0, 0.0, 0.0}, {5.0, -2.0, 0.0})

    assert SceneSnapshot.from_world(a) == SceneSnapshot.from_world(b)
  end

  test "atom-id and string-id worlds with the same geometry compare equal" do
    a = base_world()

    b =
      World.new()
      |> World.add_node(%World.Node{
        id: "tx1",
        type: :tx,
        pos: {0.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })
      |> World.add_node(%World.Node{
        id: "rx1",
        type: :rx,
        pos: {3.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })
      |> World.add_wall(%World.Wall{
        id: "wall_x",
        vertices: [{-1.0, -1.0, -1.0}, {-1.0, 1.0, -1.0}, {-1.0, 1.0, 1.0}, {-1.0, -1.0, 1.0}],
        normal: {1.0, 0.0, 0.0},
        material: :brick
      })

    assert SceneSnapshot.from_world(a) == SceneSnapshot.from_world(b)
  end

  test "integer and float coordinates compare equal" do
    a =
      World.new()
      |> World.add_node(%World.Node{id: "tx1", type: :tx, pos: {1, 2, 3}, vel: {0, 0, 0}})

    b =
      World.new()
      |> World.add_node(%World.Node{
        id: "tx1",
        type: :tx,
        pos: {1.0, 2.0, 3.0},
        vel: {0.0, 0.0, 0.0}
      })

    assert SceneSnapshot.from_world(a) == SceneSnapshot.from_world(b)
  end

  test "detects node position and z edits" do
    world = base_world()
    snapshot = SceneSnapshot.from_world(world)

    {:ok, moved} = World.move_node(world, :tx1, {1.0, 0.0, 0.0}, {0.0, 0.0, 0.0})
    {:ok, raised} = World.set_node_z(world, :tx1, 2.0)

    refute SceneSnapshot.from_world(moved) == snapshot
    refute SceneSnapshot.from_world(raised) == snapshot
  end

  test "detects wall vertex, material and attenuation edits" do
    world = base_world()
    snapshot = SceneSnapshot.from_world(world)

    {:ok, reshaped} = World.set_wall_z(world, :wall_x, 2.0)
    {:ok, rematerial} = World.set_wall_material(world, :wall_x, :glass)
    {:ok, overridden} = World.set_wall_attenuation(world, :wall_x, 25.0)
    {:ok, auto_again} = World.set_wall_attenuation(overridden, :wall_x, nil)

    refute SceneSnapshot.from_world(reshaped) == snapshot
    refute SceneSnapshot.from_world(rematerial) == snapshot
    refute SceneSnapshot.from_world(overridden) == snapshot
    assert SceneSnapshot.from_world(auto_again) == snapshot
  end

  test "integer and float attenuation overrides compare equal" do
    {:ok, a} = World.set_wall_attenuation(base_world(), :wall_x, 4)
    {:ok, b} = World.set_wall_attenuation(base_world(), :wall_x, 4.0)

    assert SceneSnapshot.from_world(a) == SceneSnapshot.from_world(b)
  end

  test "detects wall add and remove" do
    world = base_world()
    snapshot = SceneSnapshot.from_world(world)

    added =
      World.add_wall(world, %World.Wall{
        id: "wall_1",
        vertices: [{0.0, 0.0, -1.0}, {1.0, 0.0, -1.0}, {1.0, 0.0, 1.0}],
        normal: {0.0, -1.0, 0.0},
        material: :concrete
      })

    {:ok, removed} = World.remove_wall(added, "wall_1")

    refute SceneSnapshot.from_world(added) == snapshot
    assert SceneSnapshot.from_world(removed) == snapshot
  end
end
