defmodule Chronos.SceneStoreTest do
  use ExUnit.Case, async: false

  alias Chronos.SceneStore
  alias Chronos.World

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "chronos-scene-store-#{System.unique_integer([:positive])}"
      )

    previous_dir = Application.fetch_env(:chronos, :scene_dir)
    Application.put_env(:chronos, :scene_dir, dir)

    on_exit(fn ->
      restore_application_env(:chronos, :scene_dir, previous_dir)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  test "save, list, and get round-trip a valid scene as JSON", %{dir: dir} do
    scene = valid_scene()

    assert :ok = SceneStore.save(scene)
    assert {:ok, ^scene} = SceneStore.get("lab_scene")
    assert [^scene] = SceneStore.list()

    path = Path.join(dir, "lab_scene.json")
    assert File.exists?(path)

    body = File.read!(path)
    assert body =~ ~r/^\{\n  "/m
    assert body =~ "\"name\": \"lab_scene\""
    assert Path.wildcard(Path.join(dir, "lab_scene.tmp*")) == []
  end

  test "get returns not_found for a missing scene" do
    assert {:error, :not_found} = SceneStore.get("missing_scene")
  end

  test "get and list reject corrupt stored scene content", %{dir: dir} do
    assert :ok = SceneStore.save(valid_scene())
    File.write!(Path.join(dir, "corrupt_scene.json"), Jason.encode!([]))

    assert {:error, :not_found} = SceneStore.get("corrupt_scene")
    assert ["lab_scene"] = Enum.map(SceneStore.list(), & &1["name"])
  end

  test "save rejects invalid names" do
    for name <- ["../evil", "UPPER", "", String.duplicate("a", 65)] do
      scene = Map.put(valid_scene(), "name", name)
      assert {:error, :invalid_name} = SceneStore.save(scene)
    end
  end

  test "save rejects invalid scenes" do
    scene = valid_scene()
    node = hd(scene["nodes"])
    wall = hd(scene["walls"])

    invalid_scenes = [
      %{scene | "nodes" => []},
      put_in(scene, ["nodes", Access.at(0), "type"], "relay"),
      put_in(scene, ["walls", Access.at(0), "vertices"], [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]]),
      put_in(scene, ["nodes", Access.at(1), "id"], node["id"]),
      %{scene | "walls" => [wall, wall]},
      put_in(scene, ["nodes", Access.at(0), "pos"], [0.0, "north", 0.0])
    ]

    for invalid_scene <- invalid_scenes do
      assert {:error, :invalid_scene} = SceneStore.save(invalid_scene)
      assert {:error, :invalid_scene} = SceneStore.validate(invalid_scene)
    end
  end

  test "validate bounds collection sizes and identifier lengths" do
    scene = valid_scene()
    node = hd(scene["nodes"])
    wall = hd(scene["walls"])

    long_id_scene = put_in(scene, ["nodes", Access.at(0), "id"], String.duplicate("x", 200))

    too_many_nodes_scene = %{
      scene
      | "nodes" =>
          Enum.map(1..2000, fn index ->
            %{node | "id" => "node_#{index}"}
          end)
    }

    too_many_walls_scene = %{
      scene
      | "walls" =>
          Enum.map(1..1025, fn index ->
            %{wall | "id" => "wall_#{index}"}
          end)
    }

    assert {:error, :invalid_scene} = SceneStore.validate(long_id_scene)
    assert {:error, :invalid_scene} = SceneStore.validate(too_many_nodes_scene)
    assert {:error, :invalid_scene} = SceneStore.validate(too_many_walls_scene)
  end

  test "delete removes a scene and reports a missing second delete", %{dir: dir} do
    assert :ok = SceneStore.save(valid_scene())
    assert File.exists?(Path.join(dir, "lab_scene.json"))

    assert :ok = SceneStore.delete("lab_scene")
    refute File.exists?(Path.join(dir, "lab_scene.json"))
    assert {:error, :not_found} = SceneStore.delete("lab_scene")
  end

  test "list sorts scenes by name" do
    assert :ok = SceneStore.save(valid_scene("zebra"))
    assert :ok = SceneStore.save(valid_scene("alpha"))

    assert ["alpha", "zebra"] = Enum.map(SceneStore.list(), & &1["name"])
  end

  test "scene_to_world builds matching nodes and walls" do
    scene =
      valid_scene()
      |> put_in(["walls", Access.at(0), "attenuation_db"], nil)

    assert {:ok, world} = SceneStore.scene_to_world(scene)

    tx_id = hd(scene["nodes"])["id"]
    rx_id = Enum.at(scene["nodes"], 1)["id"]
    wall_id = hd(scene["walls"])["id"]

    tx = World.node(world, tx_id)
    assert %World.Node{id: ^tx_id, type: :tx} = tx
    assert tx.pos == {0.0, 0.0, 0.0}
    assert tx.vel == {0.0, 0.0, 0.0}

    rx = World.node(world, rx_id)
    assert %World.Node{id: ^rx_id, type: :rx} = rx
    assert rx.pos == {2.0, 1.0, 0.5}
    assert rx.vel == {0.1, 0.0, 0.0}

    wall = World.wall(world, wall_id)
    assert wall.id == wall_id
    assert wall.vertices == [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0}]
    assert wall.normal == {0.0, 0.0, 1.0}
    assert wall.attenuation_db == 6.0
    refute Map.has_key?(wall, :material)
  end

  test "wall attenuation uses the material reflection loss unless explicitly overridden" do
    material_scene =
      valid_scene()
      |> put_in(["walls", Access.at(0), "material"], "metal")
      |> put_in(["walls", Access.at(0), "attenuation_db"], nil)

    wall_id = hd(material_scene["walls"])["id"]

    assert {:ok, world} = SceneStore.scene_to_world(material_scene)
    assert World.wall(world, wall_id).attenuation_db == 0.5
    refute Map.has_key?(World.wall(world, wall_id), :material)

    override_scene =
      material_scene
      |> put_in(["walls", Access.at(0), "attenuation_db"], 12.5)

    assert {:ok, overridden_world} = SceneStore.scene_to_world(override_scene)
    assert World.wall(overridden_world, wall_id).attenuation_db == 12.5
  end

  test "scene_to_world keeps fresh string ids without growing the atom table" do
    warmup_scene = %{
      "name" => "warmup_ids",
      "nodes" => [
        %{
          "id" => "warmup_node",
          "type" => "tx",
          "pos" => [0.0, 0.0, 0.0],
          "vel" => [0.0, 0.0, 0.0]
        }
      ],
      "walls" => []
    }

    assert {:ok, _world} = SceneStore.scene_to_world(warmup_scene)

    node_id = "fresh_node_#{System.unique_integer([:positive])}"

    scene = %{
      "name" => "fresh_ids",
      "nodes" => [
        %{
          "id" => node_id,
          "type" => "tx",
          "pos" => [0.0, 0.0, 0.0],
          "vel" => [0.0, 0.0, 0.0]
        }
      ],
      "walls" => []
    }

    atom_count_before = :erlang.system_info(:atom_count)
    assert {:ok, world} = SceneStore.scene_to_world(scene)
    atom_count_after = :erlang.system_info(:atom_count)

    assert atom_count_after <= atom_count_before
    assert %World.Node{id: ^node_id} = World.node(world, node_id)
  end

  test "reads the scene directory from application environment at call time", %{dir: original_dir} do
    other_dir =
      Path.join(
        System.tmp_dir!(),
        "chronos-scene-store-moved-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(other_dir) end)

    Application.put_env(:chronos, :scene_dir, other_dir)

    assert [] = SceneStore.list()
    assert :ok = SceneStore.save(valid_scene())
    assert File.exists?(Path.join(other_dir, "lab_scene.json"))
    refute File.exists?(Path.join(original_dir, "lab_scene.json"))
  end

  defp valid_scene(name \\ "lab_scene") do
    unique_id = System.unique_integer([:positive])

    %{
      "name" => name,
      "description" => "A two-link laboratory scene.",
      "nodes" => [
        %{
          "id" => "tx_#{unique_id}",
          "type" => "tx",
          "pos" => [0.0, 0.0, 0.0],
          "vel" => [0.0, 0.0, 0.0]
        },
        %{
          "id" => "rx_#{unique_id}",
          "type" => "rx",
          "pos" => [2.0, 1.0, 0.5],
          "vel" => [0.1, 0.0, 0.0]
        }
      ],
      "walls" => [
        %{
          "id" => "wall_#{unique_id}",
          "vertices" => [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 1.0, 0.0]],
          "normal" => [0.0, 0.0, 1.0],
          "attenuation_db" => 3.5,
          "material" => "concrete"
        }
      ]
    }
  end

  defp restore_application_env(app, key, {:ok, value}) do
    Application.put_env(app, key, value)
  end

  defp restore_application_env(app, key, :error) do
    Application.delete_env(app, key)
  end
end
