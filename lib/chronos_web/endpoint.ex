defmodule ChronosWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :chronos

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :runtime_session_options, []}]]
  )

  plug(Plug.Static,
    at: "/",
    from: :chronos,
    gzip: false,
    only: ~w()
  )

  plug(Plug.Static,
    at: "/assets",
    from: :chronos,
    gzip: false,
    only: ~w(app.js app.css)
  )

  plug(Plug.Static,
    at: "/phoenix",
    from: :phoenix,
    gzip: false,
    only: ~w(phoenix.js phoenix.min.js)
  )

  plug(Plug.Static,
    at: "/live",
    from: :phoenix_live_view,
    gzip: false,
    only: ~w(phoenix_live_view.js phoenix_live_view.min.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:runtime_session)
  plug(ChronosWeb.Router)

  def runtime_session_options do
    :chronos
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:session_options)
  end

  defp runtime_session(conn, _opts) do
    opts = runtime_session_options()
    Plug.Session.call(conn, Plug.Session.init(opts))
  end
end
