# Scene Bounds Helper Documentation Implementation Plan

> **Historical and not implemented as written:** `ChronosWeb.SimLive` never
> gained a public `scene_bounds/1`. Bounds moved to `Chronos.Scene.bounds/2`,
> which derives them from nodes and wall vertices. See
> [../ARCHITECTURE.md](../ARCHITECTURE.md). This file is retained as a record of
> the earlier plan.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `@doc` and `@spec` annotations to the public `scene_bounds/1` helper so default bounds behavior is documented and tested.

**Architecture:** The `scene_bounds/1` helper lives in the `ChronosWeb.SimLive` module. We'll add documentation and a type spec alongside the function definition, and only introduce a default-bounds module attribute if the module already uses similar attributes. If the tests depend on exact defaults, update the sim live test to match.

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit.

### Task 1: Document scene bounds helper

**Files:**
- Modify: `lib/chronos_web/live/sim_live.ex`
- Test: `test/chronos_web/sim_live_test.exs`

**Step 1: Write the failing test (if needed)**

```elixir
test "scene_bounds/1 documents default bounds" do
  # Update this test only if the module introduces a default bounds attribute
  # or if existing expectations must align with the new documentation.
  bounds = ChronosWeb.SimLive.scene_bounds(%{world: []})
  assert bounds == %{min: {0.0, 0.0}, max: {1.0, 1.0}}
end
```

**Step 2: Run test to verify it fails (if added or updated)**

Run: `mix test test/chronos_web/sim_live_test.exs`
Expected: FAIL if the test expectation is wrong or missing documentation alignment.

**Step 3: Write minimal implementation**

```elixir
@doc """
Returns the scene bounds for the current simulation world.

If the world has no entities, returns default bounds so the scene
has a stable, non-zero viewport.
"""
@spec scene_bounds(%{world: list()}) :: %{min: {float(), float()}, max: {float(), float()}}
def scene_bounds(%{world: []}) do
  %{min: {0.0, 0.0}, max: {1.0, 1.0}}
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/chronos_web/sim_live_test.exs`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/chronos_web/live/sim_live.ex test/chronos_web/sim_live_test.exs
git commit -m "docs: document scene bounds helper"
```
