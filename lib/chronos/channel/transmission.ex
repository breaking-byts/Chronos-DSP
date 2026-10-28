defmodule Chronos.Channel.Transmission do
  @moduledoc """
  Transmission (wall penetration) path model.

  When a wall blocks the direct line-of-sight path, some energy still penetrates
  the wall. This model emits one transmission path per crossed wall so the
  simulator can show how different materials attenuate the signal.

  The loss comes from the wall's material via `Chronos.Material.transmission_loss_db/1`.
  """

  alias Chronos.Channel.Path
  alias Chronos.Channel.Physics
  alias Chronos.Geometry
  alias Chronos.Material
  alias Chronos.World

  @type vec3 :: Geometry.vec3()
  @type opts :: keyword()

  @doc """
  Returns transmission paths for walls crossed by the direct tx->rx segment.

  ## Options

    * `:transmission` - when `false`, returns `[]` (default `true`)
    * `:extra_transmission_loss_db` - extra loss added on top of the material
      loss for every penetration (default `0.0`)
    * `:max_paths` - hard cap on returned paths (default `8`)
    * All `Physics` options (`:speed_of_light`, `:carrier_freq_hz`,
      `:global_gain`) are passed through.

  ## Model

  1. Determine which walls the straight tx->rx segment crosses using
     `Geometry.segment_intersects_polygon?/4`.
  2. If no wall is crossed, return `[]` (the line-of-sight path dominates).
  3. Otherwise emit one transmission path PER crossed wall (deterministic order:
     walls sorted by id):
     * `points` = `[tx.pos, crossing_point, rx.pos]` where `crossing_point` is
       the intersection of the straight segment with that wall's plane
       (`Geometry.segment_plane_intersect/4`); if the plane intersection is not
       inside the polygon, fall back to `[tx.pos, rx.pos]`.
     * `interactions` = `[{:transmission, wall_id} | ...]` for ALL crossed
       walls, ordered by wall id.
     * `kind` = `:transmission`
     * `bounces` = `0`
     * `total_length` = `Physics.path_length(points)`
     * `delay_s` = `total_length / Physics.speed_of_light(opts)`
     * `loss_db` = sum of `Material.transmission_loss_db(wall)` over the crossed
       walls + `:extra_transmission_loss_db`
     * `gain` = `Physics.path_gain(total_length, loss_db, opts)`
     * `doppler_hz` = `Physics.doppler_hz(points, tx.vel, rx.vel, Physics.wavelength(opts))`
  4. Respect `:max_paths`.
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
    # Respect the transmission flag
    if Keyword.get(opts, :transmission, true) == false do
      []
    else
      # Sort walls by id for deterministic output
      sorted_walls = Enum.sort_by(walls, &to_string(&1.id))

      # Find all walls that the direct segment crosses
      crossed_walls = find_crossed_walls(tx_pos, rx_pos, sorted_walls)

      # No walls crossed -> no transmission path (LOS dominates)
      if crossed_walls == [] do
        []
      else
        # Compute total transmission loss across all crossed walls
        total_loss_db =
          crossed_walls
          |> Enum.reduce(0.0, fn wall, acc ->
            acc + Material.transmission_loss_db(wall)
          end)
          |> Kernel.+(Keyword.get(opts, :extra_transmission_loss_db, 0.0))

        # Build interactions list for all crossed walls (ordered by wall id)
        interactions =
          crossed_walls
          |> Enum.map(fn %World.Wall{id: wall_id} -> {:transmission, wall_id} end)

        # Build one path per crossed wall, capped by max_paths
        max_paths = Keyword.get(opts, :max_paths, 8)

        crossed_walls
        |> Enum.take(max_paths)
        |> Enum.map(fn wall ->
          build_path(
            tx_pos,
            tx_vel,
            rx_pos,
            rx_vel,
            wall,
            interactions,
            total_loss_db,
            opts
          )
        end)
      end
    end
  end

  # Find walls that the segment tx_pos->rx_pos crosses
  defp find_crossed_walls(tx_pos, rx_pos, walls) do
    Enum.filter(walls, fn
      %World.Wall{vertices: vertices, normal: normal} ->
        length(vertices) >= 3 and
          Geometry.segment_intersects_polygon?(tx_pos, rx_pos, vertices, normal)

      _ ->
        false
    end)
  end

  # Build a single transmission path for one crossed wall
  defp build_path(
         tx_pos,
         tx_vel,
         rx_pos,
         rx_vel,
         wall,
         interactions,
         total_loss_db,
         opts
       ) do
    # Find the crossing point on this specific wall
    crossing_point = find_crossing_point(tx_pos, rx_pos, wall)

    # Build the polyline: tx -> crossing_point -> rx
    points = [tx_pos, crossing_point, rx_pos]

    # Total geometric length
    total_length = Physics.path_length(points)

    # Delay = length / speed_of_light
    delay_s = total_length / Physics.speed_of_light(opts)

    # Gain from free-space + total transmission loss + global gain
    gain = Physics.path_gain(total_length, total_loss_db, opts)

    # Doppler from first and last leg
    doppler_hz =
      Physics.doppler_hz(points, tx_vel, rx_vel, Physics.wavelength(opts))

    %Path{
      delay_s: delay_s,
      gain: gain,
      doppler_hz: doppler_hz,
      kind: :transmission,
      bounces: 0,
      points: points,
      interactions: interactions
    }
  end

  # Find the intersection of the segment with the wall's plane.
  # If the intersection is not inside the polygon, fall back to the direct segment midpoint.
  defp find_crossing_point(
         tx_pos,
         rx_pos,
         %World.Wall{vertices: vertices, normal: normal} = _wall
       ) do
    [plane_point | _] = vertices

    case Geometry.segment_plane_intersect(tx_pos, rx_pos, plane_point, normal) do
      {:ok, point, _t} ->
        # Verify the point is actually inside the polygon
        if Geometry.point_in_polygon(point, vertices, normal) do
          point
        else
          # Fallback: direct segment (shouldn't happen if segment_intersects_polygon? returned true)
          midpoint = Geometry.scale(Geometry.add(tx_pos, rx_pos), 0.5)
          midpoint
        end

      _ ->
        # Fallback for parallel or other edge cases
        midpoint = Geometry.scale(Geometry.add(tx_pos, rx_pos), 0.5)
        midpoint
    end
  end
end
