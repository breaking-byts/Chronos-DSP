defmodule ChronosWeb.HealthController do
  use Phoenix.Controller

  alias Chronos.Runtime

  def health(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(Map.merge(Runtime.status(), %{status: "ok", ready: true}))
  end

  def ready(conn, _params) do
    ready? = ready?()

    conn
    |> put_status(if(ready?, do: :ok, else: :service_unavailable))
    |> json(
      Map.merge(Runtime.status(), %{
        status: if(ready?, do: "ready", else: "not_ready"),
        ready: ready?,
        require_nif: Application.get_env(:chronos, :require_nif, false)
      })
    )
  end

  defp ready? do
    not Application.get_env(:chronos, :require_nif, false) or Chronos.DSP.nif_loaded?()
  end
end
