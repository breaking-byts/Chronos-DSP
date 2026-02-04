import Config

config :chronos, ChronosWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  server: true
