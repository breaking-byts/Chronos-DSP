defmodule Chronos.Telemetry do
  @moduledoc """
  Structured logging for Chronos telemetry events.

  Events are logged through the stdlib `Logger` with structured metadata
  (`event`, `duration_ms`, `route`, `status`, scenario/session identifiers,
  render options). There is deliberately no JSON-formatter dependency: the
  metadata rides on ordinary Logger events, so any formatter or backend can
  consume it without a new library.

  Emitted events:

    * `[:chronos, :sim, :render, :start | :stop | :exception]` — one
      `Chronos.Sim.render/3` call; `:stop` carries `duration` (native time).
    * `[:chronos, :session, :start | :stop]` — `Chronos.SimServer` lifecycle;
      `:stop` carries the session `duration`.
    * `[:chronos, :api, :request, :start | :stop]` — `/api/*` requests via
      `ChronosWeb.TelemetryPlug`; `:stop` carries `duration` and the response
      `status`.
  """

  require Logger

  @handler_id __MODULE__

  @events [
    [:chronos, :sim, :render, :start],
    [:chronos, :sim, :render, :stop],
    [:chronos, :sim, :render, :exception],
    [:chronos, :session, :start],
    [:chronos, :session, :stop],
    [:chronos, :api, :request, :start],
    [:chronos, :api, :request, :stop]
  ]

  @doc """
  Attaches the logging handler for every Chronos event.

  Idempotent: any previously attached handler with the same id is detached
  first, so repeated calls (app restarts, test setups) never raise
  `:already_exists`.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, [])
  end

  @doc """
  Detaches the logging handler (used by tests and shutdown tooling).
  """
  @spec detach() :: :ok
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  @spec handle_event(:telemetry.event_name(), :telemetry.event_measurements(), map(), term()) ::
          :ok
  def handle_event(event, measurements, metadata, _config) do
    name = Enum.join(event, ".")

    Logger.log(
      level(event),
      "Chronos telemetry event: #{name}",
      log_metadata(event, measurements, metadata)
    )
  end

  defp level([:chronos, _, _, :stop]), do: :info
  defp level(_event), do: :debug

  defp log_metadata(event, measurements, metadata) do
    [
      event: Enum.join(event, "."),
      duration_ms: duration_ms(measurements),
      route: metadata[:path],
      status: metadata[:status],
      scenario: metadata[:scenario],
      session: metadata[:session],
      receiver_count: metadata[:receiver_count],
      sample_rate: metadata[:sample_rate],
      seed: metadata[:seed]
    ]
  end

  defp duration_ms(%{duration: duration}) do
    System.convert_time_unit(duration, :native, :millisecond)
  end

  defp duration_ms(_measurements), do: nil
end
