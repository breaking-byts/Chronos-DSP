defmodule Chronos.DSP.Native do
  use Rustler, otp_app: :chronos, crate: "chronos_dsp"

  def nif_loaded, do: :erlang.nif_error(:nif_not_loaded)

  def render_rx_block(_tx_block, _paths_block, _sample_rate, _noise_power, _seed),
    do: :erlang.nif_error(:nif_not_loaded)
end
