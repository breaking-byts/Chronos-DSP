defmodule Chronos.Sim do
  alias Chronos.Channel
  alias Chronos.Packing
  alias Chronos.World

  @doc """
  Renders one complex block per receiver.

  Options: `:sample_rate` (default `48_000.0`), `:noise_power` (default `0.0`),
  `:seed` (default `1`), and the channel opts forwarded to
  `Channel.paths_for_rx!/3` — including `:tx_power` (integer `0..30` dBm,
  default `10`), which scales the packed path gains before they reach the NIF
  or the reference renderer. Invalid channel opts raise `ArgumentError` via
  `Chronos.Channel.Physics.validate_opts!/1`.
  """
  @spec render(World.t(), binary(), keyword()) :: map()
  def render(%World{} = world, tx_block, opts \\ []) do
    sample_rate = Keyword.get(opts, :sample_rate, 48_000.0)
    noise_power = Keyword.get(opts, :noise_power, 0.0)
    seed = Keyword.get(opts, :seed, 1)
    receivers = World.nodes_by_type(world, :rx)

    :telemetry.span(
      [:chronos, :sim, :render],
      %{receiver_count: length(receivers), sample_rate: sample_rate, seed: seed},
      fn ->
        result =
          receivers
          |> Enum.map(fn rx ->
            paths = Channel.paths_for_rx!(world, rx.id, opts)
            paths_bin = Packing.pack_paths(Enum.map(paths, &Map.from_struct/1))

            rx_block =
              Chronos.DSP.render_rx_block(tx_block, paths_bin, sample_rate, noise_power, seed)

            {rx.id, rx_block}
          end)
          |> Map.new()

        {result,
         %{
           receiver_count: length(receivers),
           sample_rate: sample_rate,
           seed: seed,
           noise_power: noise_power
         }}
      end
    )
  end
end
