defmodule Chronos.WorldEditTest do
  @moduledoc "Structural world helpers added for the editing panel (#35)."
  use ExUnit.Case, async: true

  alias Chronos.Scenario
  alias Chronos.World

  defp world, do: Scenario.world("orbit")

  test "remove_wall/2 deletes by id and reports unknown ids" do
    {:ok, updated} = World.remove_wall(world(), :wall_x)
    assert World.wall(updated, :wall_x) == nil
    assert map_size(updated.walls) == 1
    assert {:error, :unknown_wall} = World.remove_wall(updated, :wall_x)
  end

  test "set_node_z/3 preserves x/y and velocity" do
    node = World.node(world(), :rx1)
    {:ok, updated} = World.set_node_z(world(), :rx1, -3)
    moved = World.node(updated, :rx1)
    {x, y, _} = node.pos
    assert moved.pos == {x, y, -3.0}
    assert moved.vel == node.vel
    assert {:error, :unknown_node} = World.set_node_z(world(), :nope, 0)
  end

  test "wall_z/1 is the mean vertex z (0.0 for an empty wall)" do
    assert World.wall_z(World.wall(world(), :wall_x)) == 0.0

    flat = %World.Wall{
      id: "flat",
      vertices: [{0.0, 0.0, 2.0}, {1.0, 0.0, 4.0}],
      normal: {0.0, 0.0, 1.0}
    }

    assert World.wall_z(flat) == 3.0
    assert World.wall_z(%World.Wall{id: "empty", vertices: [], normal: {0.0, 0.0, 1.0}}) == 0.0
  end

  test "set_wall_z/3 shifts every vertex by the same delta" do
    {:ok, updated} = World.set_wall_z(world(), :wall_x, -2.0)
    wall = World.wall(updated, :wall_x)
    assert Enum.map(wall.vertices, &elem(&1, 2)) == [-3.0, -3.0, -1.0, -1.0]
    assert {:error, :unknown_wall} = World.set_wall_z(world(), :nope, 0)
  end

  test "set_wall_material/3 and set_wall_attenuation/3 update in place" do
    {:ok, updated} = World.set_wall_material(world(), :wall_x, :glass)
    assert World.wall(updated, :wall_x).material == :glass
    {:ok, updated} = World.set_wall_attenuation(updated, :wall_x, 7.5)
    assert World.wall(updated, :wall_x).attenuation_db == 7.5
    {:ok, updated} = World.set_wall_attenuation(updated, :wall_x, nil)
    assert World.wall(updated, :wall_x).attenuation_db == nil

    assert {:error, :unknown_wall} = World.set_wall_material(world(), :nope, :glass)
    assert {:error, :unknown_wall} = World.set_wall_attenuation(world(), :nope, 1)
  end

  test "next_wall_id/1 skips existing string and atom ids" do
    assert World.next_wall_id(World.new()) == "wall_1"

    w =
      world()
      |> World.add_wall(%World.Wall{
        id: "wall_1",
        vertices: [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0}],
        normal: {0.0, 0.0, 1.0}
      })
      |> World.add_wall(%World.Wall{
        id: :wall_2,
        vertices: [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0}],
        normal: {0.0, 0.0, 1.0}
      })

    assert World.next_wall_id(w) == "wall_3"
  end
end
