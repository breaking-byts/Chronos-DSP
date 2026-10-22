defmodule Chronos.GeometryTest do
  use ExUnit.Case, async: true

  alias Chronos.Geometry

  test "vector operations" do
    assert Geometry.add({1.0, 2.0, 3.0}, {1.0, 1.0, 1.0}) == {2.0, 3.0, 4.0}
    assert Geometry.sub({1.0, 2.0, 3.0}, {1.0, 1.0, 1.0}) == {0.0, 1.0, 2.0}
    assert Geometry.scale({1.0, -2.0, 3.0}, 2.0) == {2.0, -4.0, 6.0}
    assert Geometry.dot({1.0, 0.0, 0.0}, {0.0, 2.0, 0.0}) == 0.0
    assert Geometry.cross({1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}) == {0.0, 0.0, 1.0}
  end

  test "norm and distance" do
    assert_in_delta Geometry.norm({3.0, 4.0, 0.0}), 5.0, 1.0e-9
    assert_in_delta Geometry.distance({0.0, 0.0, 0.0}, {0.0, 3.0, 4.0}), 5.0, 1.0e-9
  end

  test "normalize handles zero vector" do
    assert {:error, :zero_vector} = Geometry.normalize({0.0, 0.0, 0.0})
  end

  test "normalize returns unit vector" do
    assert {:ok, {x, y, z}} = Geometry.normalize({0.0, 0.0, 2.0})
    assert_in_delta x, 0.0, 1.0e-9
    assert_in_delta y, 0.0, 1.0e-9
    assert_in_delta z, 1.0, 1.0e-9
  end

  test "ray-plane intersection hits plane" do
    origin = {0.0, 0.0, 1.0}
    dir = {0.0, 0.0, -1.0}
    plane_point = {0.0, 0.0, 0.0}
    plane_normal = {0.0, 0.0, 1.0}

    assert {:ok, {x, y, z}, t} =
             Geometry.ray_plane_intersect(origin, dir, plane_point, plane_normal)

    assert_in_delta x, 0.0, 1.0e-9
    assert_in_delta y, 0.0, 1.0e-9
    assert_in_delta z, 0.0, 1.0e-9
    assert_in_delta t, 1.0, 1.0e-9
  end

  test "ray-plane intersection is parallel" do
    origin = {0.0, 0.0, 1.0}
    dir = {1.0, 0.0, 0.0}
    plane_point = {0.0, 0.0, 0.0}
    plane_normal = {0.0, 0.0, 1.0}

    assert :parallel = Geometry.ray_plane_intersect(origin, dir, plane_point, plane_normal)
  end

  test "ray-plane intersection behind origin" do
    origin = {0.0, 0.0, 1.0}
    dir = {0.0, 0.0, 1.0}
    plane_point = {0.0, 0.0, 0.0}
    plane_normal = {0.0, 0.0, 1.0}

    assert :behind = Geometry.ray_plane_intersect(origin, dir, plane_point, plane_normal)
  end

  test "segment-plane intersection inside segment" do
    a = {0.0, 0.0, 1.0}
    b = {0.0, 0.0, -1.0}
    plane_point = {0.0, 0.0, 0.0}
    plane_normal = {0.0, 0.0, 1.0}

    assert {:ok, {x, y, z}, t} =
             Geometry.segment_plane_intersect(a, b, plane_point, plane_normal)

    assert_in_delta x, 0.0, 1.0e-9
    assert_in_delta y, 0.0, 1.0e-9
    assert_in_delta z, 0.0, 1.0e-9
    assert_in_delta t, 0.5, 1.0e-9
  end

  test "reflect across plane" do
    point = {0.0, 0.0, 1.0}
    plane_point = {0.0, 0.0, 0.0}
    plane_normal = {0.0, 0.0, 1.0}

    assert {:ok, {x, y, z}} =
             Geometry.reflect_point_across_plane(point, plane_point, plane_normal)

    assert_in_delta x, 0.0, 1.0e-9
    assert_in_delta y, 0.0, 1.0e-9
    assert_in_delta z, -1.0, 1.0e-9
  end

  test "point in polygon on plane" do
    vertices = [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0}, {0.0, 1.0, 0.0}]
    normal = {0.0, 0.0, 1.0}
    assert Geometry.point_in_polygon({0.5, 0.5, 0.0}, vertices, normal)
    refute Geometry.point_in_polygon({1.5, 0.5, 0.0}, vertices, normal)
  end

  test "segment intersects polygon" do
    vertices = [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 1.0, 0.0}, {0.0, 1.0, 0.0}]
    normal = {0.0, 0.0, 1.0}
    a = {0.5, 0.5, 1.0}
    b = {0.5, 0.5, -1.0}
    assert Geometry.segment_intersects_polygon?(a, b, vertices, normal)
  end

  test "degenerate polygon checks return false instead of crashing" do
    normal = {0.0, 0.0, 1.0}
    vertices = [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}]

    refute Geometry.point_in_polygon({0.5, 0.0, 0.0}, vertices, normal)

    refute Geometry.segment_intersects_polygon?(
             {0.5, 0.0, 1.0},
             {0.5, 0.0, -1.0},
             vertices,
             normal
           )
  end
end
