defmodule Chronos.Runtime do
  @started_key {Chronos.Application, :started_at_monotonic_s}

  @spec uptime_seconds() :: non_neg_integer()
  def uptime_seconds do
    started = :persistent_term.get(@started_key, System.monotonic_time(:second))
    max(System.monotonic_time(:second) - started, 0)
  end

  @spec status() :: map()
  def status do
    %{
      app: "chronos",
      version: app_version(),
      build_env: Application.get_env(:chronos, :build_env) |> to_string(),
      runtime_env: Application.get_env(:chronos, :runtime_env, "unknown"),
      nif_loaded: Chronos.DSP.nif_loaded?(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      uptime_s: uptime_seconds()
    }
  end

  defp app_version do
    case Application.spec(:chronos, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "unknown"
    end
  end
end
