defmodule Chronos.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Chronos.PubSub},
      ChronosWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Chronos.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
