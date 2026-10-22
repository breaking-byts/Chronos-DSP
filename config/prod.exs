import Config

config :chronos, ChronosWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: false,
  force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true]
