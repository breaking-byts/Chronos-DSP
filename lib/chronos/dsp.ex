defmodule Chronos.DSP do
  alias Chronos.DSP.Native
  alias Chronos.DSP.Reference

  @spec render_rx_block(binary(), binary(), float(), float(), non_neg_integer()) :: binary()
  def render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed) do
    try do
      Native.render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed)
    rescue
      e in ErlangError ->
        if e.original == :nif_not_loaded do
          Reference.render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed)
        else
          reraise e, __STACKTRACE__
        end
    end
  end
end
