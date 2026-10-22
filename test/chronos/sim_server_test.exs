defmodule Chronos.SimServerTest do
  use ExUnit.Case, async: true

  test "emits frames with increasing tick" do
    {:ok, pid} = Chronos.SimServer.start_link(seed: 7, tick_ms: 10)
    {:ok, frame1} = Chronos.SimServer.next_frame(pid)
    {:ok, frame2} = Chronos.SimServer.next_frame(pid)

    assert frame1.tick == 0
    assert frame2.tick == 1
  end
end
