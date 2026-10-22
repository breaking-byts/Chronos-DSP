import Config

config :logger, level: :info

config :chronos,
  require_nif: false,
  build_env: config_env(),
  runtime_env: Atom.to_string(config_env())

config :chronos, ChronosWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [formats: [html: ChronosWeb.ErrorHTML], layout: false],
  pubsub_server: Chronos.PubSub,
  live_view: [signing_salt: "dev_live_view_signing_salt"],
  session_options: [
    store: :cookie,
    key: "_chronos_key",
    signing_salt: "dev_session_signing_salt"
  ]

config :phoenix, :json_library, Jason

erlang_root =
  System.get_env("ERLANG_ROOT") ||
    :code.root_dir()
    |> to_string()

config :chronos, Chronos.DSP.Native,
  env: [
    {"ERL_EI_INCLUDE_DIR",
     System.get_env("ERL_EI_INCLUDE_DIR") || Path.join(erlang_root, "usr/include")},
    {"ERL_EI_LIBDIR", System.get_env("ERL_EI_LIBDIR") || Path.join(erlang_root, "usr/lib")}
  ]

import_config "#{config_env()}.exs"
