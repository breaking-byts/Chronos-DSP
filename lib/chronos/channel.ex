defmodule Chronos.Channel do
  @moduledoc """
  Deterministic geometric channel model.

  Each transmitter/receiver pair gets a line-of-sight path when the segment is
  not blocked, plus reflection paths off planar wall polygons. The model is
  intentionally simple: free-space amplitude decays with `1 / distance`, wall
  hits apply their material attenuation, and Doppler is derived from the
  relative velocity projected onto the path.

  The path models that extend the channel (higher-order reflections,
  diffraction, and wall transmission) live in dedicated modules under
  `Chronos.Channel` and share the conventions in `Chronos.Channel.Physics`.
  """

  alias Chronos.Channel.Path
  alias Chronos.Channel.Physics
  alias Chronos.Geometry
  alias Chronos.Material
  alias Chronos.World

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
      delay_s = distance / Physics.speed_of_light(opts)
      gain = Physics.path_gain(distance, 0.0, opts)
      doppler_hz = Physics.doppler_hz([tx_pos, rx_pos], tx_vel, rx_vel, Physics.wavelength(opts))

      %Path{
        delay_s: delay_s,
        gain: gain,
        doppler_hz: doppler_hz,
        kind: :los,
        bounces: 0,
        points: [tx_pos, rx_pos],
        interactions: []
      }
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
        normal: normal
      } = wall ->
        with {:ok, tx_reflected} <-
               Geometry.reflect_point_across_plane(tx_pos, plane_point, normal),
             {:ok, hit, _t} <-
               Geometry.segment_plane_intersect(tx_reflected, rx_pos, plane_point, normal),
             true <- Geometry.point_in_polygon(hit, vertices, normal),
             false <- segment_occluded?(tx_pos, hit, walls, wall_id),
             false <- segment_occluded?(hit, rx_pos, walls, wall_id) do
          distance = Geometry.distance(tx_pos, hit) + Geometry.distance(hit, rx_pos)
          delay_s = distance / Physics.speed_of_light(opts)
          loss_db = Material.reflection_loss_db(wall)
          gain = Physics.path_gain(distance, loss_db, opts)

          doppler_hz =
            Physics.doppler_hz([tx_pos, hit, rx_pos], tx_vel, rx_vel, Physics.wavelength(opts))

          [
            %Path{
              delay_s: delay_s,
              gain: gain,
              doppler_hz: doppler_hz,
              kind: :reflection,
              bounces: 1,
              points: [tx_pos, hit, rx_pos],
              interactions: [{:reflection, wall_id}]
            }
          ]
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
    Physics.doppler_hz([tx_pos, rx_pos], tx_vel, rx_vel, Physics.wavelength(opts))
  end

  @doc "Free-space amplitude, normalized so a one-metre path has unit gain."
  @spec free_space_gain(float()) :: float()
  defdelegate free_space_gain(distance), to: Physics

  @doc "Converts a decibel ratio to linear amplitude."
  @spec db_to_linear(float()) :: float()
  defdelegate db_to_linear(db), to: Physics
end
