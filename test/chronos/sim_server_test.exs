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

  describe "set_tx_power/2 (panel slider, #35)" do
    # A static world (zero velocities) keeps received power comparable across
    # frames: only the tx_power render option changes.
    defp static_world do
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
        pos: {2.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })
    end

    defp static_sim(opts \\ []) do
      SimServer.start_link(
        Keyword.merge([world: static_world(), seed: 7, noise_power: 0.0], opts)
      )
    end

    defp received_power(pid) do
      {:ok, frame} = SimServer.next_frame(pid)
      frame.metrics.received_power
    end

    test "defaults to 10 dBm, matching the pre-#35 render" do
      {:ok, pid} = static_sim()
      {:ok, explicit} = static_sim(tx_power: 10)
      assert received_power(pid) == received_power(explicit)
    end

    test "scales the rendered signal by 10 ** ((tx_power - 10) / 10)" do
      {:ok, pid} = static_sim()
      reference = received_power(pid)
      assert reference > 0.0

      for tx_power <- [0, 20, 30] do
        assert :ok = SimServer.set_tx_power(pid, tx_power)
        expected = reference * :math.pow(10.0, (tx_power - 10) / 10.0)
        assert_in_delta received_power(pid), expected, expected * 1.0e-5
      end
    end

    test "clamps out-of-range integers into 0..30" do
      {:ok, pid} = static_sim()
      assert :ok = SimServer.set_tx_power(pid, 99)
      high = received_power(pid)
      assert :ok = SimServer.set_tx_power(pid, 30)
      assert received_power(pid) == high

      assert :ok = SimServer.set_tx_power(pid, -5)
      low = received_power(pid)
      assert :ok = SimServer.set_tx_power(pid, 0)
      assert received_power(pid) == low
    end

    test "rejects non-integers without touching the session" do
      {:ok, pid} = static_sim()
      before = received_power(pid)

      for value <- [10.5, "10", :foo, nil] do
        assert {:error, :invalid_value} = SimServer.set_tx_power(pid, value)
      end

      assert received_power(pid) == before
    end

    test "survives reset and scenario switches (a render option, not geometry)" do
      {:ok, pid} = SimServer.start_link(seed: 7, noise_power: 0.0, tx_power: 20)
      {:ok, frame} = SimServer.next_frame(pid)
      boosted = frame.metrics.received_power

      assert :ok = SimServer.reset(pid)
      {:ok, frame} = SimServer.next_frame(pid)
      assert frame.metrics.received_power == boosted

      assert :ok = SimServer.set_scenario(pid, "open_field")
      {:ok, frame} = SimServer.next_frame(pid)

      # Same scenario/seed/tick with the same tx_power opt renders identically.
      {:ok, reference} =
        SimServer.start_link(scenario: "open_field", seed: 7, noise_power: 0.0, tx_power: 20)

      {:ok, ref_frame} = SimServer.next_frame(reference)
      assert frame.metrics.received_power == ref_frame.metrics.received_power
    end
  end
end
