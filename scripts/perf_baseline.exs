# Performance baseline for issue #25 (research/perf-baseline).
#
# Run with: mix run scripts/perf_baseline.exs
#
# Measures, with warmup + per-iteration timing (System.monotonic_time):
#   1. Frame render latency: SimFrame.from_world/2, metrics_and_dsp/2, metrics/2
#      for the orbit and open_field scenarios.
#   2. Channel.paths_for_rx/3 cost alone, and the per-frame recomputation
#      (SimFrame.build_paths + Sim.render inside build_metrics + the explicit
#      paths_for_rx! in build_metrics => 2R+1 calls per frame for R receivers).
#   3. Export stepped-world cost (mirrors ExportController.step_ticks/2 and
#      history_rows/5, which are private) at 1k/10k/100k ticks, plus the
#      worst-case valid history request (1000 rows).
#   4. SceneStore.list/0 at N=10/50/100 scenes in a temp dir (O(N) evidence).
#   5. Sim.render throughput: Rust NIF vs Chronos.DSP.Reference (profile.exs
#      pattern: 2048 bits -> 1024 QPSK symbols per render).
#
# Numbers are indicative local measurements; CI (pinned toolchain) is the
# authority for regression gating. See docs/research/perf-baseline.md.

alias Chronos.Channel
alias Chronos.DSP
alias Chronos.Modem
alias Chronos.Packing
alias Chronos.Scenario
alias Chronos.SceneStore
alias Chronos.Sim
alias Chronos.SimFrame
alias Chronos.World

# The app logs every sim.render telemetry span at :info; silence it so the
# benchmark tables stay readable (restored at the end of the script).
prev_log_level = Logger.level()
Logger.configure(level: :warning)

defmodule PerfBaseline do
  @moduledoc false

  def stats(times_us) do
    sorted = Enum.sort(times_us)
    n = length(sorted)

    %{
      n: n,
      min: hd(sorted),
      median: Enum.at(sorted, div(n, 2)),
      mean: Enum.sum(sorted) / n,
      p95: Enum.at(sorted, max(0, ceil(0.95 * n) - 1)),
      max: List.last(sorted)
    }
  end

  def bench(label, warmup, iters, fun) do
    if warmup > 0, do: Enum.each(1..warmup, fn _ -> fun.() end)

    times =
      Enum.map(1..iters, fn _ ->
        {us, _result} = :timer.tc(fun)
        us
      end)

    s = stats(times)
    row(label, s)
    s
  end

  def row(label, s) do
    IO.puts(
      :io_lib.format("~-42s ~10.1f ~10.1f ~10.1f ~10.1f ~10.1f ~6w", [
        label,
        s.median / 1,
        s.mean / 1,
        s.p95 / 1,
        s.min / 1,
        s.max / 1,
        s.n
      ])
    )
  end

  def header(title) do
    IO.puts("\n== #{title} ==")

    IO.puts(
      :io_lib.format("~-42s ~10s ~10s ~10s ~10s ~10s ~6s", [
        "measurement",
        "med us",
        "mean us",
        "p95 us",
        "min us",
        "max us",
        "n"
      ])
    )
  end

  # Mirrors ChronosWeb.ExportController.step_ticks/2 (private): each tick
  # advances the scenario by 0.1 s; a single elapsed-time step is NOT
  # equivalent (floating-point trajectory).
  def step_ticks(world, _scenario, 0), do: world

  def step_ticks(world, scenario, count) do
    Enum.reduce(1..count, world, fn _tick, current ->
      Scenario.step(current, scenario, 0.1)
    end)
  end

  # Mirrors ChronosWeb.ExportController.history_rows/5 + collect_history/4:
  # step incrementally from `from`, emit one metrics row per sampled tick.
  def history_rows(scenario, from, to, step, seed) do
    world = step_ticks(Scenario.world(scenario), scenario, from)
    ticks = Enum.to_list(from..to//step)
    collect_history(ticks, world, scenario, step, seed, [])
  end

  defp collect_history([], _world, _scenario, _step, _seed, acc), do: Enum.reverse(acc)

  defp collect_history([tick | rest], world, scenario, step, seed, acc) do
    metrics =
      SimFrame.metrics(world, tick: tick, seed: seed, sample_rate: 48_000.0, noise_power: 0.01)

    row = Map.merge(metrics, %{tick: tick, time_s: world.time_s})
    next_world = if rest == [], do: world, else: step_ticks(world, scenario, step)
    collect_history(rest, next_world, scenario, step, seed, [row | acc])
  end

  def scene_fixture(i) do
    %{
      "name" => :io_lib.format("scene-~3..0b", [i]) |> to_string(),
      "description" => "perf baseline fixture #{i}",
      "nodes" => [
        %{"id" => "tx1", "type" => "tx", "pos" => [0.0, 0.0, 0.0], "vel" => [0.0, 0.0, 0.0]},
        %{"id" => "rx1", "type" => "rx", "pos" => [10.0, 0.0, 0.0], "vel" => [0.0, 0.0, 0.0]}
      ],
      "walls" => [
        %{
          "id" => "w1",
          "vertices" => [
            [-1.0, -2.0, -1.0],
            [-1.0, 2.0, -1.0],
            [-1.0, 2.0, 1.0],
            [-1.0, -2.0, 1.0]
          ],
          "normal" => [1.0, 0.0, 0.0],
          "material" => "brick"
        }
      ]
    }
  end
end

IO.puts("Chronos performance baseline (#25)")

IO.puts(
  "Elixir #{System.version()} / OTP #{System.otp_release()} / schedulers #{System.schedulers_online()}"
)

IO.puts("NIF loaded: #{DSP.nif_loaded?()}")
IO.puts("All timings in microseconds unless noted. med/mean/p95 over n iterations after warmup.")

# ---------------------------------------------------------------------------
# 1 + 2. Frame render latency and channel path cost, per scenario.
# ---------------------------------------------------------------------------
frame_results =
  for scenario <- ["orbit", "open_field"] do
    world = PerfBaseline.step_ticks(Scenario.world(scenario), scenario, 10)
    opts = [tick: 10, seed: 1]
    rx = world |> World.nodes_by_type(:rx) |> Enum.sort_by(&to_string(&1.id)) |> hd()
    {_bits, tx_block} = SimFrame.default_tx_block(256)

    PerfBaseline.header(
      "1/2. Frame + paths — #{scenario} (t=1.0s, 1 tx / 1 rx#{if scenario == "orbit", do: " / 2 walls", else: ""})"
    )

    from_world =
      PerfBaseline.bench("SimFrame.from_world/2", 5, 50, fn ->
        SimFrame.from_world(world, opts)
      end)

    metrics_dsp =
      PerfBaseline.bench("SimFrame.metrics_and_dsp/2", 5, 50, fn ->
        SimFrame.metrics_and_dsp(world, opts)
      end)

    metrics =
      PerfBaseline.bench("SimFrame.metrics/2", 5, 50, fn -> SimFrame.metrics(world, opts) end)

    sim_render =
      PerfBaseline.bench("Sim.render (frame tx block)", 5, 50, fn ->
        Sim.render(world, tx_block, sample_rate: 48_000.0, noise_power: 0.01, seed: 11)
      end)

    paths_default =
      PerfBaseline.bench("Channel.paths_for_rx (max_paths 32)", 5, 100, fn ->
        Channel.paths_for_rx(world, rx.id, [])
      end)

    paths_display =
      PerfBaseline.bench("Channel.paths_for_rx (max_paths 64)", 5, 100, fn ->
        Channel.paths_for_rx(world, rx.id, max_paths: 64)
      end)

    {:ok, paths} = Channel.paths_for_rx(world, rx.id, [])
    IO.puts("paths returned (default cap): #{length(paths)}")

    # Recomputation accounting for from_world with R receivers:
    #   build_paths: R calls (max_paths 64)
    #   build_metrics -> Sim.render: R calls (default cap)
    #   build_metrics -> explicit paths_for_rx!: 1 call (default cap)
    recompute_us = paths_display.median + 2 * paths_default.median

    IO.puts(
      :io_lib.format(
        "path recomputation per frame (R=1): ~.1f us of ~.1f us from_world (~.1f%)",
        [recompute_us / 1, from_world.median / 1, 100.0 * recompute_us / from_world.median]
      )
    )

    %{
      scenario: scenario,
      from_world: from_world,
      metrics_and_dsp: metrics_dsp,
      metrics: metrics,
      sim_render: sim_render,
      paths_default: paths_default,
      paths_display: paths_display,
      path_count: length(paths),
      recompute_us: recompute_us
    }
  end

# ---------------------------------------------------------------------------
# 3. Export stepped-world cost (orbit scenario, as the controller default).
# ---------------------------------------------------------------------------
PerfBaseline.header("3. Export stepping (orbit, 0.1 s per tick)")

stepping =
  for ticks <- [1_000, 10_000, 100_000] do
    iters = if ticks >= 100_000, do: 1, else: 3

    s =
      PerfBaseline.bench("stepped_world ticks=#{ticks}", 0, iters, fn ->
        PerfBaseline.step_ticks(Scenario.world("orbit"), "orbit", ticks)
      end)

    IO.puts(
      :io_lib.format("  -> ~.2f us/tick (~.2f ms total, median)", [
        s.median / ticks,
        s.median / 1000
      ])
    )

    {ticks, s}
  end

# NOTE: from=0,to=100000,step=100 yields div(100000,100)+1 = 1001 rows, which
# the controller REJECTS (> @max_history_rows 1000). The worst-case VALID
# request is from=0,to=99900,step=100 -> exactly 1000 rows.
PerfBaseline.header("3b. History worst case (from=0, to=99900, step=100 -> 1000 rows)")

{history_us, rows} =
  :timer.tc(fn -> PerfBaseline.history_rows("orbit", 0, 99_900, 100, 1) end)

IO.puts("history rows: #{length(rows)}")

IO.puts(
  :io_lib.format("history total: ~.1f ms (~.2f ms/row incl. stepping)", [
    history_us / 1000,
    history_us / 1000 / length(rows)
  ])
)

# ---------------------------------------------------------------------------
# 4. SceneStore.list/0 O(N) evidence.
# ---------------------------------------------------------------------------
PerfBaseline.header("4. SceneStore.list/0 vs scene count (temp dir)")

dir = Path.join(System.tmp_dir!(), "chronos-perf-baseline-#{:erlang.unique_integer([:positive])}")
File.mkdir_p!(dir)
prev_dir = Application.get_env(:chronos, :scene_dir)
Application.put_env(:chronos, :scene_dir, dir)

list_results =
  try do
    created = :counters.new(1, [])

    for n <- [10, 50, 100] do
      start = :counters.get(created, 1)

      for i <- start..(n - 1) do
        {:ok, _scene} = SceneStore.create(PerfBaseline.scene_fixture(i))
        :counters.add(created, 1, 1)
      end

      s = PerfBaseline.bench("list/0 at N=#{n}", 2, 15, fn -> SceneStore.list() end)
      IO.puts(:io_lib.format("  -> ~.1f us/scene", [s.median / n]))
      {n, s}
    end
  after
    Application.put_env(:chronos, :scene_dir, prev_dir)
    File.rm_rf(dir)
  end

# ---------------------------------------------------------------------------
# 5. NIF vs Elixir reference throughput (scripts/profile.exs pattern).
# ---------------------------------------------------------------------------
PerfBaseline.header("5. Sim.render throughput: NIF vs reference (1024 symbols/render)")

world =
  World.new()
  |> World.add_node(%World.Node{id: :tx1, type: :tx, pos: {0.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}})
  |> World.add_node(%World.Node{id: :rx1, type: :rx, pos: {10.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}})

bits = Enum.take(Stream.cycle([0, 1, 1, 0]), 2048)
symbols = Modem.qpsk_modulate(bits)
tx_bin = Packing.pack_complex(symbols)
opts = [sample_rate: 48_000.0, speed_of_light: 299_792_458.0, noise_power: 0.0, seed: 1]
symbols_per_render = length(symbols)

unless DSP.nif_loaded?(),
  do: raise("NIF not loaded — build native/chronos_dsp first (mix compile)")

nif_iters = 200

{nif_us, _} =
  :timer.tc(fn -> Enum.each(1..nif_iters, fn _ -> Sim.render(world, tx_bin, opts) end) end)

nif_throughput = symbols_per_render * nif_iters / (nif_us / 1_000_000)

nif_lat =
  PerfBaseline.bench("Sim.render NIF (per render)", 5, 100, fn ->
    Sim.render(world, tx_bin, opts)
  end)

IO.puts(
  :io_lib.format("NIF: ~w samples in ~.1f ms -> ~.1f samples/sec", [
    symbols_per_render * nif_iters,
    nif_us / 1000,
    nif_throughput
  ])
)

# Force the Elixir reference via the documented test override.
Application.put_env(:chronos, :nif_loaded_override, false)
ref_iters = 50

{ref_us, _} =
  :timer.tc(fn -> Enum.each(1..ref_iters, fn _ -> Sim.render(world, tx_bin, opts) end) end)

ref_throughput = symbols_per_render * ref_iters / (ref_us / 1_000_000)

ref_lat =
  PerfBaseline.bench("Sim.render reference (per render)", 3, 30, fn ->
    Sim.render(world, tx_bin, opts)
  end)

Application.delete_env(:chronos, :nif_loaded_override)

IO.puts(
  :io_lib.format("Reference: ~w samples in ~.1f ms -> ~.1f samples/sec", [
    symbols_per_render * ref_iters,
    ref_us / 1000,
    ref_throughput
  ])
)

IO.puts(:io_lib.format("NIF speedup (bulk throughput): ~.1fx", [nif_throughput / ref_throughput]))

IO.puts("\nDone. Results summary (JSON-ish) for docs:")

IO.puts(
  Jason.encode!(
    %{
      frames: frame_results,
      stepping: Enum.map(stepping, fn {t, s} -> %{ticks: t, stats: s} end),
      history: %{rows: length(rows), total_us: history_us},
      scene_list: Enum.map(list_results, fn {n, s} -> %{n: n, stats: s} end),
      throughput: %{
        nif_samples_per_sec: nif_throughput,
        ref_samples_per_sec: ref_throughput,
        speedup: nif_throughput / ref_throughput,
        nif_render_latency: nif_lat,
        ref_render_latency: ref_lat
      }
    },
    pretty: true
  )
)

Logger.configure(level: prev_log_level)
