# UI Vertical Slice Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a deterministic LiveView dashboard with 2D scene projection, constellation plot, and BER/power trend history.

**Architecture:** Add a small scene/metrics helper layer in Elixir, extend `SimLive` to compute metrics and render SVG panels, and add ExUnit tests for metrics, projection, and BER trend determinism. Keep rendering server-side (no new JS).

**Tech Stack:** Elixir (Phoenix LiveView, ExUnit), existing Rust NIF via Rustler.

### Task 1: Add scene projection helper

**Files:**
- Create: `lib/chronos/scene.ex`
- Test: `test/chronos/scene_test.exs`

**Step 1: Write the failing test**

```elixir
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
```

**Step 2: Run test to verify it fails**

Run: `mix test test/chronos/scene_test.exs`
Expected: FAIL with undefined module/function errors.

**Step 3: Write minimal implementation**

```elixir
defmodule Chronos.Scene do
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
git add lib/chronos/scene.ex test/chronos/scene_test.exs
git commit -m "feat: add 2D scene projection helper"
```

### Task 2: Add deterministic metrics helpers

**Files:**
- Create: `lib/chronos/metrics.ex`
- Test: `test/chronos/metrics_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule Chronos.MetricsTest do
  use ExUnit.Case, async: true

  alias Chronos.Metrics

  test "received power computes mean energy" do
    samples = [{1.0, 0.0}, {0.0, 1.0}]
    assert_in_delta Metrics.received_power(samples), 1.0, 1.0e-9
  end

  test "history caps length" do
    history = Enum.map(1..5, &%{time_s: &1})
    assert length(Metrics.push_history(history, %{time_s: 6}, 5)) == 5
    assert hd(Metrics.push_history(history, %{time_s: 6}, 5)).time_s == 2
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/chronos/metrics_test.exs`
Expected: FAIL with undefined module/function errors.

**Step 3: Write minimal implementation**

```elixir
defmodule Chronos.Metrics do
  @spec received_power(list({float(), float()})) :: float()
  def received_power(samples) do
    count = max(length(samples), 1)

    samples
    |> Enum.reduce(0.0, fn {re, im}, acc -> acc + re * re + im * im end)
    |> Kernel./(count)
  end

  @spec push_history(list(map()), map(), pos_integer()) :: list(map())
  def push_history(history, entry, limit) do
    history = history ++ [entry]
    if length(history) <= limit, do: history, else: tl(history)
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/chronos/metrics_test.exs`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/chronos/metrics.ex test/chronos/metrics_test.exs
git commit -m "feat: add deterministic metrics helpers"
```

### Task 3: Add end-to-end BER trend test

**Files:**
- Modify: `test/chronos/sim_test.exs`

**Step 1: Write the failing test**

```elixir
  test "ber worsens as noise power increases" do
    world =
      World.new()
      |> World.add_node(%World.Node{id: :tx1, type: :tx, pos: {0.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}})
      |> World.add_node(%World.Node{id: :rx1, type: :rx, pos: {2.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}})

    bits = Enum.take(Stream.cycle([0, 0, 1, 1]), 128)
    tx = Chronos.Modem.qpsk_modulate(bits)
    tx_bin = Packing.pack_complex(tx)

    ber = fn noise_power ->
      rx_bin =
        Sim.render(world, tx_bin,
          sample_rate: 48_000.0,
          speed_of_light: 299_792_458.0,
          noise_power: noise_power,
          seed: 7
        )
        |> Map.fetch!(:rx1)

      rx_bits = rx_bin |> Packing.unpack_complex() |> Chronos.Modem.qpsk_demodulate()
      Chronos.Modem.ber(bits, rx_bits)
    end

    ber_low = ber.(0.0)
    ber_mid = ber.(0.05)
    ber_high = ber.(0.2)

    assert ber_low <= ber_mid
    assert ber_mid <= ber_high
  end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/chronos/sim_test.exs:1`
Expected: FAIL if deterministic BER monotonicity not yet guaranteed.

**Step 3: Write minimal implementation**

If failures occur, ensure `Sim.render/3` passes the provided seed into DSP and that all random sources use it consistently. Update any helpers as needed.

**Step 4: Run test to verify it passes**

Run: `mix test test/chronos/sim_test.exs:1`
Expected: PASS.

**Step 5: Commit**

```bash
git add test/chronos/sim_test.exs lib/chronos/*.ex
git commit -m "test: add BER trend regression"
```

### Task 4: Extend LiveView assigns and rendering

**Files:**
- Modify: `lib/chronos_web/live/sim_live.ex`
- Modify: `test/chronos_web/sim_live_test.exs`

**Step 1: Write the failing test**

```elixir
  test "sim live assigns include metrics and history", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert %{metrics: metrics, history: history} = view |> element("main") |> render() |> Phoenix.LiveViewTest.render()
    assert is_map(metrics)
    assert is_list(history)
  end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/chronos_web/sim_live_test.exs`
Expected: FAIL due to missing assigns.

**Step 3: Write minimal implementation**

Update `ChronosWeb.SimLive` to:
- Use `Chronos.Metrics.received_power/1` for rx power.
- Build `history` with `Metrics.push_history/3` (limit ~60).
- Add a `scene_bounds` and `viewport` for projection, using `Chronos.Scene.project/3`.
- Render SVG panels (scene, constellation, history sparkline) with inline SVG.
- Keep a manual `step` event and add a toggle for auto-step (optional).

**Step 4: Run test to verify it passes**

Run: `mix test test/chronos_web/sim_live_test.exs`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/chronos_web/live/sim_live.ex test/chronos_web/sim_live_test.exs
git commit -m "feat: extend sim live view with dashboard panels"
```

### Task 5: Update README with UI details

**Files:**
- Modify: `README.md`

**Step 1: Write the failing test**

Skip (doc-only change).

**Step 2: Update README**

Add a bullet under “Next Steps” or “Layout” describing the new UI panels and metrics.

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document UI vertical slice panels"
```

### Task 6: Full test run

**Files:**
- None

**Step 1: Run full suite**

Run: `bin/test`
Expected: PASS (allow dependency warnings).

**Step 2: Commit (if needed)**

Only if the test run produced new tracked artifacts (ideally none).
