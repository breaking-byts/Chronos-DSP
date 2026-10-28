defmodule Chronos.Channel.MultiBounce do
  @moduledoc """
  Higher-order reflection paths via the image-source method.

  Enumerates ordered sequences of distinct walls up to `max_bounces`, mirrors
  the transmitter across each wall in turn, and validates the resulting path
  by intersecting back from the receiver. All validation mirrors the
  first-order model in `Chronos.Channel` so results are numerically identical
  for single-bounce paths.
  """

  alias Chronos.Channel.Path
  alias Chronos.Channel.Physics
  alias Chronos.Geometry
  alias Chronos.Material
  alias Chronos.World

  @type vec3 :: Geometry.vec3()
  @type wall :: World.Wall.t()
  @type opts :: keyword()

  # The ordered wall sequences grow factorially (n walls, k bounces), so the
  # number of candidate sequences that may be examined is capped as well.
  @default_max_candidates 1024

  @doc """
  Returns all reflection paths up to `max_bounces` order, capped at `max_paths`.

  The transmitter is mirrored across an ordered sequence of distinct walls
  [w1, w2, ..., wk]. The receiver segment intersects the last wall, then the
  path is back-tracked to find every bounce point. Every point must lie inside
  its wall polygon, and every leg must be free of occlusions from walls other
  than the ones it leaves and enters.

  ## Options

    * `:max_bounces` - highest reflection order to compute (default 2, minimum 1)
    * `:max_paths`   - hard cap on returned paths (default 64)
    * `:max_candidates` - hard cap on the wall sequences that may be examined
      (default 1024). The number of ordered sequences grows factorially with
      the wall count and bounce order, so this bounds the work per call. The
      lowest reflection orders are examined first, so a scene with many walls
      may not reach the requested bounce order.
    * `:speed_of_light`, `:carrier_freq_hz`, `:global_gain` - the shared
      propagation options from `Chronos.Channel.Physics`

  Paths are ordered by bounce count (all first-order, then second-order, etc.),
  and within each order by the sorted wall ids of the sequence. This order is
  deterministic and stable. Paths that describe the same geometry (a ray that
  hits the corner where two walls meet) are returned once.
  """
  @spec paths(World.Node.t(), World.Node.t(), list(wall()), opts()) :: [Path.t()]
  def paths(tx, rx, walls, opts \\ []) do
    max_bounces = Keyword.get(opts, :max_bounces, 2) |> max(1)
    max_paths = Keyword.get(opts, :max_paths, 64) |> max(1)
    max_candidates = Keyword.get(opts, :max_candidates, @default_max_candidates) |> max(1)

    # Sort walls by id for deterministic enumeration
    sorted_walls = Enum.sort_by(walls, &to_string(&1.id))

    # Build paths for each candidate sequence, stopping at the path cap. The
    # candidate stream is bounded as well, because the number of ordered wall
    # sequences grows factorially with the wall count and bounce order.
    sorted_walls
    |> sequence_stream(max_bounces)
    |> Stream.take(max_candidates)
    |> Enum.reduce_while([], fn seq, acc ->
      if length(acc) >= max_paths do
        {:halt, acc}
      else
        case build_path_for_sequence(tx, rx, seq, sorted_walls, opts) do
          {:ok, path} -> {:cont, [path | acc]}
          {:error, _reason} -> {:cont, acc}
        end
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq_by(&path_key/1)
  end

  # Two bounce orders can describe the same physical path (a ray that hits the
  # corner where two walls meet), so paths are de-duplicated by their geometry.
  # The key rounds to nanometres, which is far below any physical resolution.
  @spec path_key(Path.t()) :: list(tuple())
  defp path_key(%Path{points: points}) do
    Enum.map(points, fn {x, y, z} -> {round(x * 1.0e9), round(y * 1.0e9), round(z * 1.0e9)} end)
  end

  # -------------------------------------------------------------------------
  # Sequence generation
  # -------------------------------------------------------------------------

  @doc false
  @spec sequence_stream(list(wall()), pos_integer()) :: Enumerable.t()
  defp sequence_stream(walls, max_bounces) do
    Stream.flat_map(1..max_bounces, fn order -> ordered_combinations(walls, order) end)
  end

  @doc false
  @spec ordered_combinations(list(wall()), non_neg_integer()) :: Enumerable.t()
  defp ordered_combinations(_walls, 0), do: [[]]

  defp ordered_combinations(walls, k) do
    Stream.flat_map(walls, fn wall ->
      remaining = Enum.reject(walls, &(&1.id == wall.id))
      Stream.map(ordered_combinations(remaining, k - 1), &[wall | &1])
    end)
  end

  # -------------------------------------------------------------------------
  # Path construction for a single wall sequence
  # -------------------------------------------------------------------------

  @doc false
  @spec build_path_for_sequence(
          World.Node.t(),
          World.Node.t(),
          list(wall()),
          list(wall()),
          opts()
        ) :: {:ok, Path.t()} | {:error, term()}
  defp build_path_for_sequence(tx, rx, sequence, scene_walls, opts) do
    with {:ok, images} <- compute_images(tx.pos, sequence),
         {:ok, points} <- find_bounce_points(images, rx.pos, sequence),
         {:ok, true} <- validate_points_in_polygons(points, sequence),
         {:ok, true} <-
           validate_legs_unoccluded(tx.pos, rx.pos, points, sequence, scene_walls) do
      build_path(tx, rx, sequence, points, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Compute successive mirror images of the transmitter across each wall
  @spec compute_images(vec3(), list(wall())) ::
          {:ok, [vec3()]} | {:error, :degenerate_normal}
  defp compute_images(tx_pos, walls) do
    walls
    |> Enum.reduce_while({:ok, [tx_pos]}, fn
      wall, {:ok, [last_image | _] = acc} ->
        case Geometry.reflect_point_across_plane(last_image, hd(wall.vertices), wall.normal) do
          {:ok, image} -> {:cont, {:ok, [image | acc]}}
          {:error, :zero_vector} -> {:halt, {:error, :degenerate_normal}}
        end

      _, {:error, _} = err ->
        {:halt, err}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  # Find bounce points by intersecting from receiver back through the wall planes
  @spec find_bounce_points([vec3()], vec3(), list(wall())) ::
          {:ok, [vec3()]} | {:error, :no_intersection} | {:error, :parallel}
  defp find_bounce_points(images, rx_pos, walls) do
    # images = [image_0, image_1, ..., image_k] where image_0 = tx_pos
    # walls = [w1, w2, ..., wk]
    # We need points p_k, p_{k-1}, ..., p_1

    k = length(walls)

    # Start with the segment (image_k, rx_pos) intersecting wall k
    image_k = Enum.at(images, k)
    wall_k = Enum.at(walls, k - 1)
    plane_point_k = hd(wall_k.vertices)

    case Geometry.segment_plane_intersect(image_k, rx_pos, plane_point_k, wall_k.normal) do
      {:ok, p_k, _t} ->
        # Back-track for remaining walls. `find_remaining_points/4` returns the
        # bounce points already ordered from the first bounce to the last.
        find_remaining_points(images, [p_k], walls, k - 1)

      {:error, :zero_vector} ->
        {:error, :degenerate_normal}

      _ ->
        {:error, :no_intersection}
    end
  end

  @spec find_remaining_points([vec3()], [vec3()], list(wall()), non_neg_integer()) ::
          {:ok, [vec3()]} | {:error, :no_intersection} | {:error, :parallel}
  defp find_remaining_points(_images, points, _walls, 0), do: {:ok, points}

  defp find_remaining_points(images, [p_i | _] = points, walls, i) do
    image_prev = Enum.at(images, i)
    wall_prev = Enum.at(walls, i - 1)
    plane_point = hd(wall_prev.vertices)

    case Geometry.segment_plane_intersect(image_prev, p_i, plane_point, wall_prev.normal) do
      {:ok, p_prev, _t} ->
        find_remaining_points(images, [p_prev | points], walls, i - 1)

      {:error, :zero_vector} ->
        {:error, :degenerate_normal}

      _ ->
        {:error, :no_intersection}
    end
  end

  # Validate every bounce point lies inside its wall polygon
  @spec validate_points_in_polygons([vec3()], list(wall())) ::
          {:ok, true} | {:error, :point_outside_polygon}
  defp validate_points_in_polygons(points, walls) do
    Enum.zip(points, walls)
    |> Enum.all?(fn {point, wall} ->
      Geometry.point_in_polygon(point, wall.vertices, wall.normal)
    end)
    |> case do
      true -> {:ok, true}
      false -> {:error, :point_outside_polygon}
    end
  end

  # Validate every leg is not occluded by walls other than the ones it touches
  @spec validate_legs_unoccluded(vec3(), vec3(), [vec3()], list(wall()), list(wall())) ::
          {:ok, true} | {:error, :leg_occluded}
  defp validate_legs_unoccluded(tx_pos, rx_pos, bounce_points, sequence, scene_walls) do
    legs = build_legs(tx_pos, rx_pos, bounce_points)
    wall_count = length(sequence)

    result =
      Enum.with_index(legs)
      |> Enum.all?(fn {{a, b}, leg_idx} ->
        ignore_ids = leg_wall_ids(leg_idx, wall_count, sequence)
        not segment_occluded_by_any?(a, b, scene_walls, ignore_ids)
      end)

    case result do
      true -> {:ok, true}
      false -> {:error, :leg_occluded}
    end
  end

  @spec build_legs(vec3(), vec3(), [vec3()]) :: [{vec3(), vec3()}]
  defp build_legs(tx_pos, rx_pos, bounce_points) do
    points = [tx_pos | bounce_points] ++ [rx_pos]
    Enum.zip(points, tl(points))
  end

  @spec leg_wall_ids(non_neg_integer(), non_neg_integer(), list(wall())) :: [term()]
  defp leg_wall_ids(leg_idx, wall_count, walls) do
    cond do
      leg_idx == 0 ->
        # First leg: tx -> p1, touches wall 1 (entering)
        [Enum.at(walls, 0).id]

      leg_idx == wall_count ->
        # Last leg: pk -> rx, touches wall k (leaving)
        [Enum.at(walls, wall_count - 1).id]

      leg_idx > 0 and leg_idx < wall_count ->
        # Middle leg: pi -> p_{i+1}, touches wall i (leaving) and wall i+1 (entering)
        [Enum.at(walls, leg_idx - 1).id, Enum.at(walls, leg_idx).id]

      true ->
        []
    end
  end

  # Check if the segment passes through any wall that is not in ignore_ids. A
  # wall that the leg only grazes at one of its ends (the corner of two walls,
  # for example) does not block the leg.
  @spec segment_occluded_by_any?(vec3(), vec3(), list(wall()), [term()]) :: boolean()
  defp segment_occluded_by_any?(a, b, walls, ignore_ids) do
    World.segment_blocked_by?(a, b, walls, ignore_ids)
  end

  # Build the final Path struct
  @spec build_path(World.Node.t(), World.Node.t(), list(wall()), [vec3()], opts()) ::
          {:ok, Path.t()}
  defp build_path(tx, rx, walls, bounce_points, opts) do
    points = [tx.pos | bounce_points] ++ [rx.pos]
    total_length = Physics.path_length(points)

    # Guard against zero-length paths
    if total_length <= 0.0 or not Physics.finite?(total_length) do
      {:error, :zero_length}
    else
      delay_s = total_length / Physics.speed_of_light(opts)

      loss_db =
        Enum.reduce(walls, 0.0, fn wall, acc ->
          acc + Material.reflection_loss_db(wall)
        end)

      gain = Physics.path_gain(total_length, loss_db, opts)

      # Guard against non-finite gain
      if not Physics.finite?(gain) do
        {:error, :non_finite_gain}
      else
        doppler_hz = Physics.doppler_hz(points, tx.vel, rx.vel, Physics.wavelength(opts))

        interactions =
          Enum.map(walls, fn wall -> {:reflection, wall.id} end)

        path = %Path{
          delay_s: delay_s,
          gain: gain,
          doppler_hz: doppler_hz,
          kind: :reflection,
          bounces: length(walls),
          points: points,
          interactions: interactions
        }

        {:ok, path}
      end
    end
  end
end
