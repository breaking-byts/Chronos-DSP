import Config

runtime_env = System.get_env("RUNTIME_ENV") || Atom.to_string(config_env())
config :chronos, :runtime_env, runtime_env

if config_env() == :prod do
  # ---------------------------------------------------------------------------
  # Environment helpers
  #
  # Everything in this file runs at boot time (inside the release). Bad input
  # for optional settings must never take the node down, so optional values are
  # normalized/ignored. Only genuinely required settings raise, with an
  # actionable message.
  # ---------------------------------------------------------------------------

  # Returns a trimmed string, or nil for unset/blank values.
  get_env = fn name ->
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  truthy? = fn value ->
    is_binary(value) and String.downcase(String.trim(value)) in ~w(1 true t yes y on)
  end

  falsy? = fn value ->
    is_binary(value) and String.downcase(String.trim(value)) in ~w(0 false f no n off)
  end

  parse_port = fn name, default ->
    case get_env.(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 ->
            port

          _ ->
            raise """
            environment variable #{name} must be an integer between 1 and 65535, got: #{inspect(value)}
            """
        end
    end
  end

  # "HTTPS", "ssl", "http", ... -> "https" | "http"; anything else -> fallback.
  normalize_scheme = fn value, fallback ->
    case value && String.downcase(String.trim(value)) do
      "https" -> "https"
      "ssl" -> "https"
      "http" -> "http"
      _ -> fallback
    end
  end

  # Accepts "example.com", "https://example.com/", "example.com:4000", etc.
  # Returns a bare host (optionally with port) or the fallback.
  normalize_host = fn value, fallback ->
    host =
      value
      |> String.trim()
      |> String.replace(~r{^[A-Za-z][A-Za-z0-9+.\-]*://}, "")
      |> String.split(["/", "?", "#"], parts: 2)
      |> hd()
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()

    if host != "" and Regex.match?(~r/^[A-Za-z0-9.\-:\[\]]+$/, host) do
      host
    else
      fallback
    end
  end

  # Accepts a bare host or a full URL and returns "scheme://host[:port]".
  # Returns nil for entries that cannot be interpreted, so malformed input is
  # ignored instead of crashing the release.
  normalize_origin = fn value, fallback_scheme ->
    entry = String.trim(value)

    if entry == "" do
      nil
    else
      {origin_scheme, rest} =
        case Regex.run(~r{^([A-Za-z][A-Za-z0-9+.\-]*)://(.*)$}, entry) do
          [_, scheme, rest] -> {normalize_scheme.(scheme, fallback_scheme), rest}
          _ -> {fallback_scheme, entry}
        end

      host =
        rest
        |> String.split(["/", "?", "#"], parts: 2)
        |> hd()
        |> String.trim()
        |> String.trim_trailing(".")
        |> String.downcase()

      cond do
        host == "" -> nil
        Regex.match?(~r/^[A-Za-z0-9.*\-:\[\]]+$/, host) -> "#{origin_scheme}://#{host}"
        true -> nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Required settings
  # ---------------------------------------------------------------------------

  secret_key_base =
    case get_env.("SECRET_KEY_BASE") do
      nil ->
        raise """
        environment variable SECRET_KEY_BASE is missing.

        Chronos needs a secret key base to sign cookies and LiveView state.
        Generate one with:

            mix phx.gen.secret

        and provide it as SECRET_KEY_BASE when starting the release
        (for example `fly secrets set SECRET_KEY_BASE=...` or
        `docker run -e SECRET_KEY_BASE=...`).
        """

      value when byte_size(value) < 64 ->
        raise """
        environment variable SECRET_KEY_BASE is too short (#{byte_size(value)} bytes).

        It must be at least 64 bytes. Generate one with:

            mix phx.gen.secret
        """

      value ->
        value
    end

  # ---------------------------------------------------------------------------
  # Networking / TLS
  # ---------------------------------------------------------------------------

  host = normalize_host.(get_env.("PHX_HOST") || "localhost", "localhost")
  port = parse_port.("PORT", 4000)

  force_ssl_env = get_env.("FORCE_SSL")
  scheme_env = get_env.("PHX_SCHEME")

  # FORCE_SSL wins when present; otherwise PHX_SCHEME decides. Production
  # defaults to HTTPS so a misconfigured deployment fails closed (redirects)
  # rather than serving plaintext.
  force_ssl? =
    cond do
      force_ssl_env != nil -> truthy?.(force_ssl_env)
      scheme_env != nil -> normalize_scheme.(scheme_env, "https") == "https"
      true -> true
    end

  scheme =
    if force_ssl? do
      "https"
    else
      normalize_scheme.(scheme_env, "http")
    end

  # Public port used for URL generation. Behind a TLS-terminating proxy this is
  # 443; override with PHX_URL_PORT when the app is exposed on another port.
  url_port =
    parse_port.("PHX_URL_PORT", if(force_ssl?, do: 443, else: port))

  # PHX_SERVER defaults to true in production: `bin/chronos start` is expected
  # to serve HTTP. Set PHX_SERVER=false for release tasks (migrations, etc.).
  server =
    case get_env.("PHX_SERVER") do
      nil -> true
      value -> not falsy?.(value)
    end

  default_origin =
    cond do
      String.contains?(host, ":") -> "#{scheme}://#{host}"
      scheme == "https" and url_port == 443 -> "https://#{host}"
      scheme == "http" and url_port == 80 -> "http://#{host}"
      true -> "#{scheme}://#{host}:#{url_port}"
    end

  check_origin =
    case get_env.("CHECK_ORIGIN") do
      nil ->
        [default_origin]

      raw ->
        origins =
          raw
          |> String.split(",", trim: true)
          |> Enum.map(&normalize_origin.(&1, scheme))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        if origins == [], do: [default_origin], else: origins
    end

  force_ssl_config =
    if force_ssl? do
      [
        rewrite_on: [:x_forwarded_proto],
        hsts: true,
        # Platform health checks arrive over plain HTTP on the internal port.
        # Keep them reachable instead of answering with a 301 to HTTPS.
        exclude: [paths: ["/healthz", "/readyz"]]
      ]
    else
      false
    end

  # Optional signing salts. When unset, derive stable, app-specific values from
  # SECRET_KEY_BASE so a minimal deployment only needs that one secret.
  derive_salt = fn label ->
    :crypto.mac(:hmac, :sha256, secret_key_base, "chronos:" <> label)
    |> Base.url_encode64(padding: false)
  end

  live_view_signing_salt = get_env.("LIVEVIEW_SIGNING_SALT") || derive_salt.("live_view")
  session_signing_salt = get_env.("SESSION_SIGNING_SALT") || derive_salt.("session")

  config :chronos, :require_nif, true

  config :chronos, ChronosWeb.Endpoint,
    server: server,
    url: [host: host, port: url_port, scheme: scheme],
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: check_origin,
    force_ssl: force_ssl_config,
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt],
    session_options: [
      store: :cookie,
      key: "_chronos_key",
      signing_salt: session_signing_salt
    ]

  log_level =
    case get_env.("LOG_LEVEL") do
      nil ->
        :info

      value ->
        case String.downcase(value) do
          "debug" -> :debug
          "info" -> :info
          "notice" -> :notice
          "warning" -> :warning
          "warn" -> :warning
          "error" -> :error
          "critical" -> :critical
          _ -> :info
        end
    end

  config :logger, level: log_level
else
  config :chronos, :require_nif, false

  # Never force TLS outside production.
  config :chronos, ChronosWeb.Endpoint,
    force_ssl: false,
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
