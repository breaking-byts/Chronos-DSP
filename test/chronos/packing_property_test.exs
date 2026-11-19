defmodule Chronos.PackingPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Chronos.Packing

  # Random float32 bit patterns with a finite exponent (normals, subnormals,
  # zeros, negatives). Decoding them yields float32-representable float64
  # terms, so pack/unpack must round-trip them exactly.
  defp finite_f32 do
    StreamData.integer(0..0xFFFFFFFF)
    |> StreamData.filter(fn bits -> band(bsr(bits, 23), 0xFF) != 0xFF end)
    |> StreamData.map(fn bits -> <<bits::32-little>> end)
    |> StreamData.map(fn <<value::float-32-little>> -> value end)
  end

  defp sample_pair(gen), do: StreamData.tuple({gen, gen})

  # Well-sized binaries built from fixed-size chunks, so no generation space
  # is filtered away.
  defp sized_binary(chunk_size, max_chunks) do
    StreamData.list_of(
      StreamData.binary(min_length: chunk_size, max_length: chunk_size),
      max_length: max_chunks
    )
    |> StreamData.map(&IO.iodata_to_binary/1)
  end

  property "pack/unpack round-trips float32-representable samples exactly" do
    check all(samples <- StreamData.list_of(sample_pair(finite_f32()), max_length: 32)) do
      bin = Packing.pack_complex(samples)
      assert byte_size(bin) == 8 * length(samples)
      assert {:ok, ^samples} = Packing.unpack_complex(bin)
      assert Packing.unpack_complex!(bin) == samples
    end
  end

  property "float64 samples round-trip within float32 tolerance" do
    f64 = StreamData.float(min: -1.0e6, max: 1.0e6)

    check all(samples <- StreamData.list_of(sample_pair(f64), max_length: 16)) do
      assert {:ok, back} = Packing.unpack_complex(Packing.pack_complex(samples))
      assert length(back) == length(samples)

      for {{re, im}, {back_re, back_im}} <- Enum.zip(samples, back) do
        assert_close(re, back_re)
        assert_close(im, back_im)
      end
    end
  end

  # float64 -> float32 -> float64 loses at most ~2^-24 relative precision;
  # near zero an absolute floor keeps subnormal rounding inside the bound.
  defp assert_close(original, back) do
    assert abs(back - original) <= 1.0e-6 * max(abs(original), 1.0),
           "#{inspect(original)} did not round-trip within float32 tolerance (got #{inspect(back)})"
  end

  property "unpack_complex! raises ArgumentError when byte_size is not a multiple of 8" do
    check all(
            base <- sized_binary(8, 8),
            extra <- StreamData.integer(1..7),
            tail <- StreamData.binary(min_length: extra, max_length: extra)
          ) do
      bin = base <> tail
      assert {:error, :invalid_binary} = Packing.unpack_complex(bin)
      assert_raise ArgumentError, fn -> Packing.unpack_complex!(bin) end
    end
  end

  property "unpack_complex never crashes on well-sized arbitrary bytes (decoder fuzz)" do
    check all(bin <- sized_binary(8, 16)) do
      count = div(byte_size(bin), 8)

      case Packing.unpack_complex(bin) do
        {:ok, samples} ->
          assert length(samples) == count
          assert Enum.all?(samples, fn {re, im} -> is_float(re) and is_float(im) end)

        {:error, :invalid_binary} ->
          # Non-finite float32 bit patterns (inf/nan): this OTP cannot build
          # non-finite float terms, so they are rejected, never crashed on.
          :ok
      end
    end
  end

  property "non-finite float32 words anywhere in the payload are rejected, not crashed" do
    non_finite =
      StreamData.member_of([
        <<0, 0, 128, 127>>,
        <<0, 0, 128, 255>>,
        <<0, 0, 192, 127>>,
        <<1, 0, 192, 127>>
      ])

    check all(
            prefix <- sized_binary(8, 4),
            word <- non_finite,
            suffix <- sized_binary(8, 4)
          ) do
      bin = prefix <> word <> <<0, 0, 128, 63>> <> suffix
      assert {:error, :invalid_binary} = Packing.unpack_complex(bin)
      assert_raise ArgumentError, fn -> Packing.unpack_complex!(bin) end
    end
  end

  property "unpack_paths never crashes on well-sized arbitrary bytes (decoder fuzz)" do
    check all(bin <- sized_binary(16, 8)) do
      count = div(byte_size(bin), 16)

      case Packing.unpack_paths(bin) do
        {:ok, paths} ->
          assert length(paths) == count

          assert Enum.all?(paths, fn path ->
                   is_float(path.delay_s) and is_float(path.gain) and is_float(path.doppler_hz)
                 end)

        {:error, :invalid_binary} ->
          :ok
      end
    end
  end

  property "pack/unpack paths round-trips float32-representable gain/Doppler exactly" do
    check all(
            paths <-
              StreamData.list_of(
                StreamData.map(
                  StreamData.tuple(
                    {StreamData.float(min: 0.0, max: 1.0), finite_f32(), finite_f32()}
                  ),
                  fn {delay, gain, doppler} ->
                    %{delay_s: delay, gain: gain, doppler_hz: doppler}
                  end
                ),
                max_length: 16
              )
          ) do
      bin = Packing.pack_paths(paths)
      assert byte_size(bin) == 16 * length(paths)
      assert {:ok, back} = Packing.unpack_paths(bin)
      assert length(back) == length(paths)

      for {path, got} <- Enum.zip(paths, back) do
        # delay_s is float64 on the wire and survives exactly; gain/Doppler
        # were generated float32-representable, so they survive exactly too.
        assert got == path
      end
    end
  end
end
