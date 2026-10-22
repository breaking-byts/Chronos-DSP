import Config

runtime_env = System.get_env("RUNTIME_ENV") || Atom.to_string(config_env())
config :chronos, :runtime_env, runtime_env

if config_env() == :prod do
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  live_view_signing_salt = System.fetch_env!("LIVEVIEW_SIGNING_SALT")
  session_signing_salt = System.fetch_env!("SESSION_SIGNING_SALT")
  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")
  server = System.get_env("PHX_SERVER") in ["1", "true", "TRUE", "True"]

  check_origin =
    System.get_env("CHECK_ORIGIN")
    |> case do
      nil ->
        raise """
        environment variable CHECK_ORIGIN is missing.
        Set CHECK_ORIGIN to a comma-separated list of allowed origins, for example:
        https://chronos.example.com,https://admin.chronos.example.com
        """

      raw when is_binary(raw) ->
        origins =
          raw
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if origins == [] do
          raise "CHECK_ORIGIN must include at least one origin"
        end

        origins
    end

  config :chronos, :require_nif, true

  config :chronos, ChronosWeb.Endpoint,
    server: server,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: check_origin,
    force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt],
    session_options: [
      store: :cookie,
      key: "_chronos_key",
      signing_salt: session_signing_salt
    ]
else
  config :chronos, :require_nif, false

  config :chronos, ChronosWeb.Endpoint,
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") ||
        "dev_secret_key_base_dev_secret_key_base_dev_secret_key_base_dev_secret_key_base",
    live_view: [
      signing_salt: System.get_env("LIVEVIEW_SIGNING_SALT") || "dev_live_view_signing_salt"
    ],
    session_options: [
      store: :cookie,
      key: "_chronos_key",
      signing_salt: System.get_env("SESSION_SIGNING_SALT") || "dev_session_signing_salt"
    ]
end
