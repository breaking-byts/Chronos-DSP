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

  test "query strings are rejected on the POST endpoint", %{conn: conn} do
    for query <- ["?tick=0", "?_format=html", "?_method=get", "?foo=bar"] do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/simulate" <> query, Jason.encode!(%{tick: 0}))

      assert conn.status == 400
      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert error =~ "query parameters"
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end
  end

  test "a query tick cannot satisfy the required body field", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/simulate?tick=0", "{}")

    assert conn.status == 400
    assert %{"error" => error} = Jason.decode!(conn.resp_body)
    assert error =~ "query parameters"
  end

  test "reserved fields in the query string are rejected on GET", %{conn: conn} do
    conn = get(conn, "/api/simulate?_format=html")
    assert conn.status == 400
    assert %{"error" => "reserved field"} = Jason.decode!(conn.resp_body)
  end

  test "unknown API paths return a JSON 404", %{conn: conn} do
    conn = get(conn, "/api/missing")
    assert conn.status == 404
    assert %{"error" => "Not Found"} = Jason.decode!(conn.resp_body)
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
  end

  test "a wrong method on the simulation path returns a JSON error", %{conn: conn} do
    conn = get(conn, "/api/simulate")
    assert conn.status == 404
    assert %{"error" => "Not Found"} = Jason.decode!(conn.resp_body)
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
  end

  test "an unsupported non-HTML Accept header returns a JSON 406" do
    # RenderErrors renders the response and then reraises non-NoRouteError
    # exceptions, so ConnTest surfaces the raise; exercise the real test
    # server to assert what an actual client receives. json is the first
    # render_errors fallback format, so non-HTML API clients get JSON.
    {status, headers, body} =
      http_post("/api/simulate", Jason.encode!(%{tick: 0}), [{"accept", "application/xml"}])

    assert status == 406
    assert {_, "application/json" <> _} = List.keyfind(headers, "content-type", 0)
    assert %{"error" => "Not Acceptable"} = Jason.decode!(body)
  end

  test "a browser Accept header still gets an HTML 406 error page" do
    {status, headers, _body} =
      http_post("/api/simulate", Jason.encode!(%{tick: 0}), [{"accept", "text/html"}])

    assert status == 406
    assert {_, "text/html" <> _} = List.keyfind(headers, "content-type", 0)
  end

  test "an oversized body returns a JSON 413" do
    body = Jason.encode!(%{tick: 0, pad: String.duplicate("x", 8_400_000)})

    {status, headers, resp_body} =
      http_post("/api/simulate", body, [{"accept", "application/json"}])

    assert status == 413
    assert {_, "application/json" <> _} = List.keyfind(headers, "content-type", 0)
    assert %{"error" => error} = Jason.decode!(resp_body)
    assert is_binary(error)
  end

  defp http_post(path, body, headers) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", 4001, [:binary, active: false, packet: :raw])

    extra = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    request =
      "POST #{path} HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:4001\r\n" <>
        "Content-Type: application/json\r\n" <>
        extra <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    # The server may answer (e.g. 413) and close before reading the whole
    # body; tolerate a closed socket while sending and still read the reply.
    send_request(sock, request)
    response = recv_response(sock, [])
    :gen_tcp.close(sock)
    parse_response(response)
  end

  defp send_request(_sock, <<>>), do: :ok

  defp send_request(sock, data) do
    size = min(byte_size(data), 65_536)
    chunk = binary_part(data, 0, size)
    rest = binary_part(data, size, byte_size(data) - size)

    case :gen_tcp.send(sock, chunk) do
      :ok -> send_request(sock, rest)
      {:error, _reason} -> :ok
    end
  end

  defp recv_response(sock, acc) do
    data = IO.iodata_to_binary(acc)

    if complete_response?(data) do
      data
    else
      case :gen_tcp.recv(sock, 0, 2_000) do
        {:ok, more} -> recv_response(sock, [acc, more])
        {:error, _reason} -> data
      end
    end
  end

  defp complete_response?(data) do
    with [head, body] <- String.split(data, "\r\n\r\n", parts: 2),
         [_, length] <- Regex.run(~r/content-length:\s*(\d+)/i, head) do
      byte_size(body) >= String.to_integer(length)
    else
      _ -> false
    end
  end

  defp parse_response(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_http, status, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.map(header_lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(k)), String.trim(v)}
      end)

    {String.to_integer(status), headers, body}
  end

  defp decode_payload(conn), do: Jason.decode!(conn.resp_body)

  defp post_json(conn, payload) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/simulate", body)
  end
end
