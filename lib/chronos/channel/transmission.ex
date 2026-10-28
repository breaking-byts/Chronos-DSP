defmodule Chronos.Channel.Transmission do
  @moduledoc """
  Transmission (wall penetration) path model.

  When a wall blocks the direct line-of-sight path, some energy still
  penetrates the wall. This model emits one transmission path per blocked
  segment: the loss is the sum of the transmission losses of every wall the
  segment crosses, so a path that crosses two walls carries both penalties
  exactly once.

  The loss comes from the wall materials via
  `Chronos.Material.transmission_loss_db/1`.
  """

  alias Chronos.Channel.Path
  alias Chronos.Channel.Physics
  alias Chronos.Geometry
  alias Chronos.Material
  alias Chronos.World

  @type vec3 :: Geometry.vec3()
  @type opts :: keyword()

  @default_max_paths 8

  @doc """
  Returns the transmission path for the walls crossed by the direct tx->rx
  segment.

  ## Options

    * `:transmission` - when `false`, returns `[]` (default `true`)
    * `:extra_transmission_loss_db` - extra loss added on top of the material
      loss for every penetration (default `0.0`)
    * `:max_paths` - hard cap on returned paths (default `8`)
    * `:speed_of_light`, `:carrier_freq_hz`, `:global_gain` - the shared
      propagation options from `Chronos.Channel.Physics`

  ## Model

  1. Determine which walls the straight tx->rx segment crosses using
     `Geometry.segment_intersects_polygon?/4`.
  2. If no wall is crossed, return `[]` (the line-of-sight path dominates).
  3. Otherwise return a single path:
     * `points` = `[tx.pos, crossing_point, rx.pos]` where `crossing_point` is
       the intersection of the straight segment with the first crossed wall's
       plane (`Geometry.segment_plane_intersect/4`); if the plane intersection
       is not inside the polygon, fall back to `[tx.pos, rx.pos]`.
     * `interactions` = `[{:transmission, wall_id} | ...]` for ALL crossed
       walls, ordered by wall id.
     * `kind` = `:transmission`
     * `bounces` = `0`
     * `total_length` = `Physics.path_length(points)`
     * `delay_s` = `total_length / Physics.speed_of_light(opts)`
     * `loss_db` = sum of `Material.transmission_loss_db(wall)` over the crossed
       walls + `:extra_transmission_loss_db`
     * `gain` = `Physics.path_gain(total_length, loss_db, opts)`
     * `doppler_hz` = `Physics.doppler_hz(points, tx.vel, rx.vel,
       Physics.wavelength(opts))`
  """
  @spec paths(
          World.Node.t(),
          World.Node.t(),
          list(World.Wall.t()),
          opts()
        ) :: list(Path.t())
  def paths(
        %World.Node{pos: tx_pos, vel: tx_vel},
        %World.Node{pos: rx_pos, vel: rx_vel},
        walls,
        opts
      ) do
    if Keyword.get(opts, :transmission, true) == false do
      []
    else
      # Sort walls by id for deterministic output
      sorted_walls = Enum.sort_by(walls, &to_string(&1.id))

      case crossed_walls(tx_pos, rx_pos, sorted_walls) do
        [] ->
          []

        crossed ->
          [build_path(tx_pos, tx_vel, rx_pos, rx_vel, crossed, opts)]
          |> Enum.take(max_paths(opts))
      end
    end
  end

  # The walls the segment tx_pos->rx_pos crosses, in stable id order.
  defp crossed_walls(tx_pos, rx_pos, walls) do
    Enum.filter(walls, fn
      %World.Wall{vertices: vertices, normal: normal} ->
        length(vertices) >= 3 and
          Geometry.segment_intersects_polygon?(tx_pos, rx_pos, vertices, normal)

      _ ->
        false
    end)
  end

  defp build_path(tx_pos, tx_vel, rx_pos, rx_vel, crossed, opts) do
    interactions =
      Enum.map(crossed, fn %World.Wall{id: wall_id} -> {:transmission, wall_id} end)

    loss_db =
      Enum.reduce(crossed, Keyword.get(opts, :extra_transmission_loss_db, 0.0), fn wall, acc ->
        acc + Material.transmission_loss_db(wall)
      end)

    points = [tx_pos, crossing_point(tx_pos, rx_pos, crossed), rx_pos]
    total_length = Physics.path_length(points)

    %Path{
      delay_s: total_length / Physics.speed_of_light(opts),
      gain: Physics.path_gain(total_length, loss_db, opts),
      doppler_hz: Physics.doppler_hz(points, tx_vel, rx_vel, Physics.wavelength(opts)),
      kind: :transmission,
      bounces: 0,
      points: points,
      interactions: interactions
    }
  end

  # The intersection of the segment with the first crossed wall's plane, used
  # so the dashboard can show where the signal crosses the wall.
  defp crossing_point(tx_pos, rx_pos, crossed) do
    %World.Wall{vertices: vertices, normal: normal} = hd(crossed)

    case Geometry.segment_plane_intersect(tx_pos, rx_pos, hd(vertices), normal) do
      {:ok, point, _t} ->
        if Geometry.point_in_polygon(point, vertices, normal) do
          point
        else
          rx_pos
        end

      _ ->
        rx_pos
    end
  end

  defp max_paths(opts) do
    case Keyword.get(opts, :max_paths, @default_max_paths) do
      max_paths when is_integer(max_paths) and max_paths > 0 -> max_paths
      _ -> 0
    end
  end
end
