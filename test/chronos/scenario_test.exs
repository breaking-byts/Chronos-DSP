defmodule Chronos.ScenarioTest do
  use ExUnit.Case, async: true

  alias Chronos.Scenario
  alias Chronos.World

  test "list/0 exposes the catalogue used by the dashboard" do
    scenarios = Scenario.list()

    assert Enum.map(scenarios, & &1.id) == ["orbit", "open_field"]

    for scenario <- scenarios do
      assert is_binary(scenario.name)
      assert scenario.name != ""
      assert is_binary(scenario.description)
      assert scenario.description != ""
    end
  end

  test "ids/0 and default_id/0 agree with the catalogue" do
    assert Scenario.ids() == ["orbit", "open_field"]
    assert Scenario.default_id() == "orbit"
    assert Scenario.default_id() in Scenario.ids()
  end

  test "name/1 resolves ids and falls back to the raw id" do
    assert Scenario.name("orbit") == "Orbit + corner walls"
    assert Scenario.name(:open_field) == "Open field"
    assert Scenario.name("custom") == "custom"
    assert Scenario.name(:custom) == "custom"
  end

  test "bounds/1 returns one stable viewport that contains every scenario" do
    bounds = Scenario.bounds()
    assert %{min: {min_x, min_y}, max: {max_x, max_y}} = bounds
    assert min_x < max_x
    assert min_y < max_y

    for id <- Scenario.ids() do
      assert Scenario.bounds(id) == bounds
      assert_within_bounds(Scenario.world(id), bounds)
    end

    assert Scenario.bounds("unknown") == bounds
  end

  test "orbit world contains a transmitter, a receiver and two walls" do
    world = Scenario.world("orbit")

    assert %World{} = world
    assert world.time_s == 0.0
    assert map_size(world.nodes) == 2
    assert Enum.sort(Enum.map(Map.keys(world.walls), &to_string/1)) == ["wall_x", "wall_y"]

    tx = World.node(world, :tx1)
    rx = World.node(world, :rx1)

    assert tx.type == :tx
    assert tx.pos == {0.0, 0.0, 0.0}
    assert rx.type == :rx
    refute rx.pos == tx.pos
    assert_within_bounds(world, Scenario.bounds("orbit"))
  end

  test "open field world has the same nodes but no walls" do
    world = Scenario.world("open_field")

    assert map_size(world.nodes) == 2
    assert world.walls == %{}
    refute World.node(world, :rx1).pos == {0.0, 0.0, 0.0}
    assert_within_bounds(world, Scenario.bounds("open_field"))

    assert Scenario.world(:open_field) == world
    assert Scenario.world("open_field") == world
  end

  test "unknown worlds fall back to the default orbit scene" do
    assert Scenario.world("does_not_exist") == Scenario.world("orbit")
    assert Scenario.world(:does_not_exist) == Scenario.world("orbit")
    assert Scenario.world(nil) == Scenario.world("orbit")
  end

  test "orbit step moves the receiver along a curve and advances time" do
    world = Scenario.world("orbit")
    rx0 = World.node(world, :rx1)
    dt = 0.25

    stepped = Scenario.step(world, "orbit", dt)
    rx1 = World.node(stepped, :rx1)

    assert_in_delta stepped.time_s, dt, 1.0e-12
    assert World.node(stepped, :tx1) == World.node(world, :tx1)
    refute rx1.pos == rx0.pos
    assert_within_bounds(stepped, Scenario.bounds("orbit"))

    # The path is curved: a large step does not follow the straight-line
    # extrapolation of the receiver's initial velocity.
    linear = add(rx0.pos, scale(rx0.vel, dt))
    assert distance(rx1.pos, linear) > 1.0e-3
  end

  test "orbit velocity is tangent to the receiver path" do
    world = Scenario.world("orbit")
    rx = World.node(world, :rx1)

    next_rx =
      world
      |> Scenario.step("orbit", 1.0e-4)
      |> World.node(:rx1)

    step_dir = normalize(sub(next_rx.pos, rx.pos))
    velocity_dir = normalize(rx.vel)

    assert dot(step_dir, velocity_dir) > 0.9999
  end

  test "repeated orbit steps stay inside the scene bounds and accumulate time" do
    world =
      Enum.reduce(1..200, Scenario.world("orbit"), fn _i, acc ->
        Scenario.step(acc, "orbit", 0.1)
      end)

    assert_in_delta world.time_s, 20.0, 1.0e-9
    assert_within_bounds(world, Scenario.bounds("orbit"))
  end

  test "open_field uses the same orbit kinematics without reflections" do
    world = Scenario.step(Scenario.world("open_field"), "open_field", 0.4)

    assert map_size(world.walls) == 0
    assert_in_delta world.time_s, 0.4, 1.0e-12
    assert_within_bounds(world, Scenario.bounds("open_field"))
  end

  test "atom scenario ids behave like string ids" do
    world = Scenario.world(:orbit)
    assert Scenario.step(world, :orbit, 0.3) == Scenario.step(world, "orbit", 0.3)
  end

  test "unknown scenarios fall back to linear World.step/2" do
    world =
      World.new()
      |> World.add_node(%World.Node{
        id: :rx1,
        type: :rx,
        pos: {1.0, 1.0, 0.0},
        vel: {2.0, -1.0, 0.0}
      })

    stepped = Scenario.step(world, "custom", 0.5)

    assert stepped == World.step(world, 0.5)
    assert World.node(stepped, :rx1).pos == {2.0, 0.5, 0.0}
    assert stepped.time_s == 0.5
  end

  test "a known scenario without the orbit receiver also falls back to linear stepping" do
    world =
      World.new()
      |> World.add_node(%World.Node{
        id: :tx1,
        type: :tx,
        pos: {0.0, 0.0, 0.0},
        vel: {1.0, 0.0, 0.0}
      })

    assert Scenario.step(world, "orbit", 0.5) == World.step(world, 0.5)
  end

  defp assert_within_bounds(%World{} = world, bounds) do
    for node <- Map.values(world.nodes) do
      assert_in_bounds(node.pos, bounds)
    end

    for wall <- Map.values(world.walls), vertex <- wall.vertices do
      assert_in_bounds(vertex, bounds)
    end
  end

  defp assert_in_bounds({x, y, _z}, %{min: {min_x, min_y}, max: {max_x, max_y}}) do
    assert x >= min_x and x <= max_x
    assert y >= min_y and y <= max_y
  end

  defp add({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  defp sub({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}

  defp scale({x, y, z}, factor), do: {x * factor, y * factor, z * factor}

  defp dot({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz

  defp distance(a, b), do: a |> sub(b) |> norm()

  defp norm({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp normalize(vector) do
    magnitude = norm(vector)

    if magnitude == 0.0 do
      {0.0, 0.0, 0.0}
    else
      scale(vector, 1.0 / magnitude)
    end
  end
end
