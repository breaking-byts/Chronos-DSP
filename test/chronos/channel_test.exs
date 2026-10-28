defmodule Chronos.ChannelTest do
  use ExUnit.Case, async: true

  alias Chronos.Channel
  alias Chronos.World

  test "los path returns nil when occluded" do
    wall = %World.Wall{
      id: :w1,
      vertices: [{0.0, -1.0, -1.0}, {0.0, 1.0, -1.0}, {0.0, 1.0, 1.0}, {0.0, -1.0, 1.0}],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 3.0
    }

    tx = %World.Node{id: :tx, type: :tx, pos: {-1.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}}
    rx = %World.Node{id: :rx, type: :rx, pos: {1.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}}

    assert nil == Channel.los_path(tx, rx, [wall], speed_of_light: 1.0)
  end

  test "los path computes delay and gain" do
    tx = %World.Node{id: :tx, type: :tx, pos: {0.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}}
    rx = %World.Node{id: :rx, type: :rx, pos: {0.0, 3.0, 0.0}, vel: {0.0, 0.0, 0.0}}

    path = Channel.los_path(tx, rx, [], speed_of_light: 1.0, global_gain: 1.0)
    assert path.delay_s == 3.0
    assert_in_delta path.gain, 1.0 / 3.0, 1.0e-9
  end

  test "free space gain handles zero distance" do
    assert Channel.free_space_gain(0.0) == 1.0
  end

  test "segment occluded detects intersection" do
    wall = %World.Wall{
      id: :w1,
      vertices: [{0.0, -1.0, -1.0}, {0.0, 1.0, -1.0}, {0.0, 1.0, 1.0}, {0.0, -1.0, 1.0}],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 0.0
    }

    assert Channel.segment_occluded?({-1.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, [wall], nil)
  end

  test "paths_for_rx returns los path" do
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
        pos: {0.0, 1.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })

    {:ok, [path]} = Channel.paths_for_rx(world, :rx1, speed_of_light: 1.0)
    assert path.delay_s == 1.0
  end

  test "paths_for_rx returns unknown_rx error for missing receiver" do
    world =
      World.new()
      |> World.add_node(%World.Node{
        id: :tx1,
        type: :tx,
        pos: {0.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })

    assert {:error, :unknown_rx} = Channel.paths_for_rx(world, :missing_rx, speed_of_light: 1.0)
  end

  test "paths_for_rx! raises for missing receiver" do
    world = World.new()
    assert_raise ArgumentError, fn -> Channel.paths_for_rx!(world, :missing_rx) end
  end

  test "reflection path exists for single wall" do
    wall = %World.Wall{
      id: :w1,
      vertices: [{0.0, -2.0, -2.0}, {0.0, 2.0, -2.0}, {0.0, 2.0, 2.0}, {0.0, -2.0, 2.0}],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 0.0
    }

    tx = %World.Node{id: :tx, type: :tx, pos: {-1.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}}
    rx = %World.Node{id: :rx, type: :rx, pos: {-2.0, 1.0, 0.0}, vel: {0.0, 0.0, 0.0}}

    [path] = Channel.reflection_paths(tx, rx, [wall], speed_of_light: 1.0)
    assert path.delay_s > 0.0
  end

  test "doppler is zero for zero relative velocity" do
    tx = {0.0, 0.0, 0.0}
    rx = {1.0, 0.0, 0.0}
    vel = {0.0, 0.0, 0.0}

    assert Channel.doppler(tx, vel, rx, vel, carrier_freq_hz: 1.0, speed_of_light: 1.0) == 0.0
  end

  test "db_to_linear converts 20 dB to 10x" do
    assert_in_delta Channel.db_to_linear(20.0), 10.0, 1.0e-6
  end

  # -------------------------------------------------------------------------
  # Path model integration
  # -------------------------------------------------------------------------

  test "paths_for_rx combines line of sight, reflections, diffraction and transmission" do
    world = corner_world()

    {:ok, paths} = Channel.paths_for_rx(world, :rx1, speed_of_light: 1.0)
    kinds = paths |> Enum.map(& &1.kind) |> Enum.uniq()

    assert :los in kinds
    assert :reflection in kinds

    # Every path is finite and has a positive delay.
    for path <- paths do
      assert path.delay_s > 0.0
      assert path.gain > 0.0
      assert is_finite(path.gain)
      assert is_finite(path.doppler_hz)
      assert length(path.points) >= 2
    end
  end

  test "max_bounces limits the reflection order" do
    world = corner_world()

    {:ok, paths} = Channel.paths_for_rx(world, :rx1, speed_of_light: 1.0, max_bounces: 1)
    assert Enum.all?(paths, &(&1.kind != :reflection or &1.bounces == 1))

    {:ok, paths} = Channel.paths_for_rx(world, :rx1, speed_of_light: 1.0, max_bounces: 2)
    assert Enum.any?(paths, &(&1.kind == :reflection and &1.bounces == 2))
  end

  test "max_paths caps the number of returned paths" do
    world = corner_world()

    {:ok, paths} = Channel.paths_for_rx(world, :rx1, speed_of_light: 1.0, max_paths: 1)
    assert length(paths) == 1
  end

  test "diffraction and transmission can be switched off" do
    world = corner_world()

    {:ok, paths} =
      Channel.paths_for_rx(world, :rx1,
        speed_of_light: 1.0,
        diffraction: false,
        transmission: false
      )

    assert Enum.all?(paths, &(&1.kind in [:los, :reflection]))
  end

  test "paths are deterministic for the same world" do
    world = corner_world()

    {:ok, first} = Channel.paths_for_rx(world, :rx1, speed_of_light: 1.0)
    {:ok, second} = Channel.paths_for_rx(world, :rx1, speed_of_light: 1.0)

    assert first == second
  end

  defp corner_world do
    wall_x = %World.Wall{
      id: :wall_x,
      vertices: [{0.0, -2.0, -2.0}, {0.0, 2.0, -2.0}, {0.0, 2.0, 2.0}, {0.0, -2.0, 2.0}],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 3.0
    }

    wall_y = %World.Wall{
      id: :wall_y,
      vertices: [{-2.0, 0.0, -2.0}, {2.0, 0.0, -2.0}, {2.0, 0.0, 2.0}, {-2.0, 0.0, 2.0}],
      normal: {0.0, 1.0, 0.0},
      attenuation_db: 6.0
    }

    tx = %World.Node{id: :tx1, type: :tx, pos: {1.0, 1.0, 0.0}, vel: {0.0, 0.0, 0.0}}
    rx = %World.Node{id: :rx1, type: :rx, pos: {2.0, 1.0, 0.0}, vel: {0.0, 0.0, 0.0}}

    World.new()
    |> World.add_node(tx)
    |> World.add_node(rx)
    |> World.add_wall(wall_x)
    |> World.add_wall(wall_y)
  end

  defp is_finite(number) when is_number(number) do
    number == number and abs(number) < 1.0e308
  end
end
