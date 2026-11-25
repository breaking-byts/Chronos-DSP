defmodule Chronos.DSPParityTest do
  # Uses the native artifact and the :nif_loaded_override application env.
  use ExUnit.Case, async: false

  alias Chronos.Channel
  alias Chronos.DSP
  alias Chronos.DSP.Native
  alias Chronos.DSP.Reference
  alias Chronos.Packing
  alias Chronos.Scenario
  alias Chronos.SimFrame

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

  test "seeds above u64 mask identically in the reference and the NIF" do
    {tx_bin, paths_bin} = fixture()
    # 2^64 + 7 masks to 7, exactly as the reference's u64 mask does.
    large_seed = 18_446_744_073_709_551_623
    expected = Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7)

    assert expected ==
             Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, large_seed)

    if native_available?() do
      assert_samples_close(
        Native.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, large_seed),
        expected
      )
    end
  end

  test "non-finite tx and path fields are rejected by both backends" do
    tx_bin = Packing.pack_complex([{1.0, 0.0}, {2.0, 0.0}])
    ok_paths = Packing.pack_paths([%{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0}])

    # NaN/Inf in delay_s, gain, or doppler_hz: well-sized payloads that the
    # byte decoders accept but both renderers reject.
    bad_paths = [
      <<0x7FF8_0000_0000_0000::64-little, 1.0::float-32-little, 0.0::float-32-little>>,
      <<0.0::64-little, 0x7F80_0000::32-little, 0.0::float-32-little>>,
      <<0.0::64-little, 1.0::float-32-little, 0xFF80_0000::32-little>>
    ]

    for paths_bin <- bad_paths do
      assert_raise ArgumentError, fn ->
        Reference.render_rx_block(tx_bin, paths_bin, 1.0, 0.0, 1)
      end

      if native_available?() do
        assert_raise ArgumentError, fn ->
          Native.render_rx_block(tx_bin, paths_bin, 1.0, 0.0, 1)
        end
      end
    end

    bad_tx = [
      <<0x7FC0_0000::32-little, 0.0::float-32-little>>,
      <<1.0::float-32-little, 0x7F80_0000::32-little>>
    ]

    for bad_tx_bin <- bad_tx do
      assert_raise ArgumentError, fn ->
        Reference.render_rx_block(bad_tx_bin, ok_paths, 1.0, 0.0, 1)
      end

      if native_available?() do
        assert_raise ArgumentError, fn ->
          Native.render_rx_block(bad_tx_bin, ok_paths, 1.0, 0.0, 1)
        end
      end
    end
  end

  test "negative seeds are rejected by the NIF" do
    {tx_bin, paths_bin} = fixture()

    if native_available?() do
      assert_raise ArgumentError, fn ->
        Native.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, -1)
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

  test "tx_power-scaled channel paths keep native/reference parity" do
    # tx_power scales the Elixir-computed path gains before packing, so both
    # renderers consume identical scaled paths at every transmit power.
    world = Scenario.world("open_field")
    rx = world |> Chronos.World.nodes_by_type(:rx) |> hd()
    {_bits, tx_bin} = SimFrame.default_tx_block(64)

    for tx_power <- [0, 10, 30] do
      paths = Channel.paths_for_rx!(world, rx.id, tx_power: tx_power)
      paths_bin = Packing.pack_paths(Enum.map(paths, &Map.from_struct/1))

      reference = Reference.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7)

      if native_available?() do
        native = Native.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7)
        assert_samples_close(native, reference)

        assert_samples_close(
          DSP.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7),
          reference
        )
      else
        assert DSP.render_rx_block(tx_bin, paths_bin, @sample_rate, 0.01, 7) == reference
      end
    end
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
