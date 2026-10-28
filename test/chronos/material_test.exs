defmodule Chronos.MaterialTest do
  use ExUnit.Case, async: true

  alias Chronos.Material
  alias Chronos.Scenario
  alias Chronos.World

  @wall_vertices [
    {0.0, 0.0, 0.0},
    {1.0, 0.0, 0.0},
    {1.0, 1.0, 0.0},
    {0.0, 1.0, 0.0}
  ]
  @wall_normal {0.0, 0.0, 1.0}

  test "catalogue contains the expected ids and is sorted by id" do
    expected_ids = [
      :brick,
      :concrete,
      :drywall,
      :glass,
      :metal,
      :plaster,
      :plywood,
      :reinforced_concrete,
      :soil,
      :water,
      :wood
    ]

    assert Material.ids() == expected_ids
    assert Enum.map(Material.list(), & &1.id) == expected_ids
    assert Material.ids() == Enum.sort(Material.ids())
  end

  test "catalogue preserves the original material losses" do
    expected_losses = %{
      brick: {4.0, 10.0, 4.0},
      concrete: {6.0, 18.0, 6.0},
      drywall: {2.0, 4.0, 2.0},
      glass: {1.0, 3.0, 1.0},
      metal: {0.5, 40.0, 2.0},
      wood: {3.0, 6.0, 3.0}
    }

    for {id, {reflection, transmission, diffraction}} <- expected_losses do
      material = Material.get!(id)

      assert material.reflection_loss_db == reflection
      assert material.transmission_loss_db == transmission
      assert material.diffraction_loss_db == diffraction
    end
  end

  test "get/1 resolves atom and string ids and falls back for unknown ids" do
    assert Material.get(:brick) == Material.get("brick")
    assert Material.get(:brick).id == :brick
    assert Material.get(:unknown_material) == Material.default()
    assert Material.get("unknown_material") == Material.default()
    assert Material.get(nil) == Material.default()
  end

  test "get!/1 resolves known ids and raises for unknown ids" do
    assert Material.get!(:brick) == Material.get("brick")

    assert_raise ArgumentError, ~r/unknown material id/, fn ->
      Material.get!(:unknown_material)
    end

    assert_raise ArgumentError, ~r/unknown material id/, fn ->
      Material.get!("unknown_material")
    end
  end

  test "for_wall/1 resolves known materials and falls back for unknown ids" do
    glass_wall = wall(material: :glass)
    unknown_wall = wall(material: :unknown_material)

    assert Material.for_wall(glass_wall) == Material.get!(:glass)
    assert Material.for_wall(unknown_wall) == Material.default()
  end

  test "reflection_loss_db/1 prefers an explicit attenuation over the material" do
    override_wall = wall(material: :glass, attenuation_db: 12.5)
    material_wall = wall(material: :glass, attenuation_db: nil)

    assert Material.reflection_loss_db(override_wall) == 12.5
    assert Material.reflection_loss_db(material_wall) == Material.get!(:glass).reflection_loss_db
    assert Material.reflection_loss_db(material_wall) == 1.0
  end

  test "transmission and diffraction losses always come from the wall material" do
    metal_wall = wall(material: :metal, attenuation_db: 99.0)

    assert Material.transmission_loss_db(metal_wall) == 40.0
    assert Material.diffraction_loss_db(metal_wall) == 2.0
  end

  test "wall material defaults to concrete and explicit attenuation is optional" do
    wall = %World.Wall{
      id: :default_material,
      vertices: @wall_vertices,
      normal: @wall_normal
    }

    assert wall.material == :concrete
    assert wall.attenuation_db == nil
  end

  test "orbit walls carry their expected materials and drive reflection loss" do
    world = Scenario.world("orbit")
    wall_x = World.wall(world, :wall_x)
    wall_y = World.wall(world, :wall_y)

    assert wall_x.material == :brick
    assert wall_y.material == :concrete
    assert wall_x.attenuation_db == nil
    assert wall_y.attenuation_db == nil
    assert Material.reflection_loss_db(wall_x) == 4.0
    assert Material.reflection_loss_db(wall_y) == 6.0
  end

  defp wall(overrides) do
    defaults = [
      id: :wall,
      vertices: @wall_vertices,
      normal: @wall_normal,
      attenuation_db: 0.0
    ]

    struct!(World.Wall, Keyword.merge(defaults, overrides))
  end
end
