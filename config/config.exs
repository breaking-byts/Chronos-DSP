import Config

config :logger, level: :info

config :chronos, ChronosWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "4p9gnyM9Eo7xX1XyC9kxyw8qSx7tT8QF2fH2q4bG1mJ3qfW6R9eZ0zqVb3n1aX7y",
  render_errors: [formats: [html: ChronosWeb.ErrorHTML], layout: false],
  pubsub_server: Chronos.PubSub,
  live_view: [signing_salt: "Y0P4M4C0S4L7"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
