defmodule ChronosWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :chronos

  @session_options [
    store: :cookie,
    key: "_chronos_key",
    signing_salt: "tLx/9X2q"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/",
    from: :chronos,
    gzip: false,
    only: ~w()
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
  plug(Plug.Session, @session_options)
  plug(ChronosWeb.Router)
end
