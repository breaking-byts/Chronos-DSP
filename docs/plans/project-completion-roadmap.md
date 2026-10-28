# Chronos-DSP Completion Roadmap

Status after v0.2.0 (2026-10-28): the simulator is a working, deployable
single-node demo. The control plane, Rust NIF, Elixir reference, LiveView
dashboard, CI, release workflow, container/deploy configuration, and docs are in
place. The remaining work is correctness hardening and product depth, not
scaffolding.

## Where it stands

- Elixir control plane: `World`, `Geometry`, `Channel`, `Scenario`, `Sim`,
  `SimFrame`, `SimServer`, `SimSupervisor`, `Scene`, `Metrics`, `Runtime`.
- Rust NIF data plane with a pure-Elixir reference that mirrors its RNG and
  sample order.
- Live dashboard: Canvas 2D scene, vendored ECharts telemetry, play/pause/step/
  reset, speed, noise, and `orbit` / `open_field` scenarios.
- Per-connection supervised sessions, bounded tick/noise inputs, frame-error
  isolation, artifact magic validation, health/readiness endpoints.
- CI for Elixir and Rust, tag-triggered multi-arch GHCR release, Docker,
  Compose, Fly.io, Render, and deployment docs.
- MIT license.
- Test inventory: 120 Elixir tests, 2 Rust tests, all passing. Coverage includes
  channel/scenario geometry, DSP reference/NIF parity, packing, modem, scene
  bounds, frame/server/supervisor behavior, LiveView controls, and health
  endpoints.

## Completed in v0.2.0

- [x] Add CI for `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix test`, and Rust `fmt`/`clippy`/`test`.
- [x] Add release tooling: Dockerfile, Compose, Fly.io, Render, GHCR workflow,
  GitHub Release generation.
- [x] Add `@moduledoc`/`@doc` coverage for the public modules touched in this
  release.
- [x] Add a differential NIF/reference design: same xorshift64* RNG, delay
  interpolation, Doppler rotation, and noise scaling.
- [x] Add differential tests comparing NIF and reference output across seeds
  and noise powers, plus a fallback-equivalence test.
- [x] Replace PixiJS/CDN assets with Canvas 2D and vendored ECharts.
- [x] Add scenario switching, speed/noise controls, and supervised sessions.
- [x] Bound metrics history and BER history.
- [x] Validate NIF artifacts before load; fall back outside production and fail
  fast in production.
- [x] Add health/readiness JSON and deployment documentation.
- [x] Add MIT license and changelog.

## Immediate follow-ups (v0.2.x)

1. **Keep CI green.** The suite is green locally; verify the GitHub Actions
   matrix (Erlang 28.3.1/Elixir 1.19.5 and Rust 1.89) matches the release image
   and stays green on `master`.
2. **Pin and verify the Rust toolchain.** `.tool-versions` is the source of
   truth for asdf/mise; keep it on a version that can read the v4 Cargo
   lockfile, and keep `cargo test`/`clippy` in the release gate.
3. **Add property tests.** StreamData round-trips for `Packing`, geometry
   invariants, and scene bounds; fuzz the Rust binary decoders.
4. **Document the deployment files as the contract.** Keep
   `docs/DEPLOYMENT.md` aligned with `Dockerfile`, `docker-compose.yml`,
   `fly.toml`, and `render.yaml` whenever those change.
5. **Add a release smoke test.** Boot the built image, wait for `/readyz`, and
   fetch `/` to catch missing assets or a NIF that failed to load.

## Physics depth (next major value)

1. Multi-wall / higher-order reflections (2nd and 3rd order) with a path cap.
2. Diffraction (UTD) around wall edges and a penetration-loss model.
3. Frequency-selective channel: per-path delay spread and a tapped delay line.
4. Material library (concrete, glass, drywall) with attenuation coefficients.
5. Calibrated link budget: antenna gains, transmit power, wavelength term, and
   a comparison against a simple ray-tracing reference.
6. Optional 3D/height-aware rendering instead of the current XY projection.

## Performance and scale

1. Profile the NIF hot path (`bin/profile`) and consider SIMD for the inner
   sample/path loop.
2. Batch multi-receiver rendering and reuse shared path computations.
3. Replace per-frame binary packing with direct term passing where Rustler
   supports it, or reuse binaries.
4. Add a benchmark suite with regression thresholds in CI.
5. Decide whether large scenes need GPU/offload; not required for the demo.

## Product/API

1. Headless REST or JSON API: submit a world, receive samples/metrics.
2. Export metrics history, scene snapshots, and receiver samples.
3. Interactive placement of TX/RX/walls and parameter sliders.
4. Persistence: save/load scenes, named scenarios, seed management.
5. Authentication and multi-user sessions only if hosted publicly; otherwise
   keep the local-first single-tenant model.
6. Consider WebSocket streaming for non-LiveView clients.

## Quality and operations

1. Coverage target (≥80% on the control plane) and a coverage gate.
2. Structured logging and telemetry for render timing and session lifecycle.
3. Load test with many concurrent LiveViews; document connection limits.
4. Add a staging deployment using the same image with `RUNTIME_ENV=staging`.
5. Add issue/PR templates and a contribution guide.

## Decision points

- Hosted demo vs local-first tool? (affects auth, persistence, rate limits)
- Accuracy-first (calibrated ray tracing) vs teaching-first (visual clarity)?
- Keep the Rust core MIT, or split a separately licensed engine?
- Is real-time audio/RF output a goal, or is batch simulation enough?

## Sequencing

1. v0.2.x: CI verification, toolchain pin, property tests, release smoke test,
   docs alignment.
2. v0.3: multi-bounce/diffraction behind a path cap, plus benchmarks.
3. v0.4: API/export and persistence if the product direction requires them.
