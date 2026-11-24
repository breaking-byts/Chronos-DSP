defmodule Chronos.SceneEdit do
  @moduledoc """
  Server-side validation and application of canvas drag commits (issue #34).

  The `SimCanvas` hook previews drags locally and pushes ONE `commit_geometry`
  event on pointer release. This module re-validates that payload — the client
  is never trusted: positions are clamped to the viewport bounds plus a small
  margin, whole-wall drags must be pure translations, and endpoint drags keep
  every wall edge above a minimum length so a wall cannot collapse.

  Payload shapes (string keys, XY only — z is preserved from the current world
  and is edited via the panel in slice #35):

    * `%{"kind" => "node", "id" => id, "pos" => [x, y]}`
    * `%{"kind" => "wall", "id" => id, "vertices" => [[x, y], ...]}` — every
      vertex, moved by a single shared translation
    * `%{"kind" => "wall_vertex", "id" => id, "index" => i, "pos" => [x, y]}`

  When the LiveView's snap-to-grid toggle is on, the payload may carry
  `"grid_step"` (the grid spacing the canvas draws). Node/endpoint positions
  and whole-wall translation deltas are rounded to that step before clamping.

  Dragged nodes also get zero velocity so they stay where they were dropped;
  `Chronos.SimServer` switches to linear velocity stepping once a world has
  been edited, so scenario kinematics no longer overwrite the edit.
  """

  alias Chronos.World

  @bounds_margin 0.25
  @min_wall_edge 0.1
  @translation_tolerance 1.0e-6
  @max_grid_step 1_000.0

  @doc "World-unit margin added around the viewport bounds when clamping drags."
  @spec bounds_margin() :: float()
  def bounds_margin, do: @bounds_margin

  @doc "Minimum XY edge length (world units) kept between adjacent wall vertices."
  @spec min_wall_edge() :: float()
  def min_wall_edge, do: @min_wall_edge

  @doc """
  Applies a validated drag commit to `world`.

  `bounds` are the session's current XY viewport bounds (tuple form, as
  returned by `Chronos.Scene.bounds/2`). Options:

    * `:snap` - round to the grid when true (default `false`)
    * `:grid_step` - grid spacing supplied by the client; ignored unless
      finite and in `0 < step <= 1000`

  Returns `{:ok, world}` or `{:error, :invalid_payload | :unknown_entity}`.
  """
  @spec apply(World.t(), Chronos.Scene.bounds(), map(), keyword()) ::
          {:ok, World.t()} | {:error, :invalid_payload | :unknown_entity}
  def apply(world, bounds, payload, opts \\ [])

  def apply(%World{} = world, bounds, %{"kind" => "node", "id" => id, "pos" => pos}, opts) do
    with {:ok, x, y} <- parse_xy(pos),
         {:ok, node} <- fetch_node(world, id) do
      {x, y} = maybe_snap({x, y}, opts)
      {x, y} = clamp_point({x, y}, bounds)
      {_, _, z} = node.pos
      node = %{node | pos: {x, y, z}, vel: {0.0, 0.0, 0.0}}
      {:ok, %{world | nodes: Map.put(world.nodes, node.id, node)}}
    end
  end

  def apply(
        %World{} = world,
        bounds,
        %{"kind" => "wall", "id" => id, "vertices" => vertices},
        opts
      ) do
    with {:ok, wall} <- fetch_wall(world, id),
         {:ok, points} <- parse_vertices(vertices, length(wall.vertices)),
         {:ok, dx, dy} <- translation_delta(wall.vertices, points) do
      {dx, dy} = maybe_snap({dx, dy}, opts)
      {dx, dy} = clamp_translation(wall.vertices, {dx, dy}, bounds)
      vertices = Enum.map(wall.vertices, fn {x, y, z} -> {x + dx, y + dy, z} end)
      {:ok, put_wall(world, %{wall | vertices: vertices})}
    end
  end

  def apply(
        %World{} = world,
        bounds,
        %{"kind" => "wall_vertex", "id" => id, "index" => index, "pos" => pos},
        opts
      ) do
    with {:ok, wall} <- fetch_wall(world, id),
         :ok <- validate_index(index, length(wall.vertices)),
         {:ok, x, y} <- parse_xy(pos) do
      {x, y} = maybe_snap({x, y}, opts)
      {x, y} = clamp_point({x, y}, bounds)

      case place_vertex({x, y}, wall.vertices, index, bounds) do
        {:ok, {x, y}} ->
          vertices =
            List.replace_at(wall.vertices, index, {x, y, elem(Enum.at(wall.vertices, index), 2)})

          {:ok, put_wall(world, %{wall | vertices: vertices})}

        :error ->
          {:error, :invalid_payload}
      end
    end
  end

  def apply(_world, _bounds, _payload, _opts), do: {:error, :invalid_payload}

  defp fetch_node(_world, id) when not is_binary(id), do: {:error, :invalid_payload}

  defp fetch_node(world, id) do
    case Enum.find(world.nodes, fn {node_id, _node} -> to_string(node_id) == id end) do
      {_id, node} -> {:ok, node}
      nil -> {:error, :unknown_entity}
    end
  end

  defp fetch_wall(_world, id) when not is_binary(id), do: {:error, :invalid_payload}

  defp fetch_wall(world, id) do
    case Enum.find(world.walls, fn {wall_id, _wall} -> to_string(wall_id) == id end) do
      {_id, wall} -> {:ok, wall}
      nil -> {:error, :unknown_entity}
    end
  end

  defp put_wall(world, wall), do: %{world | walls: Map.put(world.walls, wall.id, wall)}

  defp parse_xy([x, y]) when is_number(x) and is_number(y), do: {:ok, x * 1.0, y * 1.0}
  defp parse_xy(_pos), do: {:error, :invalid_payload}

  defp parse_vertices(vertices, expected)
       when is_list(vertices) and length(vertices) == expected do
    vertices
    |> Enum.reduce_while([], fn pos, acc ->
      case parse_xy(pos) do
        {:ok, x, y} -> {:cont, [{x, y} | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      points -> {:ok, Enum.reverse(points)}
    end
  end

  defp parse_vertices(_vertices, _expected), do: {:error, :invalid_payload}

  defp validate_index(index, count) when is_integer(index) and index >= 0 and index < count,
    do: :ok

  defp validate_index(_index, _count), do: {:error, :invalid_payload}

  # A whole-wall commit must move every vertex by the same XY delta; anything
  # else is a malformed (or tampered) payload.
  defp translation_delta([old | _] = old_vertices, [new | _] = new_vertices) do
    {ox, oy, _} = old
    {nx, ny} = new
    dx = nx - ox
    dy = ny - oy

    consistent? =
      Enum.zip(old_vertices, new_vertices)
      |> Enum.all?(fn {{ax, ay, _}, {bx, by}} ->
        abs(bx - ax - dx) <= @translation_tolerance and
          abs(by - ay - dy) <= @translation_tolerance
      end)

    if consistent?, do: {:ok, dx, dy}, else: {:error, :invalid_payload}
  end

  defp maybe_snap({x, y}, opts) do
    if Keyword.get(opts, :snap, false) do
      case grid_step(opts) do
        {:ok, step} -> {round(x / step) * step, round(y / step) * step}
        :error -> {x, y}
      end
    else
      {x, y}
    end
  end

  defp grid_step(opts) do
    case Keyword.get(opts, :grid_step) do
      step when is_number(step) and step > 0 and step <= @max_grid_step -> {:ok, step * 1.0}
      _ -> :error
    end
  end

  defp clamp_point({x, y}, %{min: {min_x, min_y}, max: {max_x, max_y}}) do
    {
      clamp(x, min_x - @bounds_margin, max_x + @bounds_margin),
      clamp(y, min_y - @bounds_margin, max_y + @bounds_margin)
    }
  end

  # Clamp a shared translation so EVERY vertex stays inside bounds + margin.
  defp clamp_translation(vertices, {dx, dy}, %{min: {min_x, min_y}, max: {max_x, max_y}}) do
    {
      clamp_axis(dx, vertices, 0, min_x - @bounds_margin, max_x + @bounds_margin),
      clamp_axis(dy, vertices, 1, min_y - @bounds_margin, max_y + @bounds_margin)
    }
  end

  defp clamp_axis(delta, vertices, axis, lower, upper) do
    lo = Enum.max(Enum.map(vertices, fn vertex -> lower - elem(vertex, axis) end))
    hi = Enum.min(Enum.map(vertices, fn vertex -> upper - elem(vertex, axis) end))
    # A wall wider than the viewport cannot translate inside it; hold it still.
    if lo > hi, do: 0.0, else: clamp(delta, lo, hi)
  end

  # A dragged vertex must stay inside bounds + margin AND at least
  # @min_wall_edge from each cyclic neighbour. A single pass of radial pushes
  # cannot enforce both: pushing away from one neighbour can shorten the other
  # edge, and pushing after clamping can leave the viewport. Try the clamped
  # point first, then a bounded fan of points on the minimum-radius circle
  # around each neighbour (clamped again), and reject the commit when no
  # candidate satisfies both constraints.
  defp place_vertex(point, vertices, index, bounds) do
    neighbours = neighbour_vertices(vertices, index)

    if valid_placement?(point, neighbours) do
      {:ok, point}
    else
      {px, py} = point

      candidates =
        neighbours
        |> Enum.flat_map(fn {ax, ay, _} ->
          base = :math.atan2(py - ay, px - ax)

          for step <- -8..8 do
            angle = base + step * :math.pi() / 8.0

            clamp_point(
              {ax + :math.cos(angle) * @min_wall_edge, ay + :math.sin(angle) * @min_wall_edge},
              bounds
            )
          end
        end)
        |> Enum.uniq()
        |> Enum.sort_by(fn candidate -> squared_distance(candidate, point) end)

      case Enum.find(candidates, &valid_placement?(&1, neighbours)) do
        nil -> :error
        placed -> {:ok, placed}
      end
    end
  end

  defp neighbour_vertices(vertices, index) do
    count = length(vertices)

    if count < 2 do
      []
    else
      [rem(index - 1 + count, count), rem(index + 1, count)]
      |> Enum.map(&Enum.at(vertices, &1))
    end
  end

  defp valid_placement?({x, y}, neighbours) do
    Enum.all?(neighbours, fn {ax, ay, _} ->
      dx = x - ax
      dy = y - ay
      dx * dx + dy * dy >= @min_wall_edge * @min_wall_edge - 1.0e-12
    end)
  end

  defp squared_distance({x1, y1}, {x2, y2}), do: (x1 - x2) ** 2 + (y1 - y2) ** 2

  defp clamp(value, lower, upper), do: value |> max(lower) |> min(upper)
end
