defmodule Chronos.Channel do
  @moduledoc """
  Deterministic geometric channel model.

  Each transmitter/receiver pair gets a line-of-sight path when the segment is
  not blocked, plus one first-order reflection path per visible wall. The model
  is intentionally simple: free-space amplitude decays with `1 / distance`, wall
  hits apply their attenuation, and Doppler is derived from the relative
  velocity projected onto the path.
  """

  alias Chronos.Geometry
  alias Chronos.World

  defmodule Path do
    @moduledoc "A single propagation path between a transmitter and receiver."
    @enforce_keys [:delay_s, :gain, :doppler_hz]
    defstruct [:delay_s, :gain, :doppler_hz]

    @type t :: %__MODULE__{delay_s: float(), gain: float(), doppler_hz: float()}
  end

  @doc """
  Returns every path from all transmitters to `rx_id`.

  Returns `{:error, :unknown_rx}` when the receiver id does not exist.
  """
  @spec paths_for_rx(World.t(), term(), keyword()) ::
          {:ok, list(Path.t())} | {:error, :unknown_rx}
  def paths_for_rx(%World{} = world, rx_id, opts \\ []) do
    case World.node(world, rx_id) do
      %World.Node{type: :rx} = rx ->
        txs =
          world
          |> World.nodes_by_type(:tx)
          |> Enum.sort_by(&to_string(&1.id))

        walls =
          world.walls
          |> Map.values()
          |> Enum.sort_by(&to_string(&1.id))

        paths =
          Enum.flat_map(txs, fn tx ->
            los = los_path(tx, rx, walls, opts)
            reflections = reflection_paths(tx, rx, walls, opts)
            Enum.reject([los | reflections], &is_nil/1)
          end)

        {:ok, paths}

      %World.Node{} ->
        {:error, :unknown_rx}

      nil ->
        {:error, :unknown_rx}
    end
  end

  @doc "Like `paths_for_rx/3` but raises for an unknown receiver."
  @spec paths_for_rx!(World.t(), term(), keyword()) :: list(Path.t())
  def paths_for_rx!(%World{} = world, rx_id, opts \\ []) do
    case paths_for_rx(world, rx_id, opts) do
      {:ok, paths} ->
        paths

      {:error, :unknown_rx} ->
        raise ArgumentError, "unknown rx node: #{inspect(rx_id)}"
    end
  end

  @doc "Builds a line-of-sight path, or returns `nil` when a wall blocks it."
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

  @doc """
  Builds first-order reflection paths for each wall.

  The transmitter is mirrored across the wall plane. If the mirrored segment
  crosses the wall polygon and neither leg is occluded by another wall, the hit
  point defines a valid reflection path.
  """
  @spec reflection_paths(World.Node.t(), World.Node.t(), list(World.Wall.t()), keyword()) ::
          list(Path.t())
  def reflection_paths(
        %World.Node{pos: tx_pos, vel: tx_vel},
        %World.Node{pos: rx_pos, vel: rx_vel},
        walls,
        opts
      ) do
    Enum.flat_map(walls, fn
      %World.Wall{
        id: wall_id,
        vertices: [plane_point | _] = vertices,
        normal: normal,
        attenuation_db: att
      } ->
        with {:ok, tx_reflected} <-
               Geometry.reflect_point_across_plane(tx_pos, plane_point, normal),
             {:ok, hit, _t} <-
               Geometry.segment_plane_intersect(tx_reflected, rx_pos, plane_point, normal),
             true <- Geometry.point_in_polygon(hit, vertices, normal),
             false <- segment_occluded?(tx_pos, hit, walls, wall_id),
             false <- segment_occluded?(hit, rx_pos, walls, wall_id) do
          distance = Geometry.distance(tx_pos, hit) + Geometry.distance(hit, rx_pos)
          delay_s = distance / speed_of_light(opts)
          gain = free_space_gain(distance) * db_to_linear(-att) * opts_attenuation(opts)
          doppler_hz = reflection_doppler(tx_pos, tx_vel, rx_pos, rx_vel, hit, opts)
          [%Path{delay_s: delay_s, gain: gain, doppler_hz: doppler_hz}]
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Returns true when the segment `a`-`b` intersects any wall polygon.

  Pass a wall id as `ignore_wall_id` to skip the wall that produced the
  reflection being validated.
  """
  @spec segment_occluded?(
          Geometry.vec3(),
          Geometry.vec3(),
          list(World.Wall.t()),
          term() | nil
        ) :: boolean()
  def segment_occluded?(a, b, walls, ignore_wall_id \\ nil) do
    Enum.any?(walls, fn
      %World.Wall{id: id, vertices: [_ | _] = vertices, normal: normal} ->
        id != ignore_wall_id and
          Geometry.segment_intersects_polygon?(a, b, vertices, normal)

      _ ->
        false
    end)
  end

  @doc "Doppler shift for a direct path, in hertz."
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

  @doc "Free-space amplitude, normalized so a one-metre path has unit gain."
  @spec free_space_gain(float()) :: float()
  def free_space_gain(distance) when distance > 0.0, do: 1.0 / distance
  def free_space_gain(_distance), do: 1.0

  @doc "Converts a decibel ratio to linear amplitude."
  @spec db_to_linear(float()) :: float()
  def db_to_linear(db), do: :math.pow(10.0, db / 20.0)

  defp reflection_doppler(tx_pos, tx_vel, rx_pos, rx_vel, hit, opts) do
    with {:ok, outgoing} <- Geometry.normalize(Geometry.sub(hit, tx_pos)),
         {:ok, incoming} <- Geometry.normalize(Geometry.sub(rx_pos, hit)) do
      rate = Geometry.dot(rx_vel, incoming) - Geometry.dot(tx_vel, outgoing)
      rate / wavelength(opts)
    else
      _ -> 0.0
    end
  end

  defp speed_of_light(opts), do: Keyword.get(opts, :speed_of_light, 299_792_458.0)
  defp carrier_freq(opts), do: Keyword.get(opts, :carrier_freq_hz, 2.4e9)
  defp wavelength(opts), do: speed_of_light(opts) / carrier_freq(opts)
  defp opts_attenuation(opts), do: Keyword.get(opts, :global_gain, 1.0)
end
