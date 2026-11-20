defmodule Chronos.WorldToSceneTest do
  use ExUnit.Case, async: true

  alias Chronos.Material
  alias Chronos.Scenario
  alias Chronos.SceneSnapshot
  alias Chronos.SceneStore
  alias Chronos.World

  test "to_scene serializes the scenario world with string keys and string ids" do
    world = Scenario.world("orbit")
    scene = World.to_scene(world, "orbit_copy")

    assert :ok = SceneStore.validate(scene)
    assert scene["name"] == "orbit_copy"
    refute Map.has_key?(scene, "description")

    # Sorted by id, atom ids stringified.
    assert Enum.map(scene["nodes"], & &1["id"]) == ["rx1", "tx1"]
    assert Enum.map(scene["walls"], & &1["id"]) == ["wall_x", "wall_y"]

    for node <- scene["nodes"] do
      assert node["type"] in ["tx", "rx"]
      assert Enum.all?(node["pos"], &is_float/1)
      assert Enum.all?(node["vel"], &is_float/1)
    end

    material_ids = Enum.map(Material.ids(), &Atom.to_string/1)

    for wall <- scene["walls"] do
      assert wall["material"] in material_ids
      # Auto walls omit the override key entirely.
      refute Map.has_key?(wall, "attenuation_db")
      assert Enum.all?(wall["vertices"], fn vertex -> Enum.all?(vertex, &is_float/1) end)
      assert Enum.all?(wall["normal"], &is_float/1)
    end
  end

  test "to_scene includes an explicit attenuation override and optional description" do
    world = Scenario.world("orbit")
    {:ok, world} = World.set_wall_attenuation(world, :wall_x, 12.5)

    scene = World.to_scene(world, "override", description: "a lab scene")

    assert scene["description"] == "a lab scene"
    wall = Enum.find(scene["walls"], &(&1["id"] == "wall_x"))
    assert wall["attenuation_db"] == 12.5
    assert :ok = SceneStore.validate(scene)
  end

  test "save/load round-trip preserves geometry, velocities, material and override" do
    world = Scenario.world("orbit")
    {:ok, world} = World.set_wall_attenuation(world, :wall_x, 12.5)
    {:ok, world} = World.set_wall_material(world, :wall_y, :glass)
    {:ok, world} = World.set_node_z(world, :tx1, 2.5)

    world =
      World.add_wall(world, %World.Wall{
        id: "wall_9",
        vertices: [{0.0, 0.0, -1.0}, {1.0, 0.0, -1.0}, {1.0, 0.0, 1.0}, {0.0, 0.0, 1.0}],
        normal: {0.0, -1.0, 0.0},
        material: :wood
      })

    scene = World.to_scene(world, "round_trip")
    assert {:ok, restored} = SceneStore.scene_to_world(scene)

    # Geometry (positions, z, walls, material, attenuation) is identical.
    assert SceneSnapshot.from_world(world) == SceneSnapshot.from_world(restored)

    # Velocities survive the round-trip too (the snapshot ignores them).
    for {id, node} <- world.nodes do
      restored_node = World.node(restored, id) || World.node(restored, to_string(id))
      assert restored_node.vel == node.vel
      assert restored_node.type == node.type
    end
  end

  test "unknown string ids stay strings through the round-trip (no atom growth)" do
    suffix = System.unique_integer([:positive])
    tx_id = "tx_unknown_#{suffix}"
    rx_id = "rx_unknown_#{suffix}"

    world =
      World.new()
      |> World.add_node(%World.Node{
        id: tx_id,
        type: :tx,
        pos: {0.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })
      |> World.add_node(%World.Node{
        id: rx_id,
        type: :rx,
        pos: {3.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })

    scene = World.to_scene(world, "unknown_ids")
    assert {:ok, restored} = SceneStore.scene_to_world(scene)

    assert Map.has_key?(restored.nodes, tx_id)
    assert Map.has_key?(restored.nodes, rx_id)
    assert_raise ArgumentError, fn -> String.to_existing_atom(tx_id) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(rx_id) end
  end

  test "repeated serialization of the same world is byte-stable" do
    world = Scenario.world("orbit")
    assert World.to_scene(world, "stable") == World.to_scene(world, "stable")
  end
end
