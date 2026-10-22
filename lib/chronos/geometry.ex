defmodule Chronos.Geometry do
  @type vec3 :: {float(), float(), float()}

  @spec add(vec3(), vec3()) :: vec3()
  def add({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  @spec sub(vec3(), vec3()) :: vec3()
  def sub({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}

  @spec scale(vec3(), float()) :: vec3()
  def scale({x, y, z}, s), do: {x * s, y * s, z * s}

  @spec dot(vec3(), vec3()) :: float()
  def dot({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz

  @spec cross(vec3(), vec3()) :: vec3()
  def cross({ax, ay, az}, {bx, by, bz}),
    do: {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}

  @spec norm(vec3()) :: float()
  def norm(v), do: :math.sqrt(dot(v, v))

  @spec distance(vec3(), vec3()) :: float()
  def distance(a, b), do: norm(sub(a, b))

  @spec normalize(vec3()) :: {:ok, vec3()} | {:error, :zero_vector}
  def normalize(v) do
    n = norm(v)

    if n == 0.0 do
      {:error, :zero_vector}
    else
      {:ok, scale(v, 1.0 / n)}
    end
  end

  @spec ray_plane_intersect(vec3(), vec3(), vec3(), vec3()) ::
          {:ok, vec3(), float()} | :parallel | :behind | {:error, :zero_normal}
  def ray_plane_intersect(ray_origin, ray_dir, plane_point, plane_normal) do
    with {:ok, n_hat} <- normalize(plane_normal) do
      denom = dot(ray_dir, n_hat)

      if abs(denom) < 1.0e-9 do
        :parallel
      else
        t = dot(sub(plane_point, ray_origin), n_hat) / denom

        if t < 0.0 do
          :behind
        else
          {:ok, add(ray_origin, scale(ray_dir, t)), t}
        end
      end
    end
  end

  @spec segment_plane_intersect(vec3(), vec3(), vec3(), vec3()) ::
          {:ok, vec3(), float()} | :parallel | :outside | {:error, :zero_normal}
  def segment_plane_intersect(a, b, plane_point, plane_normal) do
    dir = sub(b, a)

    case ray_plane_intersect(a, dir, plane_point, plane_normal) do
      {:ok, point, t} when t >= 0.0 and t <= 1.0 -> {:ok, point, t}
      {:ok, _point, _t} -> :outside
      other -> other
    end
  end

  @spec reflect_point_across_plane(vec3(), vec3(), vec3()) ::
          {:ok, vec3()} | {:error, :zero_normal}
  def reflect_point_across_plane(point, plane_point, plane_normal) do
    with {:ok, n_hat} <- normalize(plane_normal) do
      v = sub(point, plane_point)
      dist = dot(v, n_hat)
      reflected = sub(point, scale(n_hat, 2.0 * dist))
      {:ok, reflected}
    end
  end

  @spec point_in_polygon(vec3(), list(vec3()), vec3()) :: boolean()
  def point_in_polygon(_point, vertices, _plane_normal) when length(vertices) < 3, do: false

  def point_in_polygon(point, vertices, plane_normal) do
    {proj_point, proj_vertices} = project_to_2d(point, vertices, plane_normal)
    point_in_polygon_2d(proj_point, proj_vertices)
  end

  @spec segment_intersects_polygon?(vec3(), vec3(), list(vec3()), vec3()) :: boolean()
  def segment_intersects_polygon?(_a, _b, vertices, _plane_normal) when length(vertices) < 3,
    do: false

  def segment_intersects_polygon?(a, b, vertices, plane_normal) do
    [plane_point | _] = vertices

    case segment_plane_intersect(a, b, plane_point, plane_normal) do
      {:ok, point, _t} -> point_in_polygon(point, vertices, plane_normal)
      _ -> false
    end
  end

  defp project_to_2d(point, vertices, {nx, ny, nz}) do
    {ax, ay, az} = {abs(nx), abs(ny), abs(nz)}

    drop =
      cond do
        ax >= ay and ax >= az -> :x
        ay >= ax and ay >= az -> :y
        true -> :z
      end

    {project(point, drop), Enum.map(vertices, &project(&1, drop))}
  end

  defp project({_x, y, z}, :x), do: {y, z}
  defp project({x, _y, z}, :y), do: {x, z}
  defp project({x, y, _z}, :z), do: {x, y}

  defp point_in_polygon_2d(_point, vertices) when length(vertices) < 3, do: false

  defp point_in_polygon_2d({px, py}, vertices) do
    [first | rest] = vertices
    pairs = Enum.zip(vertices, rest ++ [first])

    crossings =
      Enum.count(pairs, fn {{x1, y1}, {x2, y2}} ->
        cond do
          y1 == y2 ->
            false

          py < min(y1, y2) or py >= max(y1, y2) ->
            false

          true ->
            x_intersect = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
            x_intersect > px
        end
      end)

    rem(crossings, 2) == 1
  end
end
