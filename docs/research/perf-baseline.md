# Performance baseline — issue #25

Research branch `research/perf-baseline`, base `212dadc` (master). This is the
measurement baseline the #22 design lock waits on. Reproduce with:

```sh
mix compile                      # builds the Rust NIF (release) via Rustler
mix run scripts/perf_baseline.exs
```

## Environment and honesty notes

- **Local toolchain:** Elixir 1.20.1 / OTP 29 (erts 17.0.2), 8 schedulers,
  macOS/arm64 laptop. **CI pin:** Elixir 1.19.5-otp-28 / Erlang 28.3.1
  (`.tool-versions`). The task context assumed OTP 28 locally; the actual
  local OTP is 29. All numbers below are **indicative local measurements;
  the CI job on the pinned toolchain is the authority** for any gate.
- Method: `:timer.tc` per iteration after warmup; median / mean / p95 / min /
  max reported. Frame benchmarks: 5 warmup + 50 iterations; paths: 5 + 100;
  `list/0`: 2 + 15; NIF latency: 5 + 100; reference latency: 3 + 30.
  100k-tick stepping and the worst-case history request ran **once** (n=1) to
  keep total runtime bounded — treat those as point estimates.
- Three full runs agreed closely (e.g. orbit `from_world` median 449 / 455 /
  458 µs; NIF throughput 9.36 / 9.39 / 9.35 M samples/s). The reference
  throughput varied ±10% (1.38–1.52 M samples/s), so the NIF speedup is a
  **6.2–6.8× range**, not a precise constant. p95 tails on filesystem-bound
  measurements (`list/0`) move with GC/FS noise (one run showed 7.4 ms p95 at
  N=100 vs 5.6 ms median).
- The NIF artifact was **not** pre-present in this worktree; `mix compile`
  built `native/chronos_dsp` in release mode and copied it to
  `priv/native/chronos_dsp.so` (gitignored). `require_nif` is false in dev;
  the reference path was forced with the documented
  `:chronos, :nif_loaded_override` env override.
- Note for CI design: the current CI Elixir job does **not** build the NIF
  (tests run on the Elixir reference fallback). A NIF-throughput gate needs a
  `cargo build --release` step (or Rustler compile) in that job.
- The script mirrors the controller's **private** `step_ticks/2` and
  `history_rows/5` logic exactly (0.1 s per tick, incremental stepping); it
  does not go through HTTP, so numbers exclude Plug/CSV serialization.

## 1. Frame render latency (t = 1.0 s, 1 tx / 1 rx; orbit adds 2 walls)

Final run, microseconds (median / mean / p95, n=50):

| Measurement | orbit | open_field |
|---|---|---|
| `SimFrame.from_world/2` | **458 / 468 / 557** | **392 / 393 / 419** |
| `SimFrame.metrics_and_dsp/2` | 420 / 421 / 470 | 389 / 389 / 423 |
| `SimFrame.metrics/2` | 181 / 180 / 206 | 141 / 151 / 220 |
| `Sim.render` (frame's 128-symbol tx block) | 109 / 119 / 196 | 75 / 79 / 95 |

Frame cost decomposition (orbit, medians, derived by subtraction):

| Component | ≈ cost | share of `from_world` |
|---|---|---|
| DSP snapshot `build_dsp` (unpack + 64×128 naive DFT spectrum) | 420 − 181 = **239 µs** | **52%** |
| `Sim.render` (paths + pack + NIF render) | **109 µs** | 24% |
| metrics extras (demod, BER, received_power, unpack, 1 paths call) | 181 − 109 = **72 µs** | 16% |
| scene encoding + display paths (`from_world` − `metrics_and_dsp`) | **38 µs** | 8% |

The **spectrum/DSP snapshot is the single largest frame cost**, larger than
the NIF render itself. `metrics/2` (CSV export path) correctly skips it and is
~2.4× cheaper than `metrics_and_dsp/2`.

## 2. Channel path computation and the 2–3× recomputation

`Channel.paths_for_rx/3` alone (median / p95, n=100):

| Scenario | max_paths 32 (default) | max_paths 64 (display) | paths returned |
|---|---|---|---|
| orbit (2 walls, max_bounces 2) | **13 / 18 µs** | 14 / 16 µs | 3 |
| open_field (LOS only) | **1 / 2 µs** | 1 / 3 µs | 1 |

**Recomputation finding (quantified).** For a frame with R receivers,
`SimFrame.from_world/2` computes paths **2R + 1 times**:

1. `build_paths/1` → `Channel.paths_for_rx` per rx (max_paths 64) — `sim_frame.ex:120`
2. `build_metrics` → `Sim.render` → `Channel.paths_for_rx!` per rx — `sim.ex:20`
3. `build_metrics` → explicit `Channel.paths_for_rx!` for `path_count` — `sim_frame.ex:145`

With R=1 that is **3 calls per frame**: measured overhead ≈ 14 + 2×13 =
**40 µs = 8.7% of the 458 µs orbit frame** (open_field: 3 µs = 0.8%). The
`metrics/2` and `metrics_and_dsp/2` API paths still pay 2 calls (R + 1).
Caching one computation per (world, rx, opts) per frame removes ~27–40 µs
today; the win grows with wall count (MultiBounce is combinatorial in walls ×
bounce order) and with R (the dashboard's multi-receiver scenes pay 2R+1).

## 3. Export stepped-world cost (orbit, 0.1 s/tick)

| Request | total (median) | per tick |
|---|---|---|
| `stepped_world` ticks=1,000 (n=3) | **0.129 ms** | 0.13 µs |
| `stepped_world` ticks=10,000 (n=3) | **1.28 ms** | 0.13 µs |
| `stepped_world` ticks=100,000 (n=1) | **13.1 ms** | 0.13 µs |

Stepping is cheap and linear (~0.13 µs/tick: one `move_node` + trig). A
single-frame `metrics?ticks=100000` export therefore costs ≈ 13.1 ms stepping
+ ~0.18 ms metrics ≈ **13.3 ms** — acceptable, but it re-simulates from t=0 on
every request (no caching across requests).

**History worst case.** The literal request `from=0,to=100000,step=100`
produces `div(100000,100)+1 = 1001` rows and is **rejected** by the
controller's 1000-row cap. The worst-case *valid* request is
`from=0,to=99900,step=100` → exactly 1000 rows:

- **182.1 ms total** (n=1), ≈ 0.18 ms/row including stepping.
- Cost is dominated by 1000 × `SimFrame.metrics/2` (~181 µs each ≈ 181 ms);
  the 99,900 incremental ticks add only ~13 ms. History is already
  incremental (bounded by `to`, not re-simulated per row) — the row cap, not
  the stepping, is the binding constraint.

## 4. `SceneStore.list/0` — O(N) evidence

Temp dir, `Application.put_env(:chronos, :scene_dir, ...)`, fixture scenes
(2 nodes + 1 wall each), median / p95 over n=15:

| N scenes | list/0 median | p95 | µs per scene |
|---|---|---|---|
| 10 | **0.56 ms** | 0.82 ms | 56.0 |
| 50 | **2.90 ms** | 3.06 ms | 57.9 |
| 100 | **5.69 ms** | 6.20 ms | 56.9 |

Per-scene cost is flat (~56–58 µs) while total grows 10× from N=10→100:
**linear, confirmed**. Each entry pays `File.read` + `Jason.decode` +
full schema `validate/1` — and `validate` calls `json_encodable?`, which
**re-encodes the scene with `Jason.encode`**, so every list entry is decoded
*and* re-encoded. At the 100-scene cap that is ~5.7 ms per `list/0` call,
paid on every dashboard scene-list refresh. Caching (mtime/etag-keyed, as the
moduledoc already anticipates) or dropping the re-encode from the read path
are the obvious follow-ups. `scene_files/1` (stat-based, used by write-side
eviction) is also O(N) but only stats, no JSON.

## 5. NIF vs Elixir reference throughput

`scripts/profile.exs` pattern: 2048 bits → 1024 QPSK symbols, 1 tx / 1 rx at
10 m, 48 kHz, noise 0, seed 1. Bulk: 200 renders (NIF) / 50 renders
(reference); per-render latency separately benchmarked.

| Implementation | samples/sec (bulk) | per-render median / p95 |
|---|---|---|
| Rust NIF (release) | **9.35 M** | 101 / 121 µs |
| `Chronos.DSP.Reference` | **1.52 M** | 590 / 789 µs |

**NIF speedup: 6.2×** this run (6.2–6.8× across three runs; reference
throughput is the noisier side). Even the fallback renders a 1024-symbol
block in <1 ms, so dev-without-NIF remains usable; production requires the
NIF (`require_nif: true`).

## Hot paths, ranked by cost (orbit frame, per call)

1. **DSP snapshot / naive DFT spectrum** (`SimFrame.build_dsp` → `spectrum/2`):
   ~239 µs, **52% of a dashboard frame**. O(points × samples) Elixir trig.
2. **`Sim.render`** (paths + packing + NIF): ~109 µs, 24%. NIF itself is fast;
   packing/unpacking and telemetry span overhead live here too.
3. **Metrics extras** (QPSK demod, BER, received_power, unpack): ~72 µs, 16%.
4. **Channel path recomputation**: 40 µs total across the frame (8.7%),
   2R+1 calls — cheap today (13 µs/call, 2 walls) but the multiplier and
   wall-count scaling make it the top *structural* fix.
5. **Scene encoding + display paths**: ~38 µs, 8%.
6. **`SceneStore.list/0`**: 5.7 ms at N=100 — off the frame path, but the
   largest single measured cost of any dashboard-adjacent operation.
7. **Export history**: 182 ms worst case, dominated by 1000 × `metrics/2`;
   stepping itself is negligible (0.13 µs/tick).

## Proposal (a): benchmark suite shape

**Benchee-based `mix benchmark` task as the canonical suite; keep this
stdlib script as the zero-dependency smoke.**

- Rationale: `:timer.tc` scripts (this one, `scripts/profile.exs`) are
  dependency-free and run anywhere, but give no standard deviation,
  confidence intervals, or run-to-run comparison. Benchee provides warmup,
  statistical sampling, memory measurements, and JSON/HTML export
  (`benchee_json`/`benchee_html`) for trend tracking. Add `{:benchee, "~> 1.3",
  only: :dev, runtime: false}` (plus `benchee_json`) and a
  `benchmarks/` directory with a `mix benchmark` alias; do not put it in the
  test/prod dependency graph.
- **Scenarios/inputs:** `orbit` and `open_field` at t=0/1/10 s; a wall-heavy
  custom scene (e.g. 8 walls) to stress MultiBounce; **R=1 and R=4 receivers**
  to expose the 2R+1 path-recomputation scaling; frame trio
  (`from_world`/`metrics_and_dsp`/`metrics`); `paths_for_rx` alone; export
  stepping 1k/10k/100k + worst-case history (1000 rows); `SceneStore.list/0`
  at N=10/50/100; NIF vs reference throughput (profile.exs input).
- **CI integration:** a scheduled (nightly) job on the **pinned toolchain**
  (1.19.5-otp-28) that also builds the NIF (`cargo build --release` or the
  Rustler compile path), runs `mix benchmark --format json`, and compares
  against `benchmarks/thresholds.json` (below), failing on breach and
  uploading the JSON as an artifact for trending. Keep PR CI fast: optionally
  run only the reduced smoke (frame p95 + NIF floor) with the same generous
  thresholds. Never gate PRs on tight absolute numbers from shared runners.

## Proposal (b): candidate regression thresholds

Measured on the local toolchain; thresholds carry ~2× headroom for CI-runner
variance and are **provisional until re-measured on the pinned CI toolchain**.

| Metric | Measured (median / p95) | Proposed gate | Rationale |
|---|---|---|---|
| `from_world` orbit p95 | 458 / 557 µs | **≤ 1.0 ms** | ~1.8× headroom; dashboard frame budget at 10 fps is 100 ms, so this is a regression alarm, not a UX limit |
| `metrics_and_dsp` orbit p95 | 420 / 470 µs | **≤ 0.9 ms** | JSON API path; same headroom logic |
| `metrics/2` orbit p95 | 181 / 206 µs | **≤ 0.45 ms** | CSV row cost; binds history worst case |
| NIF throughput | 9.35 M samples/s | **≥ 4.0 M samples/s** | ~2.3× margin; catches NIF build-mode regressions (debug vs release) and packing overhead |
| NIF per-render p95 (1024 sym) | 101 / 121 µs | **≤ 300 µs** | latency-side companion to the throughput floor |
| `stepped_world` 100k ticks | 13.1 ms (n=1) | **≤ 50 ms** | ~3.8× headroom for n=1 noise; keeps single-frame export responsive |
| History worst case (1000 rows) | 182 ms (n=1) | **≤ 500 ms** | ~2.7× headroom; user-facing download budget |
| `SceneStore.list/0` N=100 | 5.69 / 6.20 ms | **median ≤ 15 ms, p95 ≤ 25 ms** | ~2.6×/4× headroom for FS noise on shared runners |
| `list/0` per-scene slope | ~57 µs/scene | **≤ 150 µs/scene** | catches super-linear regressions (e.g. accidental O(N²) eviction scans on the read path) |
| Reference throughput | 1.52 M samples/s | *informational only* | fallback correctness is covered by differential tests; do not gate dev ergonomics |

After the path-recomputation fix, add: *paths contribution ≤ 15 µs per orbit
frame* (one cached call instead of three). After a `list/0` cache lands,
tighten the N=100 budget toward ≤ 2 ms.

## Deviations / things not measured

- Local OTP is **29**, not 28 as the task context assumed (Elixir 1.20.1
  matches). CI authority caveat applies throughout.
- The literal `from=0,to=100000,step=100` history request is **rejected**
  (1001 rows > 1000 cap); measured the worst valid variant `to=99900`.
- 100k stepping and history ran once (n=1); no p95 for those.
- No HTTP-level export timing (Plug pipeline, CSV encoding, network excluded);
  controller-private logic mirrored exactly instead.
- No multi-receiver (R>1) or wall-heavy scene measurements in this baseline —
  proposed as suite inputs above; the 2R+1 accounting is derived from call
  sites and single-call timings, not directly instrumented per frame.
- No memory/GC profiling; Benchee memory measurements are a suite follow-up.