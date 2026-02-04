defmodule Chronos.SimFrameTest do
  use ExUnit.Case, async: true

  test "frame includes nodes, walls, paths, and metrics" do
    world = Chronos.World.new()
    frame = Chronos.SimFrame.from_world(world, tick: 0)

    assert Map.has_key?(frame, :nodes)
    assert Map.has_key?(frame, :walls)
    assert Map.has_key?(frame, :paths)
    assert Map.has_key?(frame, :metrics)
  end
end
