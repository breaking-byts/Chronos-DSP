defmodule Chronos.Modem do
  @spec qpsk_modulate(list(0 | 1)) :: list({float(), float()})
  def qpsk_modulate(bits) do
    if rem(length(bits), 2) != 0 do
      raise ArgumentError, "bit list length must be even"
    end

    bits
    |> Enum.chunk_every(2)
    |> Enum.map(fn [b1, b2] -> map_bits(b1, b2) end)
  end

  @spec qpsk_demodulate(list({float(), float()})) :: list(0 | 1)
  def qpsk_demodulate(symbols) do
    symbols
    |> Enum.flat_map(fn {re, im} -> demap_symbol(re, im) end)
  end

  @spec ber(list(0 | 1), list(0 | 1)) :: float()
  def ber(a, b) do
    total = min(length(a), length(b))

    errors =
      a
      |> Enum.take(total)
      |> Enum.zip(Enum.take(b, total))
      |> Enum.count(fn {x, y} -> x != y end)

    if total == 0, do: 0.0, else: errors / total
  end

  defp map_bits(0, 0), do: norm({1.0, 1.0})
  defp map_bits(0, 1), do: norm({-1.0, 1.0})
  defp map_bits(1, 1), do: norm({-1.0, -1.0})
  defp map_bits(1, 0), do: norm({1.0, -1.0})

  defp demap_symbol(re, im) do
    b1 = if re < 0.0, do: 1, else: 0
    b2 = if im < 0.0, do: 1, else: 0

    case {b1, b2} do
      {0, 0} -> [0, 0]
      {1, 0} -> [1, 0]
      {1, 1} -> [1, 1]
      {0, 1} -> [0, 1]
    end
  end

  defp norm({re, im}) do
    scale = 1.0 / :math.sqrt(2.0)
    {re * scale, im * scale}
  end
end
