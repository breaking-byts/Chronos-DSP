defmodule Chronos.DSP.Reference do
  @moduledoc """
  Pure-Elixir fallback for the Rust NIF renderer.

  The fallback is intentionally deterministic and mirrors the NIF's tick order
  and xorshift RNG so differential tests can compare the two implementations.
  It is slower than the NIF and is only used when the native artifact is
  unavailable outside production.
  """

  import Bitwise

  alias Chronos.Packing

  @u64_mask 0xFFFFFFFFFFFFFFFF
  @rng_seed_xor 0x9E3779B97F4A7C15
  @rng_multiplier 0x2545F4914F6CDD1D
  @two53 9_007_199_254_740_992.0

  @doc "Renders a complex baseband block through the supplied paths."
  @spec render_rx_block(binary(), binary(), float(), float(), non_neg_integer()) :: binary()
  def render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed) do
    tx = Packing.unpack_complex!(tx_block)
    paths = Packing.unpack_paths!(paths_block)
    rx = render_samples(tx, paths, sample_rate, noise_power, seed)
    Packing.pack_complex(rx)
  end

  @doc """
  Renders `tx` samples through `paths`, adding complex Gaussian noise.

  A path is a map with `:delay_s`, `:gain`, and `:doppler_hz`. Delays are
  linearly interpolated between samples.
  """
  @spec render_samples(list({float(), float()}), list(map()), float(), float(), non_neg_integer()) ::
          list({float(), float()})
  def render_samples(tx, paths, sample_rate, noise_power, seed) do
    tx_len = length(tx)

    if tx_len == 0 do
      []
    else
      tx_tuple = List.to_tuple(tx)
      last = tx_len - 1
      noise_scale = :math.sqrt(noise_power / 2.0)

      {samples, _rng} =
        Enum.map_reduce(0..last, seed_rng(seed), fn n, rng ->
          t = n / sample_rate

          {re, im} =
            Enum.reduce(paths, {0.0, 0.0}, fn %{delay_s: d, gain: g, doppler_hz: fd},
                                              {acc_re, acc_im} ->
              x = delayed_sample_tuple(tx_tuple, n, d * sample_rate, last)
              phase = 2.0 * :math.pi() * fd * t
              {pr, pi} = rotate(x, phase)
              {acc_re + pr * g, acc_im + pi * g}
            end)

          {nr, ni, rng_next} = gaussian_pair(rng)
          {{re + nr * noise_scale, im + ni * noise_scale}, rng_next}
        end)

      samples
    end
  end

  @doc "Returns a linearly interpolated sample, or zero outside the block."
  @spec delayed_sample(list({float(), float()}), non_neg_integer(), float()) ::
          {float(), float()}
  def delayed_sample(tx, n, delay_samples) do
    tx_len = length(tx)

    if tx_len == 0 do
      {0.0, 0.0}
    else
      delayed_sample_tuple(List.to_tuple(tx), n, delay_samples, tx_len - 1)
    end
  end

  @doc "Rotates a complex sample by `phase` radians."
  @spec rotate({float(), float()}, float()) :: {float(), float()}
  def rotate({re, im}, phase) do
    c = :math.cos(phase)
    s = :math.sin(phase)
    {re * c - im * s, re * s + im * c}
  end

  defp delayed_sample_tuple(_tx, _n, _delay_samples, last) when last < 0, do: {0.0, 0.0}

  defp delayed_sample_tuple(tx, n, delay_samples, last) do
    x = n - delay_samples

    if x < 0.0 or x > last do
      {0.0, 0.0}
    else
      i0 = :math.floor(x) |> trunc()
      {r0, i0c} = elem(tx, i0)

      if i0 == last do
        {r0, i0c}
      else
        frac = x - i0
        {r1, i1c} = elem(tx, i0 + 1)
        {r0 * (1.0 - frac) + r1 * frac, i0c * (1.0 - frac) + i1c * frac}
      end
    end
  end

  # The NIF uses xorshift64* with a 64-bit wrapping state. Keeping the exact
  # same generator here makes fallback output comparable to native output.
  defp seed_rng(seed) do
    band(seed, @u64_mask) |> bxor(@rng_seed_xor)
  end

  defp next_u64(state) do
    x = state
    x = band(bxor(x, bsr(x, 12)), @u64_mask)
    x = band(bxor(x, bsl(x, 25)), @u64_mask)
    x = band(bxor(x, bsr(x, 27)), @u64_mask)
    {band(x * @rng_multiplier, @u64_mask), x}
  end

  defp next_f64(state) do
    {value, next_state} = next_u64(state)
    v = bsr(value, 11)
    {(v + 1.0) / (@two53 + 2.0), next_state}
  end

  defp gaussian_pair(state) do
    {u1, state} = next_f64(state)
    {u2, state} = next_f64(state)
    r = :math.sqrt(-2.0 * :math.log(u1))
    theta = 2.0 * :math.pi() * u2
    {r * :math.cos(theta), r * :math.sin(theta), state}
  end
end
