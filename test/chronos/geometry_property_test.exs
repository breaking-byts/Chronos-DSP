defmodule Chronos.GeometryPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chronos.Geometry

  @z_normal {0.0, 0.0, 1.0}

  defp coord(min, max), do: StreamData.float(min: min, max: max)

  defp vec3(min, max) do
    StreamData.tuple({coord(min, max), coord(min, max), coord(min, max)})
  end

  # Regular n-gons are convex by construction; the center is the centroid and
  # lies strictly inside, well away from any edge.
  defp convex_polygon do
    gen all(
          sides <- StreamData.integer(3..10),
          radius <- coord(0.5, 50.0),
          center_x <- coord(-100.0, 100.0),
          center_y <- coord(-100.0, 100.0),
          rotation <- coord(0.0, 6.28)
        ) do
      vertices =
        for i <- 0..(sides - 1) do
          angle = rotation + 2.0 * :math.pi() * i / sides
          {center_x + radius * :math.cos(angle), center_y + radius * :math.sin(angle), 0.0}
        end

      {vertices, {center_x, center_y, 0.0}, radius}
    end
  end

  property "the centroid of a convex polygon is inside it" do
    check all({vertices, centroid, _radius} <- convex_polygon()) do
      assert Geometry.point_in_polygon(centroid, vertices, @z_normal)
      assert Geometry.point_strictly_inside_polygon?(centroid, vertices, @z_normal)
    end
  end

  property "a far-away point is outside the polygon" do
    check all({vertices, {cx, cy, _cz}, radius} <- convex_polygon()) do
      far = {cx + 10.0 * radius + 1.0, cy, 0.0}
      refute Geometry.point_in_polygon(far, vertices, @z_normal)
      refute Geometry.point_strictly_inside_polygon?(far, vertices, @z_normal)
    end
  end

  property "every vertex counts as inside (boundary included)" do
    check all(
            {vertices, _centroid, _radius} <- convex_polygon(),
            vertex <- StreamData.member_of(vertices)
          ) do
      assert Geometry.point_in_polygon(vertex, vertices, @z_normal)
    end
  end

  property "fewer than three vertices never contain a point" do
    check all(
            vertices <- StreamData.list_of(vec3(-100.0, 100.0), max_length: 2),
            point <- vec3(-100.0, 100.0)
          ) do
      refute Geometry.point_in_polygon(point, vertices, @z_normal)
      refute Geometry.point_strictly_inside_polygon?(point, vertices, @z_normal)
      refute Geometry.segment_intersects_polygon?(point, point, vertices, @z_normal)
    end
  end

  # Segments whose z difference is at least 1 m hit the z=0 plane
  # well-conditioned, so the two intersection directions agree far inside the
  # geometry tolerances.
  defp crossing_segment do
    gen all(
          a <- vec3(-100.0, 100.0),
          b <- vec3(-100.0, 100.0),
          abs(elem(a, 2) - elem(b, 2)) >= 1.0
        ) do
      {a, b}
    end
  end

  property "segment/polygon intersection is symmetric in the segment endpoints" do
    check all(
            {vertices, _centroid, _radius} <- convex_polygon(),
            {a, b} <- crossing_segment()
          ) do
      assert Geometry.segment_intersects_polygon?(a, b, vertices, @z_normal) ==
               Geometry.segment_intersects_polygon?(b, a, vertices, @z_normal)
    end
  end

  property "segment/plane intersection point is symmetric in the segment endpoints" do
    check all(
            {vertices, _centroid, _radius} <- convex_polygon(),
            {a, b} <- crossing_segment()
          ) do
      plane_point = hd(vertices)

      case {Geometry.segment_plane_intersect(a, b, plane_point, @z_normal),
            Geometry.segment_plane_intersect(b, a, plane_point, @z_normal)} do
        {{:ok, p1, t1}, {:ok, p2, t2}} ->
          assert Geometry.distance(p1, p2) <= 1.0e-9
          assert abs(t1 + t2 - 1.0) <= 1.0e-9

        {same, same} ->
          :ok

        {one, other} ->
          flunk("asymmetric segment/plane classification: #{inspect(one)} vs #{inspect(other)}")
      end
    end
  end

  property "reflecting a point across a plane twice returns the point" do
    check all(
            point <- vec3(-100.0, 100.0),
            plane_point <- vec3(-100.0, 100.0),
            normal <- vec3(-10.0, 10.0),
            Geometry.norm(normal) > 1.0e-3
          ) do
      assert {:ok, reflected} = Geometry.reflect_point_across_plane(point, plane_point, normal)
      assert {:ok, back} = Geometry.reflect_point_across_plane(reflected, plane_point, normal)
      tolerance = 1.0e-9 * (1.0 + Geometry.norm(point))
      assert Geometry.distance(point, back) <= tolerance
    end
  end

  property "boundary and strict-inside classification is invariant to cyclic vertex rotation" do
    check all(
            {vertices, _centroid, _radius} <- convex_polygon(),
            edge_idx <- StreamData.integer(0..(length(vertices) - 1)),
            t <- coord(0.1, 0.9),
            shift <- StreamData.integer(0..(length(vertices) - 1))
          ) do
      {ax, ay, az} = Enum.at(vertices, edge_idx)
      {bx, by, bz} = Enum.at(vertices, rem(edge_idx + 1, length(vertices)))
      edge_point = {ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t}

      {head, tail} = Enum.split(vertices, shift)
      rotated = tail ++ head

      assert Geometry.point_in_polygon(edge_point, vertices, @z_normal) ==
               Geometry.point_in_polygon(edge_point, rotated, @z_normal)

      assert Geometry.point_strictly_inside_polygon?(edge_point, vertices, @z_normal) ==
               Geometry.point_strictly_inside_polygon?(edge_point, rotated, @z_normal)
    end
  end
end
