defmodule Chronos.DSPReferenceTest do
  use ExUnit.Case, async: true

  alias Chronos.DSP.Reference
  alias Chronos.Packing

  test "render_rx_block identity path" do
    tx = [{1.0, 0.0}, {0.5, -0.5}]
    tx_bin = Packing.pack_complex(tx)
    paths_bin = Packing.pack_paths([%{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0}])

    rx_bin = Reference.render_rx_block(tx_bin, paths_bin, 1.0, 0.0, 1)
    assert tx == Packing.unpack_complex!(rx_bin)
  end

  test "delayed sample linear interpolation" do
    tx = [{1.0, 0.0}, {0.0, 0.0}]
    assert Reference.delayed_sample(tx, 1, 0.0) == {0.0, 0.0}
    assert Reference.delayed_sample(tx, 1, 1.0) == {1.0, 0.0}
  end

  test "rotate by pi/2" do
    {re, im} = Reference.rotate({1.0, 0.0}, :math.pi() / 2.0)
    assert_in_delta re, 0.0, 1.0e-6
    assert_in_delta im, 1.0, 1.0e-6
  end

  test "render_samples handles empty input" do
    assert [] == Reference.render_samples([], [], 1.0, 0.0, 1)
  end
end
