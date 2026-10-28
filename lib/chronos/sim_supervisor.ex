defmodule Chronos.SimSupervisor do
  @moduledoc """
  Supervises per-connection simulation sessions.

  Sessions are `:temporary` children: when a browser disconnects the owning
  LiveView stops its session explicitly (and the session also monitors its
  owner as a backstop), so there is no reason to restart a dead session.
  """

  use DynamicSupervisor

  alias Chronos.SimServer

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Starts a simulation session owned by the calling process."
  @spec start_sim(keyword()) ::
          {:ok, pid()} | {:ok, pid(), term()} | :ignore | {:error, term()}
  def start_sim(opts \\ []) do
    opts = Keyword.put_new(opts, :owner, self())
    child_spec = Supervisor.child_spec({SimServer, opts}, restart: :temporary)
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Stops a session if it is still running."
  @spec stop_sim(pid()) :: :ok
  def stop_sim(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
