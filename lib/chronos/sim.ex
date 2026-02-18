defmodule Chronos.Sim do
  alias Chronos.Channel
  alias Chronos.Packing
  alias Chronos.World

  @spec render(World.t(), binary(), keyword()) :: map()
  def render(%World{} = world, tx_block, opts \\ []) do
    sample_rate = Keyword.get(opts, :sample_rate, 48_000.0)
    noise_power = Keyword.get(opts, :noise_power, 0.0)
    seed = Keyword.get(opts, :seed, 1)

    World.nodes_by_type(world, :rx)
    |> Enum.map(fn rx ->
      paths = Channel.paths_for_rx!(world, rx.id, opts)
      paths_bin = Packing.pack_paths(Enum.map(paths, &Map.from_struct/1))
      rx_block = Chronos.DSP.render_rx_block(tx_block, paths_bin, sample_rate, noise_power, seed)
      {rx.id, rx_block}
    end)
    |> Map.new()
  end
end
