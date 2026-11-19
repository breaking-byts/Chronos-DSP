defmodule Chronos.TelemetryCapture do
  @moduledoc false
  # Shared harness for capturing telemetry events in tests. Attaches a handler
  # that forwards events to the test process, and provides next_event/1 to
  # assert on them. Used by Chronos.TelemetryTest and ChronosWeb.TelemetryPlugTest.

  import ExUnit.Assertions

  @doc false
  def capture_event(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  @doc "Attaches a capturing handler for `events`; returns the handler id."
  def attach(events) do
    handler_id = {__MODULE__, make_ref()}
    :telemetry.attach_many(handler_id, events, &capture_event/4, %{test_pid: self()})
    handler_id
  end

  @doc "Detaches a capturing handler by id."
  def detach(handler_id), do: :telemetry.detach(handler_id)

  @doc "Asserts the next captured event matches `event`; returns {measurements, metadata}."
  def next_event(event) do
    assert_receive {:telemetry, ^event, measurements, metadata}, 1_000
    {measurements, metadata}
  end
end
