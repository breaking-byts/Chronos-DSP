defmodule Chronos.SimServerSupervisorTest do
  # These tests use the globally supervised DynamicSupervisor.
  use ExUnit.Case, async: false

  alias Chronos.Scenario
  alias Chronos.SimServer
  alias Chronos.SimSupervisor

  test "next_frame returns sequential frames and advances the world" do
    pid = start_sim(tick_ms: 100)

    assert {:ok, frame0} = SimServer.next_frame(pid)
    assert {:ok, frame1} = SimServer.next_frame(pid)

    assert frame0.tick == 0
    assert frame1.tick == 1
    assert_in_delta frame1.time_s - frame0.time_s, 0.1, 1.0e-9

    assert length(frame0.nodes) == 2
    assert length(frame0.walls) == 2
    assert length(frame0.paths) >= 2

    rx0 = Enum.find(frame0.nodes, &(&1.type == "rx"))
    rx1 = Enum.find(frame1.nodes, &(&1.type == "rx"))
    refute rx0.pos == rx1.pos
  end

  test "reset rewinds the tick counter and restores the initial world" do
    pid = start_sim(tick_ms: 100)

    assert {:ok, initial} = SimServer.next_frame(pid)
    assert {:ok, _} = SimServer.next_frame(pid)
    assert {:ok, _} = SimServer.next_frame(pid)

    assert :ok = SimServer.reset(pid)
    assert {:ok, reset} = SimServer.next_frame(pid)

    assert reset.tick == 0
    assert reset.time_s == 0.0
    assert reset == initial
  end

  test "set_tick_ms changes the time step and clamps to 20..2000 ms" do
    pid = start_sim(tick_ms: 100)

    assert {:ok, _} = SimServer.next_frame(pid)

    assert :ok = SimServer.set_tick_ms(pid, 50)
    assert {:ok, before_fast} = SimServer.next_frame(pid)
    assert {:ok, after_fast} = SimServer.next_frame(pid)
    assert_in_delta after_fast.time_s - before_fast.time_s, 0.05, 1.0e-9

    assert :ok = SimServer.set_tick_ms(pid, 1)
    assert {:ok, before_clamped_low} = SimServer.next_frame(pid)
    assert {:ok, after_clamped_low} = SimServer.next_frame(pid)
    assert_in_delta after_clamped_low.time_s - before_clamped_low.time_s, 0.02, 1.0e-9

    assert :ok = SimServer.set_tick_ms(pid, 999_999)
    assert {:ok, before_clamped_high} = SimServer.next_frame(pid)
    assert {:ok, after_clamped_high} = SimServer.next_frame(pid)
    assert_in_delta after_clamped_high.time_s - before_clamped_high.time_s, 2.0, 1.0e-9
  end

  test "set_noise_power changes the rendered DSP output and clamps to 0..1" do
    pid = start_sim(noise_power: 0.0)

    assert {:ok, clean} = SimServer.next_frame(pid)

    assert :ok = SimServer.set_noise_power(pid, 0.15)
    assert :ok = SimServer.reset(pid)
    assert {:ok, noisy} = SimServer.next_frame(pid)

    assert clean.tick == noisy.tick
    refute clean.dsp.constellation == noisy.dsp.constellation

    # Negative values clamp to zero and reproduce the clean frame.
    assert :ok = SimServer.set_noise_power(pid, -5.0)
    assert :ok = SimServer.reset(pid)
    assert {:ok, clamped} = SimServer.next_frame(pid)
    assert clamped == clean
  end

  test "set_scenario swaps worlds, resets the tick and rejects unknown ids safely" do
    pid = start_sim(scenario: "orbit")

    assert {:ok, _} = SimServer.next_frame(pid)
    assert {:ok, _} = SimServer.next_frame(pid)

    assert :ok = SimServer.set_scenario(pid, "open_field")
    assert {:ok, open_field} = SimServer.next_frame(pid)

    assert open_field.tick == 0
    assert open_field.time_s == 0.0
    assert open_field.walls == []
    assert length(open_field.nodes) == 2
    assert open_field.bounds == Chronos.Scene.to_map(Scenario.bounds("open_field"))

    assert :ok = SimServer.set_scenario(pid, :orbit)
    assert {:ok, orbit} = SimServer.next_frame(pid)
    assert orbit.tick == 0
    assert length(orbit.walls) == 2

    # Unknown ids do not crash the server; the scene falls back to the default.
    assert :ok = SimServer.set_scenario(pid, "no_such_scenario")
    assert {:ok, fallback} = SimServer.next_frame(pid)
    assert fallback.tick == 0
    assert length(fallback.walls) == 2
    assert length(fallback.nodes) == 2
  end

  test "custom worlds keep their bounds and survive reset" do
    world =
      Chronos.World.new()
      |> Chronos.World.add_node(%Chronos.World.Node{
        id: :tx,
        type: :tx,
        pos: {0.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })
      |> Chronos.World.add_node(%Chronos.World.Node{
        id: :rx,
        type: :rx,
        pos: {1.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })

    pid = start_sim(world: world, scenario: "open_field")

    assert {:ok, first} = SimServer.next_frame(pid)
    assert first.bounds == Chronos.Scene.to_map(Chronos.Scene.bounds(world))
    assert first.walls == []

    assert :ok = SimServer.reset(pid)
    assert {:ok, reset} = SimServer.next_frame(pid)
    assert reset == first
  end

  test "invalid control values return errors instead of crashing the server" do
    pid = start_sim([])

    assert {:error, :invalid_value} = SimServer.set_tick_ms(pid, "fast")
    assert {:error, :invalid_value} = SimServer.set_noise_power(pid, :loud)
    assert {:ok, _frame} = SimServer.next_frame(pid)
  end

  test "unknown scenario ids fall back to the default scenario consistently" do
    pid = start_sim(scenario: "orbit")

    assert :ok = SimServer.set_scenario(pid, "no_such_scenario")
    assert {:ok, _frame0} = SimServer.next_frame(pid)
    assert {:ok, frame1} = SimServer.next_frame(pid)

    expected_world = Scenario.world("orbit") |> Scenario.step("orbit", 0.1)

    expected =
      Chronos.SimFrame.from_world(expected_world,
        tick: 1,
        seed: 7,
        bounds: Scenario.bounds("orbit"),
        sample_rate: 48_000.0,
        noise_power: 0.01
      )

    assert frame1.nodes == expected.nodes
    assert frame1.time_s == expected.time_s
  end

  test "a session stops when its owner exits" do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, pid} = SimSupervisor.start_sim(scenario: "open_field", tick_ms: 100)
        send(test_pid, {:sim_pid, pid})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:sim_pid, pid}
    ref = Process.monitor(pid)

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  defp start_sim(opts) do
    opts = Keyword.merge([scenario: "orbit", seed: 7, tick_ms: 100, noise_power: 0.01], opts)
    assert {:ok, pid} = SimSupervisor.start_sim(opts)
    on_exit(fn -> SimSupervisor.stop_sim(pid) end)
    pid
  end
end
