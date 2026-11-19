defmodule Chronos.ChannelOptsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chronos.Channel.Physics

  # Non-finite floats are unconstructible on this OTP, so invalid-input fuzz
  # uses constructible extremes: zero, negatives, out-of-range magnitudes up
  # to 1.0e308, and wrong types.

  defp wrong_type do
    StreamData.one_of([
      StreamData.atom(:alphanumeric),
      StreamData.binary(),
      StreamData.constant(nil)
    ])
  end

  # Shared generator for the positive-integer option keys: zero/negative
  # integers, any float, or a wrong type must all be rejected.
  defp non_positive_integer do
    StreamData.one_of([
      StreamData.integer(-1000..0),
      StreamData.float(),
      wrong_type()
    ])
  end

  defp valid_opts do
    gen all(
          c <- StreamData.float(min: 1.0, max: 1.0e12),
          f <- StreamData.float(min: 1.0, max: 1.0e15),
          gain <- StreamData.float(min: -1.0e100, max: 1.0e100),
          tx_power <- StreamData.integer(0..30),
          max_paths <- StreamData.integer(1..1000),
          max_bounces <- StreamData.integer(1..8),
          max_candidates <- StreamData.integer(1..1000),
          loss <- StreamData.float(min: 0.0, max: 1.0e6)
        ) do
      [
        speed_of_light: c,
        carrier_freq_hz: f,
        global_gain: gain,
        tx_power: tx_power,
        max_paths: max_paths,
        max_bounces: max_bounces,
        max_candidates: max_candidates,
        extra_transmission_loss_db: loss
      ]
    end
  end

  property "valid opts validate and pass through unchanged" do
    check all(opts <- valid_opts()) do
      assert Physics.validate_opts!(opts) == opts
    end
  end

  property "any subset of the optional keys still validates" do
    optional = [
      :global_gain,
      :tx_power,
      :max_paths,
      :max_bounces,
      :max_candidates,
      :extra_transmission_loss_db
    ]

    check all(
            opts <- valid_opts(),
            drops <- StreamData.list_of(StreamData.boolean(), length: length(optional))
          ) do
      kept =
        optional
        |> Enum.zip(drops)
        |> Enum.reject(fn {_key, drop?} -> drop? end)
        |> Enum.map(fn {key, _drop?} -> key end)

      sparse = Keyword.take(opts, [:speed_of_light, :carrier_freq_hz | kept])
      assert Physics.validate_opts!(sparse) == sparse
    end
  end

  property "zero, negative, out-of-range, or non-numeric speed_of_light raises" do
    check all(
            c <-
              StreamData.one_of([
                StreamData.float(min: -1.0e12, max: 0.999),
                StreamData.float(min: 1.0e13, max: 1.0e300),
                StreamData.constant(1.0e308),
                StreamData.integer(-1000..0),
                wrong_type()
              ])
          ) do
      assert_raise ArgumentError, ~r/:speed_of_light/, fn ->
        Physics.validate_opts!(speed_of_light: c)
      end
    end
  end

  property "zero, negative, out-of-range, or non-numeric carrier_freq_hz raises" do
    check all(
            f <-
              StreamData.one_of([
                StreamData.float(min: -1.0e15, max: 0.999),
                StreamData.float(min: 1.0e16, max: 1.0e300),
                StreamData.constant(1.0e308),
                StreamData.integer(-1000..0),
                wrong_type()
              ])
          ) do
      assert_raise ArgumentError, ~r/:carrier_freq_hz/, fn ->
        Physics.validate_opts!(carrier_freq_hz: f)
      end
    end
  end

  property "global_gain beyond 1.0e100 magnitude or non-numeric raises" do
    big = StreamData.float(min: 1.0e101, max: 1.0e300)

    check all(
            gain <-
              StreamData.one_of([
                big,
                StreamData.map(big, &(-&1)),
                StreamData.constant(1.0e308),
                StreamData.constant(-1.0e308),
                wrong_type()
              ])
          ) do
      assert_raise ArgumentError, ~r/:global_gain/, fn ->
        Physics.validate_opts!(global_gain: gain)
      end
    end
  end

  property "max_paths must be a positive integer" do
    check all(value <- non_positive_integer()) do
      assert_raise ArgumentError, ~r/max_paths/, fn ->
        Physics.validate_opts!(max_paths: value)
      end
    end
  end

  property "max_bounces must be a positive integer" do
    check all(value <- non_positive_integer()) do
      assert_raise ArgumentError, ~r/max_bounces/, fn ->
        Physics.validate_opts!(max_bounces: value)
      end
    end
  end

  property "max_candidates must be a positive integer" do
    check all(value <- non_positive_integer()) do
      assert_raise ArgumentError, ~r/max_candidates/, fn ->
        Physics.validate_opts!(max_candidates: value)
      end
    end
  end

  property "negative, out-of-range, or non-numeric extra_transmission_loss_db raises" do
    check all(
            loss <-
              StreamData.one_of([
                StreamData.float(min: -1.0e6, max: -1.0e-9),
                StreamData.float(min: 1.0e7, max: 1.0e300),
                StreamData.constant(1.0e308),
                wrong_type()
              ])
          ) do
      assert_raise ArgumentError, ~r/:extra_transmission_loss_db/, fn ->
        Physics.validate_opts!(extra_transmission_loss_db: loss)
      end
    end
  end

  property "integer speed_of_light/carrier_freq_hz inside the bounds are accepted" do
    check all(
            c <- StreamData.integer(1..1_000_000),
            f <- StreamData.integer(1..1_000_000)
          ) do
      opts = [speed_of_light: c, carrier_freq_hz: f]
      assert Physics.validate_opts!(opts) == opts
    end
  end

  property "tx_power boundary values 0 and 30 dBm are accepted" do
    check all(tx_power <- StreamData.member_of([0, 30])) do
      opts = [tx_power: tx_power]
      assert Physics.validate_opts!(opts) == opts
    end
  end

  property "any integer tx_power inside 0..30 dBm validates and passes through" do
    check all(tx_power <- StreamData.integer(0..30)) do
      opts = [tx_power: tx_power]
      assert Physics.validate_opts!(opts) == opts
    end
  end

  property "negative, float, out-of-range, or non-numeric tx_power raises" do
    check all(
            tx_power <-
              StreamData.one_of([
                StreamData.integer(-1000..-1),
                StreamData.integer(31..1000),
                StreamData.float(),
                wrong_type()
              ])
          ) do
      assert_raise ArgumentError, ~r/:tx_power/, fn ->
        Physics.validate_opts!(tx_power: tx_power)
      end
    end
  end

  property "tx_gain is exactly 1.0 at the default and scales gains by the dB offset" do
    check all(tx_power <- StreamData.integer(0..30)) do
      assert Physics.tx_gain([]) == 1.0
      assert Physics.tx_gain(tx_power: 10) == 1.0

      expected = :math.pow(10.0, (tx_power - 10) / 20.0)
      assert_in_delta Physics.tx_gain(tx_power: tx_power), expected, 1.0e-12

      base = Physics.path_gain(2.0, 3.0, [])
      scaled = Physics.path_gain(2.0, 3.0, tx_power: tx_power)
      assert_in_delta scaled, base * expected, abs(base * expected) * 1.0e-12
    end
  end
end
