defmodule ChronosWeb.ExportControllerTest do
  use ChronosWeb.ConnCase, async: false

  alias Chronos.Export
  alias Chronos.Scenario
  alias Chronos.SimFrame

  @samples_header "index,re,im"

  test "metrics endpoint returns the full expected CSV body", %{conn: conn} do
    conn =
      get(conn, "/api/export/metrics", %{
        "scenario" => "open_field",
        "seed" => "7",
        "ticks" => "3"
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="metrics.csv")
           ]

    assert conn.resp_body == expected_metrics_csv("open_field", 7, 3)
  end

  test "samples endpoint returns the requested rows with an exact first row", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/csv")
      |> get("/api/export/samples", %{
        "scenario" => "open_field",
        "seed" => "7",
        "ticks" => "2",
        "limit" => "16"
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="samples.csv")
           ]

    rows = String.split(conn.resp_body, "\n", trim: true)
    assert hd(rows) == @samples_header
    assert length(rows) - 1 == 16

    assert hd(tl(rows)) == "0,-0.080927,-0.051775"
  end

  test "ticks changes the exported simulation time", %{conn: conn} do
    zero = get(conn, "/api/export/metrics", %{"ticks" => "0"})
    three = get(conn, "/api/export/metrics", %{"ticks" => "3"})

    zero_time = metric_time(zero.resp_body)
    three_time = metric_time(three.resp_body)

    assert zero_time == "0.000000"
    assert three_time == "0.300000"
    assert zero_time != three_time
  end

  test "invalid ticks values return plain-text errors", %{conn: conn} do
    for ticks <- ["abc", "-1", "100001"] do
      response = get(conn, "/api/export/metrics", %{"ticks" => ticks})

      assert response.status == 400
      assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
      assert response.resp_body =~ "ticks"
      assert response.resp_body =~ "100000"
    end
  end

  test "invalid scenario returns a plain-text error", %{conn: conn} do
    response = get(conn, "/api/export/metrics", %{"scenario" => "unknown"})

    assert response.status == 400
    assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
    assert response.resp_body =~ "scenario"
  end

  test "invalid sample limits return plain-text errors", %{conn: conn} do
    for limit <- ["0", "513"] do
      response = get(conn, "/api/export/samples", %{"limit" => limit})

      assert response.status == 400
      assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
      assert response.resp_body =~ "limit"
    end
  end

  test "invalid seed returns a plain-text error", %{conn: conn} do
    for seed <- ["-1", "4294967296"] do
      response = get(conn, "/api/export/metrics", %{"seed" => seed})

      assert response.status == 400
      assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
      assert response.resp_body =~ "seed"
      assert response.resp_body =~ "4294967295"
    end
  end

  test "maximum ticks and seed values are accepted", %{conn: conn} do
    response =
      get(conn, "/api/export/metrics", %{
        "seed" => "4294967295",
        "ticks" => "100000"
      })

    assert response.status == 200
  end

  test "health endpoints retain JSON-only content negotiation", %{conn: conn} do
    for path <- ["/healthz", "/readyz"] do
      error =
        assert_raise Phoenix.NotAcceptableError, fn ->
          conn
          |> put_req_header("accept", "text/csv")
          |> get(path)
        end

      assert error.plug_status == 406
    end
  end

  defp metric_time(body) do
    [_header, row] = String.split(body, "\n", trim: true)
    [_tick, time_s | _rest] = String.split(row, ",")
    time_s
  end

  defp expected_metrics_csv(scenario, seed, ticks) do
    world =
      Enum.reduce(1..ticks, Scenario.world(scenario), fn _tick, current ->
        Scenario.step(current, scenario, 0.1)
      end)

    frame =
      SimFrame.from_world(world,
        tick: ticks,
        seed: seed,
        sample_rate: 48_000.0,
        noise_power: 0.01
      )

    metric = Map.merge(frame.metrics, %{tick: frame.tick, time_s: frame.time_s})
    Export.metrics_csv([metric])
  end
end
