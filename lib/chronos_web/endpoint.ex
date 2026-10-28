defmodule ChronosWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :chronos

  # Phoenix compiles `force_ssl` into the endpoint pipeline at build time, but
  # this app needs FORCE_SSL/PHX_SCHEME to be runtime settings (the same image
  # runs locally with TLS off and behind a TLS-terminating proxy in production).
  # This plug applies Plug.SSL from the runtime config instead.
  plug(:runtime_force_ssl)

  @force_ssl_cache_key {__MODULE__, :force_ssl_state}

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :runtime_session_options, []}]]
  )

  plug(Plug.Static,
    at: "/",
    from: :chronos,
    gzip: false,
    only: ~w(favicon.svg)
  )

  plug(Plug.Static,
    at: "/assets",
    from: :chronos,
    gzip: true,
    # `:only` matches the first path segment, so serve the whole vendor dir.
    only: ~w(app.js app.css vendor)
  )

  plug(Plug.Static,
    at: "/phoenix",
    from: :phoenix,
    gzip: true,
    only: ~w(phoenix.js phoenix.min.js)
  )

  plug(Plug.Static,
    at: "/live",
    from: :phoenix_live_view,
    gzip: true,
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

  defp runtime_force_ssl(conn, _opts) do
    case :persistent_term.get(@force_ssl_cache_key, :uninitialized) do
      :uninitialized ->
        state = init_force_ssl()
        :persistent_term.put(@force_ssl_cache_key, state)
        apply_force_ssl(conn, state)

      state ->
        apply_force_ssl(conn, state)
    end
  end

  defp init_force_ssl do
    case Application.get_env(:chronos, __MODULE__, [])[:force_ssl] do
      opts when is_list(opts) ->
        opts
        |> Keyword.put_new(:host, {__MODULE__, :host, []})
        |> Plug.SSL.init()

      _ ->
        nil
    end
  end

  defp apply_force_ssl(conn, nil), do: conn
  defp apply_force_ssl(conn, state), do: Plug.SSL.call(conn, state)

  defp runtime_session(conn, _opts) do
    opts = runtime_session_options()
    Plug.Session.call(conn, Plug.Session.init(opts))
  end
end
