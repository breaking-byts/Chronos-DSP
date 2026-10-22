defmodule Chronos.Application do
  use Application

  def start(_type, _args) do
    :persistent_term.put({__MODULE__, :started_at_monotonic_s}, System.monotonic_time(:second))

    children = [
      {Phoenix.PubSub, name: Chronos.PubSub},
      Chronos.SimSupervisor,
      ChronosWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Chronos.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
