# Scene Project Zero-Span Guard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure `Scene.project/3` raises a clear `ArgumentError` when bounds have zero span.

**Architecture:** Add a regression test in `test/chronos/scene_test.exs` that exercises zero-span bounds and expects an `ArgumentError`, then implement a minimal guard in `lib/chronos/scene.ex` to raise with an explicit message. Follow TDD red-green flow and verify with targeted test run.

**Tech Stack:** Elixir, ExUnit, Mix

### Task 1: Add failing regression test

**Files:**
- Modify: `test/chronos/scene_test.exs`

**Step 1: Write the failing test**

```elixir
test "project/3 raises when bounds have zero span" do
  assert_raise ArgumentError, ~r/zero span/i, fn ->
    Scene.project(0.5, {1.0, 1.0}, {0.0, 1.0})
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/chronos/scene_test.exs`
Expected: FAIL with no `ArgumentError` or wrong message.

### Task 2: Implement minimal guard

**Files:**
- Modify: `lib/chronos/scene.ex`

**Step 1: Write minimal implementation**

```elixir
def project(value, {min, max}, bounds) when min == max do
  raise ArgumentError, "Scene.project/3 requires non-zero bounds span"
end
```

**Step 2: Run test to verify it passes**

Run: `mix test test/chronos/scene_test.exs`
Expected: PASS

### Task 3: Commit fix

**Files:**
- Stage: `test/chronos/scene_test.exs`, `lib/chronos/scene.ex`

**Step 1: Commit**

```bash
git add test/chronos/scene_test.exs lib/chronos/scene.ex
git commit -m "fix: guard zero-span scene bounds"
```
