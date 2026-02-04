defmodule Chronos.SceneTest do
  use ExUnit.Case, async: true

  alias Chronos.Scene

  test "projects 3D points into 2D bounds" do
    bounds = %{min: {-5.0, -5.0}, max: {5.0, 5.0}}
    viewport = %{width: 200, height: 100}

    assert Scene.project({0.0, 0.0, 2.0}, bounds, viewport) == {100.0, 50.0}
    assert Scene.project({5.0, 5.0, 0.0}, bounds, viewport) == {200.0, 0.0}
    assert Scene.project({-5.0, -5.0, 0.0}, bounds, viewport) == {0.0, 100.0}
  end
end
