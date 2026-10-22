defmodule Chronos.PackingTest do
  use ExUnit.Case, async: true

  alias Chronos.Packing

  test "pack/unpack complex roundtrip" do
    samples = [{1.0, -1.0}, {0.25, 0.5}, {-0.5, 0.0}]
    bin = Packing.pack_complex(samples)
    assert {:ok, samples} == Packing.unpack_complex(bin)
    assert samples == Packing.unpack_complex!(bin)
  end

  test "pack/unpack paths roundtrip" do
    paths = [
      %{delay_s: 0.001, gain: 0.5, doppler_hz: 10.0},
      %{delay_s: 0.002, gain: 1.25, doppler_hz: -25.0}
    ]

    bin = Packing.pack_paths(paths)
    assert {:ok, paths} == Packing.unpack_paths(bin)
    assert paths == Packing.unpack_paths!(bin)
  end

  test "unpack_complex returns tagged error on malformed payload" do
    assert {:error, :invalid_binary} = Packing.unpack_complex(<<1, 2, 3>>)
    assert_raise ArgumentError, fn -> Packing.unpack_complex!(<<1, 2, 3>>) end
  end

  test "unpack_paths returns tagged error on malformed payload" do
    assert {:error, :invalid_binary} = Packing.unpack_paths(<<1, 2, 3>>)
    assert_raise ArgumentError, fn -> Packing.unpack_paths!(<<1, 2, 3>>) end
  end
end
