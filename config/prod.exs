import Config

# TLS is configured at runtime (see config/runtime.exs) because `force_ssl` is
# compiled into the endpoint pipeline by Phoenix. Setting it here would ignore
# the runtime FORCE_SSL/PHX_SCHEME environment variables.
config :chronos, ChronosWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: false
