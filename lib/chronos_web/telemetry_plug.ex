defmodule ChronosWeb.TelemetryPlug do
  @moduledoc """
  Emits `[:chronos, :api, :request]` start/stop events for `/api/*` requests.

  A mid-pipeline plug cannot wrap the downstream plugs in `:telemetry.span/3`
  (the span would end before the router runs), so this plug emits the same
  events a span would: `:start` in `call/2` and `:stop` from
  `register_before_send/2`, which runs for halted conns too. The stop event
  carries the monotonic request `duration` and the response `status`.
  Non-API paths pass through untouched to keep the event stream quiet.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    metadata = %{method: conn.method, path: conn.request_path}
    started_at = System.monotonic_time()

    :telemetry.execute(
      [:chronos, :api, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    register_before_send(conn, fn conn ->
      :telemetry.execute(
        [:chronos, :api, :request, :stop],
        %{duration: System.monotonic_time() - started_at},
        Map.put(metadata, :status, conn.status)
      )

      conn
    end)
  end

  def call(conn, _opts), do: conn
end
