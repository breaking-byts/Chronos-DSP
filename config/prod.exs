import Config

config :chronos, ChronosWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: true
