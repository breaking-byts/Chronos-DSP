defmodule Chronos.ChannelScenarioTest do
  use ExUnit.Case, async: true

  alias Chronos.Channel
  alias Chronos.Scenario
  alias Chronos.SimFrame
  alias Chronos.World

  test "orbit tick zero has line of sight plus at least one reflection" do
    world = Scenario.world("orbit")
    tx = World.node(world, :tx1)
    rx = World.node(world, :rx1)
    walls = Map.values(world.walls)

    assert Channel.los_path(tx, rx, walls, []) != nil

    paths = Channel.paths_for_rx!(world, :rx1, [])
    assert length(paths) >= 2

    frame = SimFrame.from_world(world, tick: 0, seed: 7)
    assert frame.metrics.path_count >= 2
    assert length(frame.paths) >= 2
    assert Enum.any?(frame.paths, &(&1.kind == "los"))
    assert Enum.any?(frame.paths, &(&1.kind == "reflection"))
  end

  test "open field only has the direct path" do
    world = Scenario.world("open_field")

    assert Channel.los_path(
             World.node(world, :tx1),
             World.node(world, :rx1),
             Map.values(world.walls),
             []
           ) != nil

    assert length(Channel.paths_for_rx!(world, :rx1, [])) == 1
  end

  test "a wall between transmitter and receiver blocks the direct path" do
    wall = blocking_wall(:blocker, 0.0)
    tx = node(:tx1, :tx, {-1.0, 0.0, 0.0})
    rx = node(:rx1, :rx, {1.0, 0.0, 0.0})

    world =
      World.new()
      |> World.add_node(tx)
      |> World.add_node(rx)
      |> World.add_wall(wall)

    assert Channel.segment_occluded?(tx.pos, rx.pos, [wall], nil)
    assert Channel.los_path(tx, rx, [wall], []) == nil
    assert {:ok, []} = Channel.paths_for_rx(world, :rx1, [])
  end

  test "reflections are not generated through an occluding wall" do
    reflector = reflector_wall()
    blocker = blocking_wall(:blocker, 0.5)

    tx = node(:tx1, :tx, {0.0, 2.0, 0.0})
    rx = node(:rx1, :rx, {2.0, 2.0, 0.0})

    # Control: the reflector alone produces exactly one valid reflection.
    assert [_reflection] = Channel.reflection_paths(tx, rx, [reflector], [])

    # The blocker crosses the transmitter leg of that reflection, so it is dropped.
    assert Channel.reflection_paths(tx, rx, [reflector, blocker], []) == []

    world =
      World.new()
      |> World.add_node(tx)
      |> World.add_node(rx)
      |> World.add_wall(reflector)
      |> World.add_wall(blocker)

    # Line of sight survives (the blocker does not reach y = 2).
    paths = Channel.paths_for_rx!(world, :rx1, [])
    assert length(paths) == 1
    assert Channel.los_path(tx, rx, [reflector, blocker], []) != nil
  end

  defp blocking_wall(id, x) do
    %World.Wall{
      id: id,
      vertices: [
        {x, -1.5, -1.0},
        {x, 1.5, -1.0},
        {x, 1.5, 1.0},
        {x, -1.5, 1.0}
      ],
      normal: {-1.0, 0.0, 0.0},
      attenuation_db: 20.0
    }
  end

  defp reflector_wall do
    %World.Wall{
      id: :reflector,
      vertices: [
        {-5.0, 0.0, -1.0},
        {5.0, 0.0, -1.0},
        {5.0, 0.0, 1.0},
        {-5.0, 0.0, 1.0}
      ],
      normal: {0.0, 1.0, 0.0},
      attenuation_db: 0.0
    }
  end

  defp node(id, type, pos) do
    %World.Node{id: id, type: type, pos: pos, vel: {0.0, 0.0, 0.0}}
  end
end
