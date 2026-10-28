defmodule Chronos.DSPParityTest do
  # Uses the native artifact and the :nif_loaded_override application env.
  use ExUnit.Case, async: false

  alias Chronos.DSP
  alias Chronos.DSP.Native
  alias Chronos.DSP.Reference
  alias Chronos.Packing

  @sample_rate 48_000.0
  # The reference works in f64 and the NIF in f32 for the sample path, so the
  # two agree to float32 rounding rather than bit-for-bit.
  @sample_epsilon 1.0e-6

  test "reference rendering is deterministic and sized like the input" do
    {tx_bin, paths_bin} = fixture()

    first = Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7)
    second = Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7)

    assert first == second
    assert byte_size(first) == 32 * 8
  end

  test "reference noise is deterministic per seed and varies across seeds" do
    {tx_bin, paths_bin} = fixture()

    seed_a = Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.05, 11)
    seed_a_again = Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.05, 11)
    seed_b = Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.05, 12)

    assert seed_a == seed_a_again
    refute seed_a == seed_b
  end

  test "zero noise keeps a single-sample impulse at unit gain" do
    tx_bin = Packing.pack_complex([{1.0, 0.0}])
    paths_bin = Packing.pack_paths([%{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0}])

    assert [{1.0, 0.0}] ==
             tx_bin
             |> Reference.render_rx_block(paths_bin, 1.0, 0.0, 1)
             |> Packing.unpack_complex!()
  end

  test "reference and native NIF agree when the NIF is loaded" do
    {tx_bin, paths_bin} = fixture()

    for seed <- [0, 7, 123_456_789], noise <- [0.0, 0.01] do
      reference = Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, noise, seed)

      if native_available?() do
        native = Native.render_rx_block(tx_bin, paths_bin, @sample_rate, noise, seed)
        native_again = Native.render_rx_block(tx_bin, paths_bin, @sample_rate, noise, seed)

        assert native == native_again
        assert byte_size(native) == byte_size(reference)
        assert_samples_close(native, reference)

        # The public entry point must route to the same native output.
        assert_samples_close(
          DSP.render_rx_block(tx_bin, paths_bin, @sample_rate, noise, seed),
          reference
        )
      else
        # No native artifact: the public entry point must fall back exactly.
        assert DSP.render_rx_block(tx_bin, paths_bin, @sample_rate, noise, seed) == reference
      end
    end
  end

  test "fallback path through DSP matches the reference exactly" do
    previous = Application.get_env(:chronos, :nif_loaded_override)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:chronos, :nif_loaded_override)
      else
        Application.put_env(:chronos, :nif_loaded_override, previous)
      end
    end)

    Application.put_env(:chronos, :nif_loaded_override, false)
    {tx_bin, paths_bin} = fixture()

    assert DSP.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7) ==
             Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7)
  end

  defp native_available? do
    DSP.nif_loaded?() and Code.ensure_loaded?(Native) and
      function_exported?(Native, :render_rx_block, 5)
  end

  defp fixture do
    tx =
      for n <- 0..31 do
        phase = 2.0 * :math.pi() * n / 8.0
        {:math.cos(phase), :math.sin(phase)}
      end

    paths = [
      %{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0},
      %{delay_s: 1.0 / @sample_rate, gain: 0.5, doppler_hz: 120.0},
      %{delay_s: 3.0 / @sample_rate, gain: -0.25, doppler_hz: -40.0}
    ]

    {Packing.pack_complex(tx), Packing.pack_paths(paths)}
  end

  defp assert_samples_close(left, right) do
    left_samples = Packing.unpack_complex!(left)
    right_samples = Packing.unpack_complex!(right)

    assert length(left_samples) == length(right_samples)

    for {{lr, li}, {rr, ri}} <- Enum.zip(left_samples, right_samples) do
      assert_in_delta lr, rr, @sample_epsilon
      assert_in_delta li, ri, @sample_epsilon
    end
  end
end
