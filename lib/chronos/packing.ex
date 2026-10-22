defmodule Chronos.Packing do
  @spec pack_complex(list({float(), float()})) :: binary()
  def pack_complex(samples) do
    samples
    |> Enum.map(fn {re, im} -> <<re::float-32-little, im::float-32-little>> end)
    |> IO.iodata_to_binary()
  end

  @spec unpack_complex(binary()) :: {:ok, list({float(), float()})} | {:error, :invalid_binary}
  def unpack_complex(bin) do
    if rem(byte_size(bin), 8) == 0 do
      {:ok, do_unpack_complex(bin, [])}
    else
      {:error, :invalid_binary}
    end
  end

  @spec unpack_complex!(binary()) :: list({float(), float()})
  def unpack_complex!(bin) do
    case unpack_complex(bin) do
      {:ok, samples} ->
        samples

      {:error, :invalid_binary} ->
        raise ArgumentError, "invalid complex binary payload"
    end
  end

  defp do_unpack_complex(<<>>, acc), do: Enum.reverse(acc)

  defp do_unpack_complex(<<re::float-32-little, im::float-32-little, rest::binary>>, acc) do
    do_unpack_complex(rest, [{re, im} | acc])
  end

  @spec pack_paths(list(%{delay_s: float(), gain: float(), doppler_hz: float()})) :: binary()
  def pack_paths(paths) do
    paths
    |> Enum.map(fn %{delay_s: d, gain: g, doppler_hz: f} ->
      <<d::float-64-little, g::float-32-little, f::float-32-little>>
    end)
    |> IO.iodata_to_binary()
  end

  @spec unpack_paths(binary()) ::
          {:ok, list(%{delay_s: float(), gain: float(), doppler_hz: float()})}
          | {:error, :invalid_binary}
  def unpack_paths(bin) do
    if rem(byte_size(bin), 16) == 0 do
      {:ok, do_unpack_paths(bin, [])}
    else
      {:error, :invalid_binary}
    end
  end

  @spec unpack_paths!(binary()) :: list(%{delay_s: float(), gain: float(), doppler_hz: float()})
  def unpack_paths!(bin) do
    case unpack_paths(bin) do
      {:ok, paths} ->
        paths

      {:error, :invalid_binary} ->
        raise ArgumentError, "invalid path binary payload"
    end
  end

  defp do_unpack_paths(<<>>, acc), do: Enum.reverse(acc)

  defp do_unpack_paths(
         <<d::float-64-little, g::float-32-little, f::float-32-little, rest::binary>>,
         acc
       ) do
    do_unpack_paths(rest, [%{delay_s: d, gain: g, doppler_hz: f} | acc])
  end
end
