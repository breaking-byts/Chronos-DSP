# Frame Payload Shape Implementation Plan

> **Historical:** this plan describes the first minimal frame shape. The current
> frame also carries viewport bounds, display paths, metrics, and a DSP snapshot;
> see [../ARCHITECTURE.md](../ARCHITECTURE.md) and
> [../architecture/hybrid-ui.md](../architecture/hybrid-ui.md).

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a simulation frame payload shape with nodes, walls, paths, and metrics.

**Architecture:** Introduce a `Chronos.SimFrame` module that builds a frame map from a `Chronos.World` plus a tick. The frame is a simple map of lists and metrics, and the server is adjusted to expose or use this frame to match the payload shape.

**Tech Stack:** Elixir, ExUnit, Mix.

### Task 2: Frame payload shape

**Files:**
- Create: `lib/chronos/sim_frame.ex`
- Modify: `lib/chronos/sim_server.ex`
- Test: `test/chronos/sim_frame_test.exs`

**Step 1: Write the failing test**

```elixir
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
```

**Step 2: Run test to verify it fails**

Run: `mix test test/chronos/sim_frame_test.exs`
Expected: FAIL with `Chronos.SimFrame` undefined

**Step 3: Write minimal implementation**

```elixir
defmodule Chronos.SimFrame do
  def from_world(world, opts) do
    tick = Keyword.fetch!(opts, :tick)

    %{
      tick: tick,
      nodes: Map.values(world.nodes),
      walls: Map.values(world.walls),
      paths: [],
      metrics: %{ber: 0.0, path_count: 0}
    }
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/chronos/sim_frame_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/chronos/sim_frame.ex lib/chronos/sim_server.ex test/chronos/sim_frame_test.exs
git commit -m "feat: define simulation frame payload"
```
