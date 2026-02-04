# Scene Projection Helper Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a minimal scene projection helper that maps 3D points into 2D viewport coordinates.

**Architecture:** Introduce a lightweight `Chronos.Scene` module with a single `project/3` function that normalizes x/y coordinates against bounds and maps them to viewport dimensions. A new focused test validates projection behavior against expected viewport coordinates.

**Tech Stack:** Elixir, ExUnit.

### Task 1: Add scene projection helper

**Files:**
- Create: `lib/chronos/scene.ex`
- Test: `test/chronos/scene_test.exs`

**Step 1: Write the failing test**

```elixir
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
```

**Step 2: Run test to verify it fails**

Run: `mix test test/chronos/scene_test.exs`
Expected: FAIL with undefined module/function errors.

**Step 3: Write minimal implementation**

```elixir
  @type vec3 :: {float(), float(), float()}

  def project({x, y, _z}, %{min: {min_x, min_y}, max: {max_x, max_y}}, %{width: w, height: h}) do
    nx = (x - min_x) / (max_x - min_x)
    ny = (y - min_y) / (max_y - min_y)
    {nx * w, (1.0 - ny) * h}
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/chronos/scene_test.exs`
Expected: PASS.

**Step 5: Commit**

```bash
git commit -m "feat: add 2D scene projection helper"
```
