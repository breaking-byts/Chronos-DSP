defmodule Chronos.DSP.Reference do
  alias Chronos.Packing

  @spec render_rx_block(binary(), binary(), float(), float(), non_neg_integer()) :: binary()
  def render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed) do
    tx = Packing.unpack_complex!(tx_block)
    paths = Packing.unpack_paths!(paths_block)
    rx = render_samples(tx, paths, sample_rate, noise_power, seed)
    Packing.pack_complex(rx)
  end

  @spec render_samples(list({float(), float()}), list(map()), float(), float(), non_neg_integer()) ::
          list({float(), float()})
  def render_samples(tx, paths, sample_rate, noise_power, seed) do
    tx_len = length(tx)

    if tx_len == 0 do
      []
    else
      indices = 0..(tx_len - 1)

      {samples, _rng} =
        Enum.map_reduce(indices, seed_rng(seed), fn n, rng ->
          t = n / sample_rate

          {re, im} =
            Enum.reduce(paths, {0.0, 0.0}, fn %{delay_s: d, gain: g, doppler_hz: fd},
                                              {acc_re, acc_im} ->
              x = delayed_sample(tx, n, d * sample_rate)
              phase = 2.0 * :math.pi() * fd * t
              {pr, pi} = rotate(x, phase)
              {acc_re + pr * g, acc_im + pi * g}
            end)

          {nr, ni, rng_next} = gaussian_pair(rng)
          noise_scale = :math.sqrt(noise_power / 2.0)
          {{re + nr * noise_scale, im + ni * noise_scale}, rng_next}
        end)

      samples
    end
  end

  @spec delayed_sample(list({float(), float()}), non_neg_integer(), float()) :: {float(), float()}
  def delayed_sample(tx, n, delay_samples) do
    x = n - delay_samples

    last = length(tx) - 1

    if x < 0.0 or x > last do
      {0.0, 0.0}
    else
      i0 = :math.floor(x) |> trunc()
      {r0, i0c} = Enum.at(tx, i0)

      if i0 == last do
        {r0, i0c}
      else
        frac = x - i0
        {r1, i1c} = Enum.at(tx, i0 + 1)
        {r0 * (1.0 - frac) + r1 * frac, i0c * (1.0 - frac) + i1c * frac}
      end
    end
  end

  @spec rotate({float(), float()}, float()) :: {float(), float()}
  def rotate({re, im}, phase) do
    c = :math.cos(phase)
    s = :math.sin(phase)
    {re * c - im * s, re * s + im * c}
  end

  defp seed_rng(seed) do
    a = rem(seed, 3_000_001)
    b = rem(seed * 1_024_003, 3_000_011)
    c = rem(seed * 6_420_031, 3_000_013)
    :rand.seed_s(:exsplus, {a + 1, b + 1, c + 1})
  end

  defp gaussian_pair(rng_state) do
    {u1, rng1} = rand_uniform(rng_state)
    {u2, rng2} = rand_uniform(rng1)
    r = :math.sqrt(-2.0 * :math.log(u1))
    theta = 2.0 * :math.pi() * u2
    {r * :math.cos(theta), r * :math.sin(theta), rng2}
  end

  defp rand_uniform(rng_state) do
    {u, rng_next} = :rand.uniform_s(rng_state)
    {u, rng_next}
  end
end
