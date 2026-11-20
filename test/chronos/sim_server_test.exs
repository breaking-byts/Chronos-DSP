defmodule Chronos.SimServerTest do
  use ExUnit.Case, async: true

  alias Chronos.Scenario
  alias Chronos.Scene
  alias Chronos.SimServer
  alias Chronos.World

  test "emits frames with increasing tick" do
    {:ok, pid} = Chronos.SimServer.start_link(seed: 7, tick_ms: 10)
    {:ok, frame1} = Chronos.SimServer.next_frame(pid)
    {:ok, frame2} = Chronos.SimServer.next_frame(pid)
    assert frame1.tick == 0
    assert frame2.tick == 1
  end

  describe "update_world/2 (drag commits, #34)" do
    test "replaces the world, recomputes bounds and marks the session custom" do
      {:ok, pid} = SimServer.start_link(seed: 7, tick_ms: 10)
      {:ok, original, _bounds} = SimServer.get_world(pid)

      edited =
        original
        |> World.move_node(:tx1, {1.0, 1.0, 0.0}, {0.0, 0.0, 0.0})
        |> elem(1)

      assert :ok = SimServer.update_world(pid, edited)
      assert {:ok, ^edited, bounds} = SimServer.get_world(pid)
      assert bounds == Scene.bounds(edited)

      {:ok, frame} = SimServer.next_frame(pid)
      assert frame.bounds == Scene.to_map(bounds)
      tx = Enum.find(frame.nodes, &(&1.id == "tx1"))
      assert tx.pos == [1.0, 1.0, 0.0]
    end

    test "edited worlds step by velocity, not scenario kinematics" do
      {:ok, pid} = SimServer.start_link(seed: 7, tick_ms: 10)
      {:ok, world, _bounds} = SimServer.get_world(pid)
      # Park the receiver with zero velocity; the orbit must not reclaim it.
      {:ok, edited} = World.move_node(world, :rx1, {2.5, 2.5, 0.0}, {0.0, 0.0, 0.0})
      assert :ok = SimServer.update_world(pid, edited)

      {:ok, _frame} = SimServer.next_frame(pid)
      {:ok, frame} = SimServer.next_frame(pid)
      rx = Enum.find(frame.nodes, &(&1.id == "rx1"))
      assert rx.pos == [2.5, 2.5, 0.0]
    end

    test "reset restores the pre-edit baseline and the scenario stepping" do
      {:ok, pid} = SimServer.start_link(seed: 7, tick_ms: 10)
      {:ok, baseline, _bounds} = SimServer.get_world(pid)
      {:ok, edited} = World.move_node(baseline, :tx1, {1.0, 1.0, 0.0}, {0.0, 0.0, 0.0})
      assert :ok = SimServer.update_world(pid, edited)
      {:ok, _frame} = SimServer.next_frame(pid)

      assert :ok = SimServer.reset(pid)
      assert {:ok, ^baseline, _bounds} = SimServer.get_world(pid)
      {:ok, frame} = SimServer.next_frame(pid)
      assert frame.tick == 0

      # Orbit kinematics resume after reset: the receiver moves again.
      {:ok, frame2} = SimServer.next_frame(pid)
      rx1 = Enum.find(frame.nodes, &(&1.id == "rx1"))
      rx2 = Enum.find(frame2.nodes, &(&1.id == "rx1"))
      assert rx1.pos != rx2.pos
    end

    test "rejects non-world values without touching the session" do
      {:ok, pid} = SimServer.start_link(seed: 7, tick_ms: 10)
      {:ok, before_world, before_bounds} = SimServer.get_world(pid)
      assert {:error, :invalid_world} = SimServer.update_world(pid, %{not: "a world"})
      assert {:ok, ^before_world, ^before_bounds} = SimServer.get_world(pid)
    end

    test "custom-start sessions keep their baseline across reset" do
      custom = Scenario.world("open_field")
      {:ok, pid} = SimServer.start_link(world: custom, seed: 7, tick_ms: 10)
      {:ok, edited} = World.move_node(custom, :tx1, {1.0, 1.0, 0.0}, {0.0, 0.0, 0.0})
      assert :ok = SimServer.update_world(pid, edited)
      assert :ok = SimServer.reset(pid)
      assert {:ok, ^custom, _bounds} = SimServer.get_world(pid)
    end
  end
end
