defmodule Chronos.Channel.Diffraction do
  @moduledoc """
  Deterministic knife-edge diffraction paths around blocking wall polygons.

  This is an ITU-R P.526-style approximation. For each wall that intersects
  the direct transmitter-to-receiver segment, the model finds the polygon edge
  closest to the infinite direct line, evaluates the Fresnel knife-edge
  parameter at that point, and keeps the least-loss edge on the wall.

  A finite wall in three dimensions can straddle the direct line, so there is
  no single global side on which every boundary edge lies. The obstruction
  height is therefore the shortest non-negative distance from the selected
  edge point to the direct line. Both sides of a blocking wall remain
  eligible, while an edge that lies directly on the line is not a diffraction
  edge and is skipped.
  """

  alias Chronos.Channel.Path
  alias Chronos.Channel.Physics
  alias Chronos.Geometry
  alias Chronos.Material
  alias Chronos.World

  @default_max_paths 8
  @epsilon 1.0e-12

  @doc """
  Returns the best diffracted path for every wall that blocks the direct path.

  Options:

    * `:diffraction` - set to `false` to disable diffraction (default `true`)
    * `:max_paths` - maximum number of paths to return (default `8`)

  Walls are processed in stable id order. If several edges on one wall have
  the same loss, polygon vertex order breaks the tie.
  """
  @spec paths(World.Node.t(), World.Node.t(), list(World.Wall.t()), keyword()) :: [Path.t()]
  def paths(
        %World.Node{pos: tx_pos, vel: tx_vel},
        %World.Node{pos: rx_pos, vel: rx_vel},
        walls,
        opts
      ) do
    with true <- Keyword.get(opts, :diffraction, true) != false,
         {:ok, direction} <- line_direction(tx_pos, rx_pos),
         {:ok, wavelength} <- positive_wavelength(opts),
         {:ok, speed_of_light} <- positive_speed_of_light(opts),
         max_paths <- max_paths(opts) do
      walls
      |> blocking_walls(tx_pos, rx_pos)
      |> Enum.map(
        &best_path_for_wall(
          &1,
          tx_pos,
          rx_pos,
          tx_vel,
          rx_vel,
          direction,
          walls,
          opts,
          wavelength,
          speed_of_light
        )
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.take(max_paths)
    else
      _ -> []
    end
  end

  defp blocking_walls(walls, tx_pos, rx_pos) do
    walls
    |> Enum.sort_by(&to_string(&1.id))
    |> Enum.filter(fn
      %World.Wall{vertices: vertices, normal: normal} ->
        length(vertices) >= 3 and
          Geometry.segment_intersects_polygon?(tx_pos, rx_pos, vertices, normal)

      _ ->
        false
    end)
  end

  defp best_path_for_wall(
         %World.Wall{id: wall_id, vertices: vertices} = wall,
         tx_pos,
         rx_pos,
         tx_vel,
         rx_vel,
         direction,
         walls,
         opts,
         wavelength,
         speed_of_light
       ) do
    ignored_ids = MapSet.new([wall_id])

    candidates =
      vertices
      |> Geometry.polygon_edges()
      |> Enum.map(&edge_candidate(&1, tx_pos, direction))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn {edge_point, _height, _distance} ->
        edge_point != tx_pos and edge_point != rx_pos
      end)
      |> Enum.filter(fn {edge_point, _height, _distance} ->
        not segment_occluded_by_others?(tx_pos, edge_point, walls, ignored_ids) and
          not segment_occluded_by_others?(edge_point, rx_pos, walls, ignored_ids)
      end)
      |> Enum.map(fn {edge_point, height, distance_to_tx} ->
        distance_to_rx = Geometry.distance(edge_point, rx_pos)

        fresnel_parameter =
          height *
            :math.sqrt(2.0 / wavelength * (1.0 / distance_to_tx + 1.0 / distance_to_rx))

        loss_db = knife_edge_loss_db(fresnel_parameter) + Material.diffraction_loss_db(wall)
        {edge_point, distance_to_tx, distance_to_rx, loss_db}
      end)

    case candidates do
      [] ->
        nil

      candidates ->
        {edge_point, _distance_to_tx, _distance_to_rx, loss_db} =
          Enum.reduce(candidates, hd(candidates), fn candidate, best ->
            if elem(candidate, 3) < elem(best, 3), do: candidate, else: best
          end)

        build_path(
          wall,
          edge_point,
          loss_db,
          tx_pos,
          rx_pos,
          tx_vel,
          rx_vel,
          opts,
          wavelength,
          speed_of_light
        )
    end
  end

  # Returns the point on an edge closest to the infinite direct line, its
  # obstruction height, and its distance to the transmitter.
  defp edge_candidate({a, b}, tx_pos, direction) do
    edge_vector = Geometry.sub(b, a)
    perpendicular_edge = perpendicular_component(edge_vector, direction)
    perpendicular_to_tx = perpendicular_component(Geometry.sub(a, tx_pos), direction)
    edge_length_squared = Geometry.dot(perpendicular_edge, perpendicular_edge)

    parameter =
      if edge_length_squared == 0.0 do
        0.0
      else
        (-Geometry.dot(perpendicular_to_tx, perpendicular_edge) / edge_length_squared)
        |> clamp(0.0, 1.0)
      end

    edge_point = Geometry.add(a, Geometry.scale(edge_vector, parameter))
    line_point = closest_point_on_infinite_line(edge_point, tx_pos, direction)
    height = Geometry.distance(edge_point, line_point)

    if height > @epsilon do
      {edge_point, height, Geometry.distance(tx_pos, edge_point)}
    end
  end

  defp build_path(
         wall,
         edge_point,
         total_loss_db,
         tx_pos,
         rx_pos,
         tx_vel,
         rx_vel,
         opts,
         wavelength,
         speed_of_light
       ) do
    points = [tx_pos, edge_point, rx_pos]
    total_length = Physics.path_length(points)
    gain = Physics.path_gain(total_length, total_loss_db, opts)
    doppler_hz = Physics.doppler_hz(points, tx_vel, rx_vel, wavelength)

    if finite_positive?(total_length) and finite_number?(total_loss_db) and
         finite_number?(gain) and finite_number?(doppler_hz) do
      Path.new(
        delay_s: total_length / speed_of_light,
        gain: gain,
        doppler_hz: doppler_hz,
        kind: :diffraction,
        bounces: 0,
        points: points,
        interactions: [{:diffraction, wall.id, edge_point}]
      )
    end
  end

  defp knife_edge_loss_db(fresnel_parameter) do
    t = :math.sqrt((fresnel_parameter - 0.1) * (fresnel_parameter - 0.1) + 1.0)
    argument = :math.sqrt((t - 0.1) * (t - 0.1) + 1.0) + t - 0.1

    6.9 + 20.0 * :math.log10(argument)
  end

  defp segment_occluded_by_others?(a, b, walls, ignored_ids) do
    Enum.any?(walls, fn
      %World.Wall{id: id, vertices: vertices, normal: normal} ->
        not MapSet.member?(ignored_ids, id) and length(vertices) >= 3 and
          Geometry.segment_intersects_polygon?(a, b, vertices, normal)

      _ ->
        false
    end)
  end

  defp closest_point_on_infinite_line(point, tx_pos, direction) do
    projection = Geometry.dot(Geometry.sub(point, tx_pos), direction)
    extent = max(abs(projection), 1.0) + 1.0
    segment_start = Geometry.sub(tx_pos, Geometry.scale(direction, extent))
    segment_end = Geometry.add(tx_pos, Geometry.scale(direction, extent))

    Geometry.closest_point_on_segment(point, {segment_start, segment_end})
  end

  defp perpendicular_component(vector, direction) do
    parallel = Geometry.scale(direction, Geometry.dot(vector, direction))
    Geometry.sub(vector, parallel)
  end

  defp line_direction(tx_pos, rx_pos) do
    case Geometry.normalize(Geometry.sub(rx_pos, tx_pos)) do
      {:ok, direction} -> {:ok, direction}
      {:error, :zero_vector} -> :error
    end
  end

  defp positive_wavelength(opts) do
    wavelength = Physics.wavelength(opts)

    if finite_positive?(wavelength) do
      {:ok, wavelength}
    else
      :error
    end
  end

  defp positive_speed_of_light(opts) do
    speed_of_light = Physics.speed_of_light(opts)

    if finite_positive?(speed_of_light) do
      {:ok, speed_of_light}
    else
      :error
    end
  end

  defp max_paths(opts) do
    case Keyword.get(opts, :max_paths, @default_max_paths) do
      max_paths when is_integer(max_paths) and max_paths > 0 -> max_paths
      _ -> 0
    end
  end

  defp finite_positive?(number), do: finite_number?(number) and number > 0.0

  defp finite_number?(number) when is_number(number) do
    number == number and abs(number) < 1.0e308
  end

  defp finite_number?(_number), do: false

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
