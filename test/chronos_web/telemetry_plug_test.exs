defmodule ChronosWeb.TelemetryPlugTest do
  use ChronosWeb.ConnCase, async: false

  import Chronos.TelemetryCapture, only: [next_event: 1]

  @events [
    [:chronos, :api, :request, :start],
    [:chronos, :api, :request, :stop]
  ]

  setup do
    handler_id = Chronos.TelemetryCapture.attach(@events)
    on_exit(fn -> Chronos.TelemetryCapture.detach(handler_id) end)
    :ok
  end

  test "GET /api/scenes emits request start/stop with method, path, and status", %{conn: conn} do
    conn = get(conn, "/api/scenes")
    assert conn.status == 200

    {start_measurements, start_metadata} = next_event([:chronos, :api, :request, :start])
    assert is_integer(start_measurements.system_time)
    assert start_metadata.method == "GET"
    assert start_metadata.path == "/api/scenes"

    {stop_measurements, stop_metadata} = next_event([:chronos, :api, :request, :stop])
    assert stop_measurements.duration >= 0
    assert stop_metadata.method == "GET"
    assert stop_metadata.path == "/api/scenes"
    assert stop_metadata.status == 200
  end

  test "POST /api/simulate emits request events with the response status", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/simulate", Jason.encode!(%{tick: 0, scenario: "open_field"}))

    assert conn.status == 200

    {_start_measurements, start_metadata} = next_event([:chronos, :api, :request, :start])
    assert start_metadata.method == "POST"
    assert start_metadata.path == "/api/simulate"

    {stop_measurements, stop_metadata} = next_event([:chronos, :api, :request, :stop])
    assert stop_measurements.duration >= 0
    assert stop_metadata.status == 200
  end

  test "halted error responses still emit a stop event with their status", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/simulate?tick=0", "")

    assert conn.status == 400
    assert conn.halted

    {_measurements, _metadata} = next_event([:chronos, :api, :request, :start])
    {stop_measurements, stop_metadata} = next_event([:chronos, :api, :request, :stop])
    assert stop_measurements.duration >= 0
    assert stop_metadata.status == 400
  end

  test "non-API paths emit no request events", %{conn: conn} do
    conn = get(conn, "/healthz")
    assert conn.status == 200
    refute_receive {:telemetry, [:chronos, :api, :request, _], _, _}, 100
  end

  test "the plug passes non-API conns through untouched" do
    conn = %{Phoenix.ConnTest.build_conn() | path_info: ["healthz"]}
    assert ChronosWeb.TelemetryPlug.call(conn, []) == conn
  end
end
