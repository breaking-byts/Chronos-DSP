defmodule ChronosWeb.SimulationControllerTest do
  use ChronosWeb.ConnCase, async: false

  test "a valid minimal request returns metrics and dsp", %{conn: conn} do
    conn = post_json(conn, %{tick: 0})

    assert conn.status == 200

    payload = Jason.decode!(conn.resp_body)

    assert payload |> Map.keys() |> Enum.sort() == ["dsp", "metrics", "tick", "time_s"]
    assert payload["tick"] == 0
    assert payload["time_s"] == 0.0
    assert is_map(payload["metrics"])

    assert payload["dsp"] |> Map.keys() |> Enum.sort() == [
             "constellation",
             "spectrum",
             "waveform"
           ]

    assert is_list(payload["dsp"]["constellation"])
    assert is_list(payload["dsp"]["spectrum"])
    assert is_list(payload["dsp"]["waveform"])
    refute Map.has_key?(payload, "nodes")
    refute Map.has_key?(payload, "walls")
    refute Map.has_key?(payload, "paths")
  end

  test "metrics contain the documented fields", %{conn: conn} do
    payload = conn |> post_json(%{tick: 0}) |> decode_payload()

    assert Map.keys(payload["metrics"]) |> Enum.sort() ==
             ["ber", "path_count", "received_power", "rx_id"]

    assert payload["metrics"]["rx_id"] == "rx1"
    assert is_number(payload["metrics"]["ber"])
    assert is_integer(payload["metrics"]["path_count"])
    assert is_number(payload["metrics"]["received_power"])
  end

  test "the same request produces identical metrics", %{conn: conn} do
    request = %{tick: 2, scenario: "orbit", seed: 42, sample_rate: 48_000, noise_power: 0.05}

    first = conn |> post_json(request) |> decode_payload()
    second = conn |> post_json(request) |> decode_payload()

    assert first["metrics"] == second["metrics"]
  end

  test "scenarios expose their expected number of paths", %{conn: conn} do
    open_field = conn |> post_json(%{tick: 0, scenario: "open_field"}) |> decode_payload()
    orbit = conn |> post_json(%{tick: 0, scenario: "orbit"}) |> decode_payload()

    assert open_field["metrics"]["path_count"] == 1
    assert orbit["metrics"]["path_count"] >= 2
  end

  test "advancing the tick changes simulation time", %{conn: conn} do
    tick_zero = conn |> post_json(%{tick: 0}) |> decode_payload()
    tick_five = conn |> post_json(%{tick: 5}) |> decode_payload()

    assert tick_zero["time_s"] == 0.0
    assert tick_five["time_s"] == 0.5
    refute tick_zero["time_s"] == tick_five["time_s"]
  end

  test "a missing tick returns a bad request error", %{conn: conn} do
    conn = post_json(conn, %{})

    assert conn.status == 400
    assert %{"error" => error} = Jason.decode!(conn.resp_body)
    assert is_binary(error)
  end

  test "invalid tick values return a bad request error", %{conn: conn} do
    for tick <- [-1, 1.5, "1"] do
      conn = post_json(conn, %{tick: tick})

      assert conn.status == 400
      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert is_binary(error)
    end
  end

  test "tick above the documented maximum returns a bad request error", %{conn: conn} do
    for tick <- [1_000_001, 18_446_744_073_709_551_616, 10 ** 400] do
      conn = post_json(conn, %{tick: tick})

      assert conn.status == 400

      assert %{"error" => "tick must be between 0 and 1000000"} =
               Jason.decode!(conn.resp_body)
    end
  end

  test "an invalid seed returns a bad request error", %{conn: conn} do
    for seed <- [-1, 1.5, "1"] do
      conn = post_json(conn, %{tick: 0, seed: seed})

      assert conn.status == 400
      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert is_binary(error)
    end
  end

  test "seed above the documented maximum returns a bad request error", %{conn: conn} do
    for seed <- [4_294_967_296, 18_446_744_073_709_551_616, 10 ** 400] do
      conn = post_json(conn, %{tick: 0, seed: seed})

      assert conn.status == 400

      assert %{"error" => "seed must be between 0 and 4294967295"} =
               Jason.decode!(conn.resp_body)
    end
  end

  test "the documented upper bounds are accepted", %{conn: conn} do
    conn = post_json(conn, %{tick: 1_000_000, seed: 4_294_967_295})

    assert conn.status == 200
    assert %{"tick" => 1_000_000, "time_s" => 100_000.0} = Jason.decode!(conn.resp_body)
  end

  test "an unknown scenario returns a bad request error", %{conn: conn} do
    conn = post_json(conn, %{tick: 0, scenario: "unknown"})

    assert conn.status == 400
    assert %{"error" => error} = Jason.decode!(conn.resp_body)
    assert is_binary(error)
  end

  test "out-of-range sample rate returns a bad request error", %{conn: conn} do
    for sample_rate <- [999.0, 1_000_001.0, "48000"] do
      conn = post_json(conn, %{tick: 0, sample_rate: sample_rate})

      assert conn.status == 400
      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert is_binary(error)
    end
  end

  test "out-of-range noise power returns a bad request error", %{conn: conn} do
    for noise_power <- [-0.01, 1.01, "0.01"] do
      conn = post_json(conn, %{tick: 0, noise_power: noise_power})

      assert conn.status == 400
      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert is_binary(error)
    end
  end

  test "malformed JSON returns a bad request error", %{conn: conn} do
    conn = post_json(conn, "{not valid json")

    assert conn.status == 400
    assert %{"error" => "malformed JSON body"} = Jason.decode!(conn.resp_body)
  end

  test "malformed JSON on a percent-encoded simulation path returns a JSON error", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/%73imulate", "{not valid json")

    assert conn.status == 400
    assert %{"error" => "malformed JSON body"} = Jason.decode!(conn.resp_body)
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
  end

  test "a non-JSON content type returns a bad request error", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "text/plain")
      |> post("/api/simulate", Jason.encode!(%{tick: 0}))

    assert conn.status == 400
    assert %{"error" => "content type must be application/json"} = Jason.decode!(conn.resp_body)
  end

  test "unknown request fields are ignored", %{conn: conn} do
    conn = post_json(conn, %{tick: 0, unknown: "value", another: 123})

    assert conn.status == 200
    assert %{"tick" => 0} = Jason.decode!(conn.resp_body)
  end

  test "reserved request fields are rejected consistently", %{conn: conn} do
    for {field, value} <- [{"_method", "DELETE"}, {"_format", "csv"}, {"_foo", "value"}] do
      conn = post_json(conn, Map.put(%{tick: 0}, field, value))

      assert conn.status == 400
      assert %{"error" => "reserved field"} = Jason.decode!(conn.resp_body)
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end
  end

  defp decode_payload(conn), do: Jason.decode!(conn.resp_body)

  defp post_json(conn, payload) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/simulate", body)
  end
end
