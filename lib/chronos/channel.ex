defmodule Chronos.Channel do
  alias Chronos.Geometry
  alias Chronos.World

  defmodule Path do
    @enforce_keys [:delay_s, :gain, :doppler_hz]
    defstruct [:delay_s, :gain, :doppler_hz]
  end

  @spec paths_for_rx(World.t(), term(), keyword()) ::
          {:ok, list(Path.t())} | {:error, :unknown_rx}
  def paths_for_rx(%World{} = world, rx_id, opts \\ []) do
    case World.node(world, rx_id) do
      %World.Node{} = rx ->
        txs = World.nodes_by_type(world, :tx)
        walls = Map.values(world.walls)

        paths =
          Enum.flat_map(txs, fn tx ->
            los = los_path(tx, rx, walls, opts)
            reflections = reflection_paths(tx, rx, walls, opts)
            Enum.reject([los | reflections], &is_nil/1)
          end)

        {:ok, paths}

      nil ->
        {:error, :unknown_rx}
    end
  end

  @spec paths_for_rx!(World.t(), term(), keyword()) :: list(Path.t())
  def paths_for_rx!(%World{} = world, rx_id, opts \\ []) do
    case paths_for_rx(world, rx_id, opts) do
      {:ok, paths} ->
        paths

      {:error, :unknown_rx} ->
        raise ArgumentError, "unknown rx node: #{inspect(rx_id)}"
    end
  end

  @spec los_path(World.Node.t(), World.Node.t(), list(World.Wall.t()), keyword()) ::
          Path.t() | nil
  def los_path(
        %World.Node{pos: tx_pos, vel: tx_vel},
        %World.Node{pos: rx_pos, vel: rx_vel},
        walls,
        opts
      ) do
    if segment_occluded?(tx_pos, rx_pos, walls, nil) do
      nil
    else
      distance = Geometry.distance(tx_pos, rx_pos)
      delay_s = distance / speed_of_light(opts)
      gain = free_space_gain(distance) * opts_attenuation(opts)
      doppler_hz = doppler(tx_pos, tx_vel, rx_pos, rx_vel, opts)
      %Path{delay_s: delay_s, gain: gain, doppler_hz: doppler_hz}
    end
  end

  @spec reflection_paths(World.Node.t(), World.Node.t(), list(World.Wall.t()), keyword()) ::
          list(Path.t())
  def reflection_paths(
        %World.Node{pos: tx_pos, vel: tx_vel},
        %World.Node{pos: rx_pos, vel: rx_vel},
        walls,
        opts
      ) do
    Enum.flat_map(walls, fn
      %World.Wall{vertices: [plane_point | _] = vertices, normal: normal, attenuation_db: att} ->
        with {:ok, tx_reflected} <-
               Geometry.reflect_point_across_plane(tx_pos, plane_point, normal),
             {:ok, hit, _t} <-
               Geometry.segment_plane_intersect(tx_reflected, rx_pos, plane_point, normal),
             true <- Geometry.point_in_polygon(hit, vertices, normal),
             false <- segment_occluded?(tx_pos, hit, walls, plane_point),
             false <- segment_occluded?(hit, rx_pos, walls, plane_point) do
          d1 = Geometry.distance(tx_pos, hit)
          d2 = Geometry.distance(hit, rx_pos)
          distance = d1 + d2
          delay_s = distance / speed_of_light(opts)
          gain = free_space_gain(distance) * db_to_linear(-att) * opts_attenuation(opts)
          doppler_hz = doppler(hit, tx_vel, rx_pos, rx_vel, opts)
          [%Path{delay_s: delay_s, gain: gain, doppler_hz: doppler_hz}]
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  @spec segment_occluded?(
          Geometry.vec3(),
          Geometry.vec3(),
          list(World.Wall.t()),
          Geometry.vec3() | nil
        ) ::
          boolean()
  def segment_occluded?(a, b, walls, ignore_plane_point) do
    Enum.any?(walls, fn
      %World.Wall{vertices: [plane_point | _] = vertices, normal: normal} ->
        if ignore_plane_point == plane_point do
          false
        else
          Geometry.segment_intersects_polygon?(a, b, vertices, normal)
        end

      _ ->
        false
    end)
  end

  @spec doppler(Geometry.vec3(), Geometry.vec3(), Geometry.vec3(), Geometry.vec3(), keyword()) ::
          float()
  def doppler(tx_pos, tx_vel, rx_pos, rx_vel, opts) do
    dir = Geometry.sub(rx_pos, tx_pos)

    case Geometry.normalize(dir) do
      {:ok, unit} ->
        rel = Geometry.sub(rx_vel, tx_vel)
        Geometry.dot(rel, unit) / wavelength(opts)

      _ ->
        0.0
    end
  end

  @spec free_space_gain(float()) :: float()
  def free_space_gain(distance) when distance > 0.0, do: 1.0 / distance
  def free_space_gain(_distance), do: 1.0

  @spec db_to_linear(float()) :: float()
  def db_to_linear(db), do: :math.pow(10.0, db / 20.0)

  defp speed_of_light(opts), do: Keyword.get(opts, :speed_of_light, 299_792_458.0)
  defp carrier_freq(opts), do: Keyword.get(opts, :carrier_freq_hz, 2.4e9)
  defp wavelength(opts), do: speed_of_light(opts) / carrier_freq(opts)
  defp opts_attenuation(opts), do: Keyword.get(opts, :global_gain, 1.0)
end
