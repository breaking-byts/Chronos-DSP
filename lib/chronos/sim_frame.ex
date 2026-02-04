defmodule Chronos.SimFrame do
  def from_world(world, opts) do
    tick = Keyword.fetch!(opts, :tick)

    %{
      tick: tick,
      nodes: Map.values(world.nodes),
      walls: Map.values(world.walls),
      paths: [],
      metrics: %{ber: 0.0, path_count: 0},
      dsp: %{constellation: [], spectrum: [], waveform: []}
    }
  end
end
