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
      decode_complex(bin, [])
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

  defp decode_complex(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_complex(<<re::float-32-little, im::float-32-little, rest::binary>>, acc) do
    decode_complex(rest, [{re, im} | acc])
  end

  # Non-finite float32 bit patterns (±inf, NaN) fail the float pattern above.
  # This OTP cannot construct non-finite float terms, so such payloads get a
  # tagged error instead of a crash: like the Rust decoder, unpacking a
  # well-sized binary is total.
  defp decode_complex(_bin, _acc), do: {:error, :invalid_binary}

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
      decode_paths(bin, [])
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

  defp decode_paths(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_paths(
         <<d::float-64-little, g::float-32-little, f::float-32-little, rest::binary>>,
         acc
       ) do
    decode_paths(rest, [%{delay_s: d, gain: g, doppler_hz: f} | acc])
  end

  # Same totality guarantee as decode_complex/2: non-finite delay/gain/Doppler
  # bit patterns are rejected with a tagged error, never a crash.
  defp decode_paths(_bin, _acc), do: {:error, :invalid_binary}
end
