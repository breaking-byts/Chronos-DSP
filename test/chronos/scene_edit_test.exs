defmodule Chronos.SceneEditTest do
  use ExUnit.Case, async: true

  alias Chronos.SceneEdit
  alias Chronos.World

  @bounds %{min: {-3.0, -3.0}, max: {3.0, 3.0}}
  @margin SceneEdit.bounds_margin()
  @min_edge SceneEdit.min_wall_edge()

  setup do
    world =
      World.new()
      |> World.add_node(%World.Node{
        id: :tx1,
        type: :tx,
        pos: {0.0, 0.0, 0.5},
        vel: {0.0, 0.0, 0.0}
      })
      |> World.add_node(%World.Node{
        id: :rx1,
        type: :rx,
        pos: {2.0, 0.0, 0.0},
        vel: {0.1, 0.2, 0.0}
      })
      |> World.add_wall(%World.Wall{
        id: :w1,
        vertices: [{-1.0, -1.0, -0.5}, {1.0, -1.0, -0.5}, {1.0, 1.0, 0.5}, {-1.0, 1.0, 0.5}],
        normal: {0.0, 0.0, 1.0},
        material: :concrete
      })

    {:ok, world: world}
  end

  describe "node commits" do
    test "moves the node in XY, preserves z and zeroes velocity", %{world: world} do
      payload = %{"kind" => "node", "id" => "rx1", "pos" => [1.5, -0.5]}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      node = World.node(updated, :rx1)
      assert node.pos == {1.5, -0.5, 0.0}
      assert node.vel == {0.0, 0.0, 0.0}
      # Other entities untouched.
      assert World.node(updated, :tx1) == World.node(world, :tx1)
      assert updated.walls == world.walls
    end

    test "clamps out-of-bounds positions to bounds plus margin", %{world: world} do
      payload = %{"kind" => "node", "id" => "tx1", "pos" => [100.0, -100.0]}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      assert World.node(updated, :tx1).pos == {3.0 + @margin, -3.0 - @margin, 0.5}
    end

    test "rejects unknown ids and malformed payloads", %{world: world} do
      assert {:error, :unknown_entity} =
               SceneEdit.apply(world, @bounds, %{
                 "kind" => "node",
                 "id" => "nope",
                 "pos" => [0, 0]
               })

      for payload <- [
            %{"kind" => "node", "id" => "tx1", "pos" => ["x", 0]},
            %{"kind" => "node", "id" => "tx1", "pos" => [0]},
            %{"kind" => "node", "id" => :tx1, "pos" => [0, 0]},
            %{"kind" => "node", "id" => "tx1"},
            %{"kind" => "bogus"},
            %{}
          ] do
        assert {:error, :invalid_payload} = SceneEdit.apply(world, @bounds, payload)
      end
    end
  end

  describe "whole-wall commits" do
    test "translates every vertex and preserves z", %{world: world} do
      payload = %{
        "kind" => "wall",
        "id" => "w1",
        "vertices" => [[-0.5, -0.75], [1.5, -0.75], [1.5, 1.25], [-0.5, 1.25]]
      }

      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      wall = World.wall(updated, :w1)

      assert wall.vertices == [
               {-0.5, -0.75, -0.5},
               {1.5, -0.75, -0.5},
               {1.5, 1.25, 0.5},
               {-0.5, 1.25, 0.5}
             ]
    end

    test "clamps the shared translation so every vertex stays in bounds", %{world: world} do
      payload = %{
        "kind" => "wall",
        "id" => "w1",
        "vertices" => [[99.0, 99.0], [101.0, 99.0], [101.0, 101.0], [99.0, 101.0]]
      }

      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      wall = World.wall(updated, :w1)

      Enum.each(wall.vertices, fn {x, y, _z} ->
        assert x >= -3.0 - @margin and x <= 3.0 + @margin
        assert y >= -3.0 - @margin and y <= 3.0 + @margin
      end)

      # Still a pure translation: edge lengths are unchanged.
      [{x0, y0, _}, {x1, y1, _} | _] = wall.vertices
      assert_in_delta :math.sqrt((x1 - x0) ** 2 + (y1 - y0) ** 2), 2.0, 1.0e-9
    end

    test "rejects non-translations, wrong vertex counts and bad values", %{world: world} do
      non_translation = %{
        "kind" => "wall",
        "id" => "w1",
        "vertices" => [[-0.5, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]
      }

      assert {:error, :invalid_payload} = SceneEdit.apply(world, @bounds, non_translation)

      wrong_count = %{"kind" => "wall", "id" => "w1", "vertices" => [[0.0, 0.0]]}
      assert {:error, :invalid_payload} = SceneEdit.apply(world, @bounds, wrong_count)

      bad_value = %{
        "kind" => "wall",
        "id" => "w1",
        "vertices" => [[0.0, 0.0], [1.0, 0.0], [1.0, "x"], [0.0, 1.0]]
      }

      assert {:error, :invalid_payload} = SceneEdit.apply(world, @bounds, bad_value)

      assert {:error, :unknown_entity} =
               SceneEdit.apply(world, @bounds, %{
                 "kind" => "wall",
                 "id" => "nope",
                 "vertices" => [[0.0, 0.0]]
               })
    end

    test "rejects a whole-wall drag on a zero-vertex wall instead of raising" do
      wall = %World.Wall{id: :w1, vertices: [], normal: {0.0, 0.0, 1.0}}
      world = World.add_wall(World.new(), wall)

      assert {:error, :invalid_payload} =
               SceneEdit.apply(world, @bounds, %{
                 "kind" => "wall",
                 "id" => "w1",
                 "vertices" => []
               })
    end
  end

  describe "wall endpoint commits" do
    test "moves exactly one vertex and preserves its z", %{world: world} do
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 2, "pos" => [1.5, 1.5]}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      wall = World.wall(updated, :w1)
      assert Enum.at(wall.vertices, 2) == {1.5, 1.5, 0.5}

      assert List.delete_at(wall.vertices, 2) ==
               List.delete_at(World.wall(world, :w1).vertices, 2)
    end

    test "minimum-length guard keeps edges from collapsing", %{world: world} do
      # Drop vertex 0 onto vertex 1: the guard must push it back out so the
      # shared edge stays at least @min_edge long.
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 0, "pos" => [1.0, -1.0]}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      [{x0, y0, _}, {x1, y1, _} | _] = World.wall(updated, :w1).vertices
      assert :math.sqrt((x1 - x0) ** 2 + (y1 - y0) ** 2) >= @min_edge - 1.0e-9

      # A near-collapse is pushed out along the edge direction.
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 0, "pos" => [0.95, -1.0]}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      [{x0, y0, _}, {x1, y1, _} | _] = World.wall(updated, :w1).vertices
      assert_in_delta x0, 1.0 - @min_edge, 1.0e-9
      assert_in_delta y0, -1.0, 1.0e-9
      assert :math.sqrt((x1 - x0) ** 2 + (y1 - y0) ** 2) >= @min_edge - 1.0e-9
    end

    test "clamps the endpoint to bounds plus margin", %{world: world} do
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 2, "pos" => [50.0, 50.0]}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      {x, y, _} = Enum.at(World.wall(updated, :w1).vertices, 2)
      assert x <= 3.0 + @margin
      assert y <= 3.0 + @margin
    end

    test "guard keeps both adjacent edges above the minimum", %{world: _world} do
      wall = %World.Wall{
        id: :w1,
        vertices: [{0.0, 0.0, 0.0}, {0.05, 0.08, 0.0}, {0.05, -0.08, 0.0}],
        normal: {0.0, 0.0, 1.0}
      }

      world = World.add_wall(World.new(), wall)
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 0, "pos" => [0.0, 0.0]}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)

      [{x, y, _}, a, b] = World.wall(updated, :w1).vertices

      for neighbour <- [a, b] do
        distance = :math.sqrt((x - elem(neighbour, 0)) ** 2 + (y - elem(neighbour, 1)) ** 2)
        assert distance >= @min_edge - 1.0e-9
      end
    end

    test "guard never pushes an endpoint outside bounds plus margin", %{world: _world} do
      wall = %World.Wall{
        id: :w1,
        vertices: [{3.20, 3.20, 0.0}, {0.0, 0.0, 0.0}, {3.21, 3.21, 0.0}],
        normal: {0.0, 0.0, 1.0}
      }

      world = World.add_wall(World.new(), wall)
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 2, "pos" => [99.0, 99.0]}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload)
      {x, y, _} = Enum.at(World.wall(updated, :w1).vertices, 2)

      assert x <= 3.0 + @margin and y <= 3.0 + @margin
      assert x >= -3.0 - @margin and y >= -3.0 - @margin
    end

    test "rejects vertex drag when no sampled clamped candidate satisfies min edge" do
      # Collapsed clamp box (min - margin == max + margin == -0.25) forces every
      # candidate onto {-0.25, -0.25}, colliding with the adjacent vertex.
      collapsed_bounds = %{min: {0.0, 0.0}, max: {-0.5, -0.5}}

      wall = %World.Wall{
        id: :w1,
        vertices: [{-0.25, -0.25, 0.0}, {-0.25, -0.25, 0.0}, {1.0, 1.0, 0.0}],
        normal: {0.0, 0.0, 1.0}
      }

      world = World.add_wall(World.new(), wall)
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 0, "pos" => [0.5, 0.5]}
      assert {:error, :invalid_payload} = SceneEdit.apply(world, collapsed_bounds, payload)
    end

    test "rejects out-of-range indices and unknown walls", %{world: world} do
      for index <- [-1, 4, "0", 1.5] do
        assert {:error, :invalid_payload} =
                 SceneEdit.apply(world, @bounds, %{
                   "kind" => "wall_vertex",
                   "id" => "w1",
                   "index" => index,
                   "pos" => [0.0, 0.0]
                 })
      end

      assert {:error, :unknown_entity} =
               SceneEdit.apply(world, @bounds, %{
                 "kind" => "wall_vertex",
                 "id" => "nope",
                 "index" => 0,
                 "pos" => [0.0, 0.0]
               })
    end
  end

  describe "snap to grid" do
    test "rounds node positions to the supplied grid step", %{world: world} do
      payload = %{"kind" => "node", "id" => "tx1", "pos" => [1.23, -0.77], "grid_step" => 0.5}
      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload, snap: true, grid_step: 0.5)
      assert World.node(updated, :tx1).pos == {1.0, -1.0, 0.5}
    end

    test "rounds endpoint positions and whole-wall translation deltas", %{world: world} do
      payload = %{"kind" => "wall_vertex", "id" => "w1", "index" => 2, "pos" => [1.23, 1.26]}

      assert {:ok, updated} =
               SceneEdit.apply(world, @bounds, payload, snap: true, grid_step: 0.5)

      assert Enum.at(World.wall(updated, :w1).vertices, 2) == {1.0, 1.5, 0.5}

      # Delta (0.6, 0.6) snaps to (0.5, 0.5) for every vertex.
      payload = %{
        "kind" => "wall",
        "id" => "w1",
        "vertices" => [[-0.4, -0.4], [1.6, -0.4], [1.6, 1.6], [-0.4, 1.6]]
      }

      assert {:ok, updated} =
               SceneEdit.apply(world, @bounds, payload, snap: true, grid_step: 0.5)

      assert World.wall(updated, :w1).vertices == [
               {-0.5, -0.5, -0.5},
               {1.5, -0.5, -0.5},
               {1.5, 1.5, 0.5},
               {-0.5, 1.5, 0.5}
             ]
    end

    test "snap off or invalid grid steps leave positions unrounded", %{world: world} do
      payload = %{"kind" => "node", "id" => "tx1", "pos" => [1.23, -0.77]}

      assert {:ok, updated} = SceneEdit.apply(world, @bounds, payload, grid_step: 0.5)
      assert World.node(updated, :tx1).pos == {1.23, -0.77, 0.5}

      for step <- [0, -0.5, "0.5", 10_000, nil] do
        assert {:ok, updated} =
                 SceneEdit.apply(world, @bounds, payload, snap: true, grid_step: step)

        assert World.node(updated, :tx1).pos == {1.23, -0.77, 0.5}
      end
    end
  end
end
