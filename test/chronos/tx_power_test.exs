defmodule Chronos.TxPowerTest do
  @moduledoc """
  Link-budget behavior of the `:tx_power` channel opt (issue #33).

  `received_power` is the mean power of the rendered samples, so scaling the
  Elixir-computed path gains scales the rendered signal (and therefore the
  metric) while the additive noise floor stays unchanged. The default 10 dBm
  calibrates the existing unit-gain-at-one-metre normalization, so default
  renders are bit-identical to pre-`tx_power` renders.
  """
  use ExUnit.Case, async: true

  alias Chronos.Scenario
  alias Chronos.Sim
  alias Chronos.SimFrame

  @base_opts [tick: 0, seed: 7, sample_rate: 48_000.0]

  defp world, do: Scenario.world("open_field")

  defp metrics(tx_power, noise_power) do
    opts = Keyword.merge(@base_opts, noise_power: noise_power, tx_power: tx_power)
    SimFrame.metrics(world(), opts)
  end

  defp power(tx_power, noise_power), do: metrics(tx_power, noise_power).received_power

  defp power_factor(tx_power), do: :math.pow(10.0, (tx_power - 10) / 10.0)

  test "the default is 10 dBm and matches explicit tx_power: 10 exactly" do
    default = SimFrame.metrics(world(), Keyword.put(@base_opts, :noise_power, 0.01))
    explicit = metrics(10, 0.01)

    assert default == explicit
  end

  test "with zero noise, received power scales by 10 ** ((tx_power - 10) / 10)" do
    reference = power(10, 0.0)
    assert reference > 0.0

    for tx_power <- [0, 5, 20, 30] do
      expected = reference * power_factor(tx_power)
      # Gains and samples round through float32, so allow a small relative error.
      assert_in_delta power(tx_power, 0.0), expected, expected * 1.0e-5
    end
  end

  test "tx_power scales the signal but not the additive noise floor" do
    signal = power(10, 0.0)
    noisy = power(10, 0.01)
    noise = noisy - signal
    assert noise > 0.0

    for tx_power <- [0, 20, 30] do
      signal_part = signal * power_factor(tx_power)
      expected = signal_part + noise

      # Over a finite block the mean power carries a signal-noise cross term
      # of order 2*sqrt(signal*noise)/sqrt(sample_count), which changes with
      # the signal amplitude; bound the tolerance by it (128 QPSK samples).
      cross_term = 4.0 * :math.sqrt(signal_part * noise) / :math.sqrt(128.0)
      assert_in_delta power(tx_power, 0.01), expected, cross_term + 1.0e-6
    end
  end

  test "received power is monotonic in tx_power across the full range" do
    powers = for tx_power <- [0, 10, 20, 30], do: power(tx_power, 0.01)

    assert powers == Enum.sort(powers)
    assert hd(powers) < List.last(powers)
  end

  test "more transmit power never worsens BER at a fixed noise floor" do
    assert metrics(30, 0.01).ber <= metrics(10, 0.01).ber
    assert metrics(10, 0.01).ber <= metrics(0, 0.01).ber
  end

  test "SimFrame and Sim.render reject invalid tx_power uniformly" do
    for tx_power <- [-1, 31, 10.5, "10", :foo, nil] do
      assert_raise ArgumentError, ~r/:tx_power/, fn ->
        SimFrame.metrics(world(), Keyword.put(@base_opts, :tx_power, tx_power))
      end

      {_bits, tx_block} = SimFrame.default_tx_block(16)

      assert_raise ArgumentError, ~r/:tx_power/, fn ->
        Sim.render(world(), tx_block, tx_power: tx_power)
      end
    end
  end

  test "boundary values 0 and 30 dBm render through SimFrame and the DSP snapshot" do
    for tx_power <- [0, 30] do
      opts = Keyword.merge(@base_opts, noise_power: 0.01, tx_power: tx_power)
      {metrics, dsp} = SimFrame.metrics_and_dsp(world(), opts)

      assert metrics.received_power > 0.0
      assert length(dsp.constellation) == 128
      assert length(dsp.waveform) == 128
    end
  end
end
