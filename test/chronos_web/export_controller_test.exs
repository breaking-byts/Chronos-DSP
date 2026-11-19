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

  test "invalid ticks values return JSON errors", %{conn: conn} do
    for ticks <- ["abc", "-1", "100001"] do
      response = get(conn, "/api/export/metrics", %{"ticks" => ticks})

      assert response.status == 400
      assert ["application/json" <> _] = get_resp_header(response, "content-type")
      assert %{"error" => error} = Jason.decode!(response.resp_body)
      assert error =~ "ticks"
      assert error =~ "100000"
    end
  end

  test "invalid scenario returns a JSON error", %{conn: conn} do
    response = get(conn, "/api/export/metrics", %{"scenario" => "unknown"})

    assert response.status == 400
    assert ["application/json" <> _] = get_resp_header(response, "content-type")
    assert %{"error" => error} = Jason.decode!(response.resp_body)
    assert error =~ "scenario"
  end

  test "invalid sample limits return JSON errors", %{conn: conn} do
    for limit <- ["0", "513"] do
      response = get(conn, "/api/export/samples", %{"limit" => limit})

      assert response.status == 400
      assert ["application/json" <> _] = get_resp_header(response, "content-type")
      assert %{"error" => error} = Jason.decode!(response.resp_body)
      assert error =~ "limit"
    end
  end

  test "invalid seed returns a JSON error", %{conn: conn} do
    for seed <- ["-1", "4294967296"] do
      response = get(conn, "/api/export/metrics", %{"seed" => seed})

      assert response.status == 400
      assert ["application/json" <> _] = get_resp_header(response, "content-type")
      assert %{"error" => error} = Jason.decode!(response.resp_body)
      assert error =~ "seed"
      assert error =~ "4294967295"
    end
  end

  test "invalid tx_power returns a JSON error on every export endpoint", %{conn: conn} do
    for path <- ["/api/export/metrics", "/api/export/history", "/api/export/samples"],
        tx_power <- ["-1", "31", "10.5", "abc"] do
      response =
        conn
        |> put_req_header("accept", "text/csv")
        |> get(path, %{"tx_power" => tx_power})

      assert response.status == 400
      assert ["application/json" <> _] = get_resp_header(response, "content-type")
      assert %{"error" => error} = Jason.decode!(response.resp_body)
      assert error =~ "tx_power"
      assert error =~ "30"
    end
  end

  test "explicit tx_power 10 keeps the golden samples row", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/csv")
      |> get("/api/export/samples", %{
        "scenario" => "open_field",
        "seed" => "7",
        "ticks" => "2",
        "limit" => "16",
        "tx_power" => "10"
      })

    assert conn.status == 200
    rows = String.split(conn.resp_body, "\n", trim: true)
    assert hd(tl(rows)) == "0,-0.080927,-0.051775"
  end

  test "tx_power scales exported metrics and samples", %{conn: conn} do
    powers =
      for tx_power <- ["0", "10", "30"] do
        response =
          get(conn, "/api/export/metrics", %{
            "scenario" => "open_field",
            "seed" => "7",
            "tx_power" => tx_power
          })

        assert response.status == 200
        [_header, row] = String.split(response.resp_body, "\n", trim: true)
        row |> String.split(",") |> Enum.at(4) |> String.to_float()
      end

    assert powers == Enum.sort(powers)
    assert hd(powers) < List.last(powers)

    # The first rendered sample is noise-only (the fractional path delay gives
    # the signal zero weight at n=0), so the golden row survives any tx_power;
    # the second sample carries signal and must scale.
    samples_at = fn tx_power ->
      response =
        conn
        |> put_req_header("accept", "text/csv")
        |> get("/api/export/samples", %{
          "scenario" => "open_field",
          "seed" => "7",
          "ticks" => "2",
          "limit" => "16",
          "tx_power" => tx_power
        })

      assert response.status == 200
      String.split(response.resp_body, "\n", trim: true)
    end

    default_rows = samples_at.("10")
    boosted_rows = samples_at.("30")

    assert hd(tl(default_rows)) == "0,-0.080927,-0.051775"
    assert hd(tl(boosted_rows)) == "0,-0.080927,-0.051775"
    refute Enum.at(default_rows, 2) == Enum.at(boosted_rows, 2)
  end

  test "history rows match single-frame metrics at the same tx_power", %{conn: conn} do
    history =
      conn
      |> put_req_header("accept", "text/csv")
      |> get("/api/export/history", %{
        "scenario" => "open_field",
        "seed" => "7",
        "from" => "1",
        "to" => "2",
        "step" => "1",
        "tx_power" => "20"
      })

    assert history.status == 200
    rows = history.resp_body |> String.split("\n", trim: true) |> tl()

    for {row, tick} <- Enum.zip(rows, [1, 2]) do
      single =
        get(conn, "/api/export/metrics", %{
          "scenario" => "open_field",
          "seed" => "7",
          "ticks" => Integer.to_string(tick),
          "tx_power" => "20"
        })

      [_header, single_row] = String.split(single.resp_body, "\n", trim: true)
      assert row == single_row
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

  test "history exports one row per sampled tick", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/csv")
      |> get("/api/export/history", %{
        "scenario" => "open_field",
        "seed" => "7",
        "from" => "0",
        "to" => "6",
        "step" => "2"
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="history.csv")
           ]

    rows = String.split(conn.resp_body, "\n", trim: true)
    assert hd(rows) == "tick,time_s,rx_id,path_count,received_power,ber"
    assert length(rows) - 1 == 4
    ticks = Enum.map(tl(rows), fn row -> row |> String.split(",") |> hd() end)
    assert ticks == ["0.000000", "2.000000", "4.000000", "6.000000"]
  end

  test "history rows match independently stepped single-frame metrics", %{conn: conn} do
    history =
      get(conn, "/api/export/history", %{
        "scenario" => "open_field",
        "seed" => "7",
        "from" => "1",
        "to" => "3",
        "step" => "1"
      })

    assert history.status == 200
    rows = history.resp_body |> String.split("\n", trim: true) |> tl()

    for {row, tick} <- Enum.zip(rows, [1, 2, 3]) do
      single =
        get(conn, "/api/export/metrics", %{
          "scenario" => "open_field",
          "seed" => "7",
          "ticks" => Integer.to_string(tick)
        })

      [_header, single_row] = String.split(single.resp_body, "\n", trim: true)
      assert row == single_row
    end
  end

  test "history defaults produce a bounded multi-row export", %{conn: conn} do
    response = get(conn, "/api/export/history", %{})

    assert response.status == 200
    rows = String.split(response.resp_body, "\n", trim: true)
    assert length(rows) - 1 == 101
  end

  test "history accepts a single tick when from equals to", %{conn: conn} do
    response = get(conn, "/api/export/history", %{"from" => "4", "to" => "4"})

    assert response.status == 200
    rows = String.split(response.resp_body, "\n", trim: true)
    assert length(rows) - 1 == 1
    assert hd(tl(rows)) |> String.split(",") |> hd() == "4.000000"
  end

  test "history rejects to below from", %{conn: conn} do
    response = get(conn, "/api/export/history", %{"from" => "5", "to" => "2"})

    assert response.status == 400
    assert %{"error" => error} = Jason.decode!(response.resp_body)
    assert error =~ "to must be greater than or equal to from"
  end

  test "history rejects ranges exceeding the row cap", %{conn: conn} do
    response =
      get(conn, "/api/export/history", %{"from" => "0", "to" => "100000", "step" => "1"})

    assert response.status == 400
    assert %{"error" => error} = Jason.decode!(response.resp_body)
    assert error =~ "1000"
  end

  test "export endpoints are CSV-only and reject a JSON Accept header", %{conn: conn} do
    for path <- ["/api/export/metrics", "/api/export/history", "/api/export/samples"] do
      error =
        assert_raise Phoenix.NotAcceptableError, fn ->
          conn
          |> put_req_header("accept", "application/json")
          |> get(path)
        end

      assert error.plug_status == 406
    end
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
