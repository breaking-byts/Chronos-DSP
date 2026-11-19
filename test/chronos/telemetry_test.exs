defmodule Chronos.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Chronos.TelemetryCapture, only: [next_event: 1]

  alias Chronos.Packing
  alias Chronos.Sim
  alias Chronos.SimServer
  alias Chronos.World

  @events [
    [:chronos, :sim, :render, :start],
    [:chronos, :sim, :render, :stop],
    [:chronos, :sim, :render, :exception],
    [:chronos, :session, :start],
    [:chronos, :session, :stop]
  ]

  setup do
    handler_id = Chronos.TelemetryCapture.attach(@events)
    on_exit(fn -> Chronos.TelemetryCapture.detach(handler_id) end)
    :ok
  end

  defp one_rx_world do
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
      pos: {1.0, 0.0, 0.0},
      vel: {0.0, 0.0, 0.0}
    })
  end

  test "Sim.render emits a render span with receiver/sample_rate/seed metadata" do
    tx_bin = Packing.pack_complex([{1.0, 0.0}, {0.0, 0.0}])

    result =
      Sim.render(one_rx_world(), tx_bin,
        sample_rate: 1.0,
        speed_of_light: 1.0,
        noise_power: 0.0,
        seed: 42
      )

    assert map_size(result) == 1

    {start_measurements, start_metadata} = next_event([:chronos, :sim, :render, :start])
    assert is_integer(start_measurements.system_time)
    assert start_metadata.receiver_count == 1
    assert start_metadata.sample_rate == 1.0
    assert start_metadata.seed == 42

    {stop_measurements, stop_metadata} = next_event([:chronos, :sim, :render, :stop])
    assert stop_measurements.duration >= 0
    assert stop_metadata.receiver_count == 1
    assert stop_metadata.sample_rate == 1.0
    assert stop_metadata.seed == 42
    assert stop_metadata.noise_power == 0.0
  end

  test "Sim.render emits an exception event when rendering fails" do
    tx_bin = Packing.pack_complex([{1.0, 0.0}])

    assert_raise ArgumentError, fn ->
      Sim.render(one_rx_world(), tx_bin, speed_of_light: -1.0)
    end

    {_measurements, metadata} = next_event([:chronos, :sim, :render, :exception])
    assert metadata.kind == :error
    assert %ArgumentError{} = metadata.reason
    assert metadata.receiver_count == 1
  end

  test "SimServer emits session start on init and stop on terminate" do
    {:ok, pid} = SimServer.start_link(scenario: "orbit", seed: 7)

    {start_measurements, start_metadata} = next_event([:chronos, :session, :start])
    assert is_integer(start_measurements.system_time)
    assert start_metadata.scenario == "orbit"
    assert start_metadata.session == pid
    assert start_metadata.custom_world == false

    GenServer.stop(pid)

    {stop_measurements, stop_metadata} = next_event([:chronos, :session, :stop])
    assert is_integer(stop_measurements.system_time)
    assert stop_measurements.duration >= 0
    assert stop_metadata.scenario == "orbit"
    assert stop_metadata.session == pid
  end

  test "session stop fires when the owner process exits" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid} = SimServer.start_link(scenario: "open_field", owner: owner)
    ref = Process.monitor(pid)

    {_measurements, metadata} = next_event([:chronos, :session, :start])
    assert metadata.scenario == "open_field"

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    {stop_measurements, stop_metadata} = next_event([:chronos, :session, :stop])
    assert stop_measurements.duration >= 0
    assert stop_metadata.session == pid
  end

  test "Chronos.Telemetry.attach/0 is idempotent and logs events with metadata" do
    assert Chronos.Telemetry.attach() == :ok
    assert Chronos.Telemetry.attach() == :ok

    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:chronos, :api, :request, :stop],
            %{duration: System.convert_time_unit(5, :millisecond, :native)},
            %{method: "GET", path: "/api/scenes", status: 200}
          )

          :telemetry.execute(
            [:chronos, :session, :start],
            %{system_time: System.system_time()},
            %{scenario: "orbit", session: self()}
          )

          :telemetry.execute(
            [:chronos, :sim, :render, :start],
            %{system_time: System.system_time()},
            %{receiver_count: 2, sample_rate: 48_000.0, seed: 7}
          )

          :telemetry.execute(
            [:chronos, :sim, :render, :exception],
            %{duration: 0},
            %{kind: :error, reason: %ArgumentError{message: "boom"}, receiver_count: 1}
          )
        end)

      assert log =~ "chronos.api.request.stop"
      assert log =~ "chronos.session.start"
      assert log =~ "chronos.sim.render.start"
      assert log =~ "chronos.sim.render.exception"
    after
      Logger.configure(level: previous_level)
      Chronos.Telemetry.attach()
    end
  end

  test "Chronos.Telemetry.detach/0 removes the logging handler" do
    assert Chronos.Telemetry.attach() == :ok
    assert Chronos.Telemetry.detach() == :ok

    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:chronos, :session, :start],
            %{system_time: System.system_time()},
            %{scenario: "orbit", session: self()}
          )
        end)

      refute log =~ "chronos.session.start"
    after
      Logger.configure(level: previous_level)
      Chronos.Telemetry.attach()
    end
  end

  test "the logging handler renders structured metadata fields" do
    Chronos.Telemetry.attach()
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        capture_log(
          [
            level: :debug,
            format: "$metadata$message",
            metadata: [:event, :duration_ms, :route, :status]
          ],
          fn ->
            :telemetry.execute(
              [:chronos, :api, :request, :stop],
              %{duration: System.convert_time_unit(5, :millisecond, :native)},
              %{method: "GET", path: "/api/scenes", status: 200}
            )
          end
        )

      assert log =~ "event=chronos.api.request.stop"
      assert log =~ "duration_ms=5"
      assert log =~ "route=/api/scenes"
      assert log =~ "status=200"
    after
      Logger.configure(level: previous_level)
      Chronos.Telemetry.attach()
    end
  end
end
