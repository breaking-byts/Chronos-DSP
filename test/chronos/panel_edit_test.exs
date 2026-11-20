defmodule Chronos.PanelEditTest do
  @moduledoc """
  Pure server-side property-edit validation for the editing panel (#35).
  Every edit preserves x/y; ranges mirror ChronosWeb.ApiParams; the client is
  never trusted.
  """
  use ExUnit.Case, async: true

  alias Chronos.Material
  alias Chronos.PanelEdit
  alias Chronos.Scenario
  alias Chronos.World

  defp world, do: Scenario.world("orbit")
  defp bounds, do: Scenario.bounds("orbit")

  describe "range constants" do
    test "match the design lock" do
      assert PanelEdit.attenuation_range() == {0.0, 40.0}
      assert PanelEdit.z_range() == {-5.0, 5.0}
      assert PanelEdit.max_walls() == 1024
    end
  end

  describe "set_wall_attenuation/3" do
    test "sets an explicit override that replaces the reflection loss only" do
      {:ok, updated} = PanelEdit.set_wall_attenuation(world(), "wall_x", 25.0)
      wall = World.wall(updated, :wall_x)
      assert wall.attenuation_db == 25.0
      assert Material.reflection_loss_db(wall) == 25.0
      # Transmission and diffraction still come from the material (brick).
      assert Material.transmission_loss_db(wall) == 10.0
      assert Material.diffraction_loss_db(wall) == 4.0
    end

    test "nil clears the override (Auto: use the material)" do
      {:ok, explicit} = PanelEdit.set_wall_attenuation(world(), "wall_x", 25.0)
      {:ok, auto} = PanelEdit.set_wall_attenuation(explicit, "wall_x", nil)
      wall = World.wall(auto, :wall_x)
      assert wall.attenuation_db == nil
      assert Material.reflection_loss_db(wall) == 4.0
    end

    test "accepts the boundary values 0 and 40" do
      for db <- [0, 0.0, 40, 40.0] do
        assert {:ok, updated} = PanelEdit.set_wall_attenuation(world(), "wall_x", db)
        assert World.wall(updated, :wall_x).attenuation_db == db
      end
    end

    test "rejects out-of-range, negative, and non-number values" do
      for db <- [-0.5, -1, 40.5, 100, 1.0e308, "12", :foo, true] do
        assert {:error, :invalid_value} = PanelEdit.set_wall_attenuation(world(), "wall_x", db)
      end
    end

    test "rejects unknown and non-string wall ids" do
      assert {:error, :unknown_entity} = PanelEdit.set_wall_attenuation(world(), "nope", 5)
      assert {:error, :invalid_payload} = PanelEdit.set_wall_attenuation(world(), :wall_x, 5)
    end
  end

  describe "set_node_z/3" do
    test "sets z while preserving x/y and velocity" do
      original = World.node(world(), :rx1)
      {:ok, updated} = PanelEdit.set_node_z(world(), "rx1", 2.5)
      node = World.node(updated, :rx1)
      {x, y, _} = original.pos
      assert node.pos == {x, y, 2.5}
      assert node.vel == original.vel
    end

    test "accepts the boundary values -5 and +5" do
      for z <- [-5, 5, -5.0, 5.0] do
        assert {:ok, updated} = PanelEdit.set_node_z(world(), "tx1", z)
        assert elem(World.node(updated, :tx1).pos, 2) == z
      end
    end

    test "rejects out-of-range and non-number values" do
      for z <- [-5.1, 5.1, 100, -100, 1.0e308, "1", nil, :foo] do
        assert {:error, :invalid_value} = PanelEdit.set_node_z(world(), "tx1", z)
      end
    end

    test "rejects unknown and non-string node ids" do
      assert {:error, :unknown_entity} = PanelEdit.set_node_z(world(), "nope", 1)
      assert {:error, :invalid_payload} = PanelEdit.set_node_z(world(), :tx1, 1)
    end
  end

  describe "set_wall_z/3" do
    test "translates every vertex by the same delta, preserving x/y and extent" do
      # wall_x spans z -1..1 (reference height 0).
      {:ok, updated} = PanelEdit.set_wall_z(world(), "wall_x", 3.0)
      wall = World.wall(updated, :wall_x)
      assert Enum.map(wall.vertices, &elem(&1, 2)) == [2.0, 2.0, 4.0, 4.0]
      assert World.wall_z(wall) == 3.0

      original = World.wall(world(), :wall_x)

      for {{ox, oy, _}, {nx, ny, _}} <- Enum.zip(original.vertices, wall.vertices) do
        assert {ox, oy} == {nx, ny}
      end

      # Vertical extent (2 m) and normal are unchanged.
      assert wall.normal == original.normal
    end

    test "a flat wall (single shared z) lands exactly at the requested height" do
      flat = %World.Wall{
        id: "flat",
        vertices: [{0.0, 0.0, 1.0}, {1.0, 0.0, 1.0}, {1.0, 1.0, 1.0}],
        normal: {0.0, 0.0, 1.0}
      }

      w = World.add_wall(World.new(), flat)
      {:ok, updated} = PanelEdit.set_wall_z(w, "flat", -2.5)
      assert Enum.map(World.wall(updated, "flat").vertices, &elem(&1, 2)) == [-2.5, -2.5, -2.5]
    end

    test "accepts the boundary values and rejects out-of-range values" do
      for z <- [-5, 5] do
        assert {:ok, _} = PanelEdit.set_wall_z(world(), "wall_x", z)
      end

      for z <- [-5.5, 5.5, "0", nil] do
        assert {:error, :invalid_value} = PanelEdit.set_wall_z(world(), "wall_x", z)
      end
    end

    test "rejects unknown and non-string wall ids" do
      assert {:error, :unknown_entity} = PanelEdit.set_wall_z(world(), "nope", 1)
      assert {:error, :invalid_payload} = PanelEdit.set_wall_z(world(), :wall_x, 1)
    end
  end

  describe "set_wall_material/3" do
    test "accepts string and atom catalogue ids and updates the losses" do
      for id <- ["metal", :metal] do
        {:ok, updated} = PanelEdit.set_wall_material(world(), "wall_x", id)
        wall = World.wall(updated, :wall_x)
        assert wall.material == :metal
        assert Material.reflection_loss_db(wall) == 0.5
        assert Material.transmission_loss_db(wall) == 40.0
      end
    end

    test "an explicit attenuation override survives a material change" do
      {:ok, w} = PanelEdit.set_wall_attenuation(world(), "wall_x", 12.0)
      {:ok, updated} = PanelEdit.set_wall_material(w, "wall_x", "glass")
      wall = World.wall(updated, :wall_x)
      assert wall.attenuation_db == 12.0
      assert Material.reflection_loss_db(wall) == 12.0
      assert Material.transmission_loss_db(wall) == 3.0
    end

    test "rejects ids outside the 11-material catalogue" do
      for id <- ["unobtainium", "", "concrete ", nil, 123, :vibranium] do
        assert {:error, :invalid_value} = PanelEdit.set_wall_material(world(), "wall_x", id)
      end
    end

    test "rejects unknown and non-string wall ids" do
      assert {:error, :unknown_entity} = PanelEdit.set_wall_material(world(), "nope", "glass")
      assert {:error, :invalid_payload} = PanelEdit.set_wall_material(world(), :wall_x, "glass")
    end
  end

  describe "add_wall/2" do
    test "adds a short default wall near the viewport center, nodes untouched" do
      original = world()
      {:ok, updated} = PanelEdit.add_wall(original, bounds())

      assert map_size(updated.walls) == map_size(original.walls) + 1
      assert updated.nodes == original.nodes

      wall = World.wall(updated, "wall_1")
      assert wall.material == :concrete
      assert wall.attenuation_db == nil
      assert wall.normal == {1.0, 0.0, 0.0}

      # 1 m long (y), 1 m tall (z), centered near the bounds center.
      ys = Enum.map(wall.vertices, &elem(&1, 1))
      zs = Enum.map(wall.vertices, &elem(&1, 2))
      assert_in_delta Enum.max(ys) - Enum.min(ys), 1.0, 1.0e-9
      assert_in_delta Enum.max(zs) - Enum.min(zs), 1.0, 1.0e-9

      %{min: {min_x, min_y}, max: {max_x, max_y}} = bounds()
      cx = (min_x + max_x) / 2.0
      cy = (min_y + max_y) / 2.0

      for {x, y, _} <- wall.vertices do
        assert abs(x - cx) <= 2.0
        assert abs(y - cy) <= 0.5 + 1.0e-9
      end
    end

    test "repeated adds get unique ids and stay bounded" do
      {:ok, w1} = PanelEdit.add_wall(world(), bounds())
      {:ok, w2} = PanelEdit.add_wall(w1, bounds())
      assert World.wall(w2, "wall_1")
      assert World.wall(w2, "wall_2")
      assert map_size(w2.walls) == 4
    end

    test "rejects adds at the scene wall cap without touching the world" do
      full =
        Enum.reduce(1..PanelEdit.max_walls(), World.new(), fn i, acc ->
          World.add_wall(acc, %World.Wall{
            id: "w#{i}",
            vertices: [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0}],
            normal: {0.0, 0.0, 1.0}
          })
        end)

      assert {:error, :wall_cap_reached} = PanelEdit.add_wall(full, bounds())
      assert map_size(full.walls) == PanelEdit.max_walls()
    end
  end

  describe "remove_wall/2" do
    test "removes by id and never touches nodes" do
      original = world()
      {:ok, updated} = PanelEdit.remove_wall(original, "wall_x")
      assert World.wall(updated, :wall_x) == nil
      assert World.wall(updated, :wall_y)
      assert updated.nodes == original.nodes
    end

    test "rejects unknown and non-string ids" do
      assert {:error, :unknown_entity} = PanelEdit.remove_wall(world(), "nope")
      assert {:error, :invalid_payload} = PanelEdit.remove_wall(world(), :wall_x)
    end
  end
end
