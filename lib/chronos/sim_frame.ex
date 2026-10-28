defmodule Chronos.SimFrame do
  @moduledoc """
  Builds the single JSON-safe frame consumed by the LiveView dashboard.

  A frame contains the scene geometry, every LOS/reflection path for display,
  the latest link metrics, and a small DSP snapshot (constellation, waveform,
  spectrum) for the first receiver.
  """

  alias Chronos.Channel
  alias Chronos.Metrics
  alias Chronos.Material
  alias Chronos.Modem
  alias Chronos.Packing
  alias Chronos.Scene
  alias Chronos.Sim
  alias Chronos.World

  @constellation_points 128
  @waveform_points 128
  @spectrum_points 64
  @bit_count @constellation_points * 2

  @default_sample_rate 48_000.0
  @default_noise_power 0.01
  @display_path_limit 64

  @type frame :: %{
          tick: non_neg_integer(),
          time_s: float(),
          bounds: %{min: [float()], max: [float()]},
          nodes: list(map()),
          walls: list(map()),
          paths: list(map()),
          metrics: map(),
          dsp: map()
        }

  @doc """
  Builds a frame for the current world.

  Options:

    * `:tick` - required, monotonically increasing frame number
    * `:seed` - deterministic noise seed (default `1`)
    * `:sample_rate` - samples per second (default `48_000.0`)
    * `:noise_power` - complex noise power (default `0.01`)
    * `:bounds` - fixed viewport bounds; derived from the world when absent
  """
  @spec from_world(World.t(), keyword()) :: frame()
  def from_world(%World{} = world, opts) do
    tick = Keyword.fetch!(opts, :tick)
    seed = Keyword.get(opts, :seed, 1)
    sample_rate = Keyword.get(opts, :sample_rate, @default_sample_rate)
    noise_power = Keyword.get(opts, :noise_power, @default_noise_power)
    bounds = Keyword.get_lazy(opts, :bounds, fn -> Scene.bounds(world) end)

    {metrics, dsp} = build_metrics_and_dsp(world, seed + tick, sample_rate, noise_power)

    %{
      tick: tick,
      time_s: world.time_s,
      bounds: Scene.to_map(bounds),
      nodes:
        world.nodes |> Map.values() |> Enum.sort_by(&to_string(&1.id)) |> Enum.map(&encode_node/1),
      walls:
        world.walls |> Map.values() |> Enum.sort_by(&to_string(&1.id)) |> Enum.map(&encode_wall/1),
      paths: build_paths(world),
      metrics: metrics,
      dsp: dsp
    }
  end

  # The dashboard draws the same paths the DSP renders, so the display paths
  # come straight from the channel model instead of a second copy of the
  # geometry code.
  defp build_paths(world) do
    world
    |> nodes_of_type(:rx)
    |> Enum.flat_map(fn rx ->
      case Channel.paths_for_rx(world, rx.id, max_paths: @display_path_limit) do
        {:ok, paths} -> Enum.map(paths, &encode_path/1)
        {:error, :unknown_rx} -> []
      end
    end)
  end

  defp build_metrics_and_dsp(world, seed, sample_rate, noise_power) do
    case nodes_of_type(world, :rx) do
      [] ->
        {empty_metrics(), empty_dsp()}

      [rx | _] ->
        bits = default_bits()
        symbols = Modem.qpsk_modulate(bits)
        tx_block = Packing.pack_complex(symbols)

        sim_opts = [
          sample_rate: sample_rate,
          noise_power: noise_power,
          seed: seed
        ]

        rx_map = Sim.render(world, tx_block, sim_opts)
        rx_block = Map.get(rx_map, rx.id, <<>>)
        samples = Packing.unpack_complex!(rx_block)
        rx_bits = Modem.qpsk_demodulate(samples)
        paths = Channel.paths_for_rx!(world, rx.id, sim_opts)

        metrics = %{
          ber: Modem.ber(bits, rx_bits),
          path_count: length(paths),
          received_power: Metrics.received_power(samples),
          rx_id: to_string(rx.id)
        }

        {metrics, build_dsp(samples)}
    end
  end

  defp nodes_of_type(world, type) do
    world
    |> World.nodes_by_type(type)
    |> Enum.sort_by(&to_string(&1.id))
  end

  defp encode_node(%World.Node{id: id, type: type, pos: pos, vel: vel}) do
    %{id: to_string(id), type: to_string(type), pos: tuple_to_list(pos), vel: tuple_to_list(vel)}
  end

  defp encode_wall(%World.Wall{
         id: id,
         vertices: vertices,
         normal: normal,
         attenuation_db: att,
         material: material
       }) do
    %{
      id: to_string(id),
      vertices: Enum.map(vertices, &tuple_to_list/1),
      normal: tuple_to_list(normal),
      attenuation_db: att,
      material: to_string(material),
      loss_db: Material.reflection_loss_db(%{attenuation_db: att, material: material})
    }
  end

  defp encode_path(%{points: points, kind: kind, bounces: bounces}) do
    %{
      points: Enum.map(points, &tuple_to_list/1),
      kind: to_string(kind),
      bounces: bounces
    }
  end

  defp tuple_to_list(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)

  defp build_dsp(samples) do
    constellation =
      samples
      |> Enum.take(@constellation_points)
      |> Enum.map(fn {re, im} -> [re, im] end)

    waveform =
      samples
      |> Enum.take(@waveform_points)
      |> Enum.map(fn {re, _im} -> re end)

    spectrum = spectrum(waveform, @spectrum_points)

    %{constellation: constellation, spectrum: spectrum, waveform: waveform}
  end

  defp spectrum(waveform, points) do
    count = min(length(waveform), points)

    if count == 0 do
      []
    else
      values = Enum.take(waveform, count)

      for k <- 0..(count - 1) do
        {re, im} =
          Enum.reduce(Enum.with_index(values), {0.0, 0.0}, fn {x, n}, {acc_re, acc_im} ->
            angle = -2.0 * :math.pi() * k * n / count
            {acc_re + x * :math.cos(angle), acc_im + x * :math.sin(angle)}
          end)

        :math.sqrt(re * re + im * im) / count
      end
    end
  end

  defp default_bits do
    Stream.cycle([0, 0, 0, 1, 1, 1, 1, 0])
    |> Enum.take(@bit_count)
  end

  defp empty_metrics do
    %{ber: 0.0, path_count: 0, received_power: 0.0, rx_id: nil}
  end

  defp empty_dsp do
    %{constellation: [], spectrum: [], waveform: []}
  end
end
