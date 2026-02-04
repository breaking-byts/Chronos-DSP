defmodule Chronos.DSPTest do
  use ExUnit.Case, async: true

  alias Chronos.DSP
  alias Chronos.Packing

  test "render_rx_block falls back to reference when nif missing" do
    tx = [{1.0, 0.0}]
    tx_bin = Packing.pack_complex(tx)
    paths_bin = Packing.pack_paths([%{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0}])

    rx_bin = DSP.render_rx_block(tx_bin, paths_bin, 1.0, 0.0, 1)
    assert tx == Packing.unpack_complex(rx_bin)
  end
end
