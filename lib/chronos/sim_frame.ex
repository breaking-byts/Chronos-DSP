defmodule Chronos.SimFrame do
  alias Chronos.Channel
  alias Chronos.Geometry
  alias Chronos.Modem
  alias Chronos.Packing
  alias Chronos.Sim
  alias Chronos.World

  @constellation_points 128
  @waveform_points 128
  @spectrum_points 64
  @bit_count @constellation_points * 2
  @sample_rate 48_000.0
  @noise_power 0.01

  def from_world(world, opts) do
    tick = Keyword.fetch!(opts, :tick)
    seed = Keyword.get(opts, :seed, 1)
    {metrics, dsp} = build_metrics_and_dsp(world, seed + tick)

    %{
      tick: tick,
      nodes: world.nodes |> Map.values() |> Enum.map(&encode_node/1),
      walls: world.walls |> Map.values() |> Enum.map(&encode_wall/1),
      paths: build_paths(world) |> Enum.map(&encode_path/1),
      metrics: metrics,
      dsp: dsp
    }
  end

  defp build_paths(world) do
    txs = World.nodes_by_type(world, :tx)
    rxs = World.nodes_by_type(world, :rx)
    walls = Map.values(world.walls)

    Enum.flat_map(txs, fn tx ->
      Enum.flat_map(rxs, fn rx ->
        direct =
          if Channel.segment_occluded?(tx.pos, rx.pos, walls, nil) do
            []
          else
            [%{points: [tx.pos, rx.pos], kind: :los}]
          end

        direct ++ reflection_paths(tx, rx, walls)
      end)
    end)
  end

  defp reflection_paths(tx, rx, walls) do
    Enum.flat_map(walls, fn wall ->
      plane_point = hd(wall.vertices)

      with {:ok, tx_reflected} <-
             Geometry.reflect_point_across_plane(tx.pos, plane_point, wall.normal),
           {:ok, hit, _t} <-
             Geometry.segment_plane_intersect(tx_reflected, rx.pos, plane_point, wall.normal),
           true <- Geometry.point_in_polygon(hit, wall.vertices, wall.normal),
           false <- Channel.segment_occluded?(tx.pos, hit, walls, plane_point),
           false <- Channel.segment_occluded?(hit, rx.pos, walls, plane_point) do
        [%{points: [tx.pos, hit, rx.pos], kind: :reflection}]
      else
        _ -> []
      end
    end)
  end

  defp build_metrics_and_dsp(world, seed) do
    case World.nodes_by_type(world, :rx) do
      [] ->
        {%{ber: 0.0, path_count: 0}, empty_dsp()}

      [rx | _] ->
        bits = default_bits()
        symbols = Modem.qpsk_modulate(bits)
        tx_block = Packing.pack_complex(symbols)
        sim_opts = [sample_rate: @sample_rate, noise_power: @noise_power, seed: seed]
        rx_map = Sim.render(world, tx_block, sim_opts)
        rx_block = Map.get(rx_map, rx.id, <<>>)
        samples = Packing.unpack_complex!(rx_block)
        rx_bits = Modem.qpsk_demodulate(samples)
        ber = Modem.ber(bits, rx_bits)
        path_count = Channel.paths_for_rx!(world, rx.id, sim_opts) |> length()
        dsp = build_dsp(samples)
        {%{ber: ber, path_count: path_count}, dsp}
    end
  end

  defp encode_node(%World.Node{id: id, type: type, pos: pos, vel: vel}) do
    %{id: to_string(id), type: to_string(type), pos: tuple_to_list(pos), vel: tuple_to_list(vel)}
  end

  defp encode_wall(%World.Wall{id: id, vertices: vertices, normal: normal, attenuation_db: att}) do
    %{
      id: to_string(id),
      vertices: Enum.map(vertices, &tuple_to_list/1),
      normal: tuple_to_list(normal),
      attenuation_db: att
    }
  end

  defp encode_path(%{points: points, kind: kind}) do
    %{points: Enum.map(points, &tuple_to_list/1), kind: to_string(kind)}
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
    Stream.cycle([0, 0, 1, 1])
    |> Enum.take(@bit_count)
  end

  defp empty_dsp do
    %{constellation: [], spectrum: [], waveform: []}
  end
end
