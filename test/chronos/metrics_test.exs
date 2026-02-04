defmodule Chronos.MetricsTest do
  use ExUnit.Case, async: true

  alias Chronos.Metrics

  test "received power computes mean energy" do
    samples = [{1.0, 0.0}, {0.0, 1.0}]
    assert_in_delta Metrics.received_power(samples), 1.0, 1.0e-9
  end

  test "history caps length" do
    history = Enum.map(1..5, &%{time_s: &1})
    assert length(Metrics.push_history(history, %{time_s: 6}, 5)) == 5
    assert hd(Metrics.push_history(history, %{time_s: 6}, 5)).time_s == 2
  end
end
