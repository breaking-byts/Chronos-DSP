# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-20

### Added

- Undo/reset + Export CSV (issue #37, interactive-editing slice 5 — the final
  editing slice): an undo stack of pre-edit worlds (newest first, capped at
  50, oldest dropped beyond the cap) pushed by the shared drag/panel commit
  path in `ChronosWeb.SimLive`, covering drag commits, sliders, z, material,
  attenuation, and add/remove wall. An Undo button plus an `UndoKeys` hook
  (window Ctrl/Cmd+Z, ignored while text inputs/selects have focus) pop the
  top world back through `SimServer.update_world/2`, re-render through the
  normal `sim_frame` flow, and recompute the dirty dot; undo is geometry-only
  (the tick keeps running) and undo-only for v1 — redo is deferred. A
  `saved_world` assign keeps the restorable world behind the normalized
  dirty baseline; "Revert to saved" restores it, re-baselines (clearing undo
  + dirty), and is disabled/no-op while clean. Reset keeps reloading the
  built-in scenario; reset/load/scenario switch/save all clear the stack. An
  "Export CSV" control-bar button (next to Reset) opens a server-rendered
  menu of metrics/history/samples links to the existing
  `/api/export/{metrics,history,samples}` endpoints with the live
  scenario/seed/tx_power and current tick (history `from=0&to=100&step=1`,
  samples `limit=128`). The endpoints are scenario-based, so while the world
  is custom the menu warns that export reflects the built-in scenario, not
  the edits; noise power and sample rate are fixed by the export API and the
  menu notes this. DSP renderers untouched (parity preserved); no new
  dependencies or build steps.

- Scene save/load UI + dirty state (issue #36, interactive-editing slice 4):
  a "Scenes" panel in `ChronosWeb.SimLive` with a name input + "Save scene"
  button, a scene picker (Load/Delete per scene), an "N/100 scenes" counter,
  and the oldest-first-by-mtime eviction + ephemeral-storage note (ADR 0001).
  The server-side LiveView calls `Chronos.SceneStore` directly (same
  validation, caps, and eviction as `POST/GET /api/scenes`, no HTTP
  round-trip to itself; the JSON controllers remain the public API).
  `Chronos.World.to_scene/3` serializes a world to the scene schema (string
  keys/ids, float vec3 lists, sorted for byte-stable saves); loading reuses
  the atom-safe `SceneStore.scene_to_world/1` and replaces the session world
  through `SimServer.update_world/2`. Every save/load/delete failure
  (invalid or traversal-unsafe name, invalid/oversized scene, missing scene,
  storage error) surfaces a friendly banner instead of crashing; saving at
  the 100-scene cap reports the oldest-first eviction. A dirty dot compares
  the live world against a normalized geometry snapshot
  (`Chronos.SceneSnapshot`: positions, walls, material, attenuation, z —
  never tick/velocity noise), recomputed on drag/panel edits and cleared on
  save/load/reset/scenario switch. Loading, resetting, and switching
  scenarios also clear the new `undo_stack` assign — the hook slice #37
  populates with the ~50-entry undo history. `SceneStore.max_scenes/0`
  exposes the count cap. DSP renderers untouched (parity preserved); no new
  dependencies or build steps.

- `tx_power` channel opt (issue #33, interactive-editing slice 1): transmit
  power in dBm, integer `0..30`, default `10`. Validated uniformly by
  `Chronos.Channel.Physics.validate_opts!/1` (negatives, floats, out-of-range
  integers, and wrong types raise `ArgumentError`) and clamped API-side via
  `ChronosWeb.ApiParams`: a `tx_power` JSON-body field on `POST /api/simulate`
  and a `tx_power` query parameter on all three CSV export endpoints. Every
  path gain is scaled Elixir-side by `10 ** ((tx_power - 10) / 20)` in
  `Physics.path_gain/3` before packing, so the Rust NIF and the Elixir
  reference renderer consume identical scaled paths (parity preserved, no
  renderer changes). Received power scales by `10 ** ((tx_power - 10) / 10)`
  while the additive noise floor is unchanged. The default 10 dBm calibrates
  the existing one-metre unit-gain normalization, so default renders —
  including the golden samples CSV row — remain bit-identical; the link
  budget is a relative one, still not a full FSPL calibration.

- StreamData property tests (`test/chronos/*_property_test.exs`): packing
  round-trips (exact for float32-representable samples, float32 tolerance for
  arbitrary float64) and decoder fuzz over arbitrary bytes, geometry
  invariants (convex-polygon containment, boundary inclusion, segment
  symmetry, reflection involution), scene-bounds containment, and
  `Channel.Physics.validate_opts!/1` valid/invalid option fuzz.
- Coverage gate: ExCoveralls with a minimum of 80% total coverage
  (`coveralls.json`, `mix coveralls` in CI and `bin/test`); the NIF
  declaration module is excluded from coverage.
- Telemetry events with structured Logger-metadata logging (no JSON-formatter
  dependency): `[:chronos, :sim, :render, :start/:stop/:exception]` around
  `Chronos.Sim.render/3`, `[:chronos, :session, :start/:stop]` for
  `Chronos.SimServer` lifecycle, and `[:chronos, :api, :request, :start/:stop]`
  for `/api/*` requests via the new halt-safe `ChronosWeb.TelemetryPlug`.
  `Chronos.Telemetry.attach/0` (idempotent) is called from
  `Chronos.Application.start/2`; see the Telemetry section in
  docs/ARCHITECTURE.md.
- `Chronos.Material`: a material catalogue (brick, concrete, drywall, glass,
  metal, wood, plaster, plywood, reinforced concrete, soil, water) with
  reflection, transmission, and diffraction losses in dB. Walls now carry a
  `material` and may override the reflection loss with an explicit
  `attenuation_db`.
- `Chronos.Channel.MultiBounce`: reflection paths of first order and higher
  found with the image-source method, with per-leg occlusion checks and a
  `:max_bounces` limit (default 2).
- `Chronos.Channel.Diffraction`: ITU-R P.526-style knife-edge diffraction
  around the edges of blocking walls.
- `Chronos.Channel.Transmission`: transmission paths through blocking walls
  whose loss comes from the wall material's transmission loss.
- `Chronos.Channel.Physics`: the propagation conventions shared by the path
  models (free-space gain, dB conversion, path length, Doppler).
- `Chronos.Channel.Path`: a path struct that carries the path kind, bounce
  count, polyline, and interactions alongside the DSP fields.
- Dashboard overlays for diffraction and transmission paths, and wall labels
  showing the material and its effective reflection loss.
- `POST /api/simulate`: a stateless JSON endpoint that runs a built-in scenario
  and returns its metrics and DSP snapshot, with bounded, validated parameters
  (`tick`, `scenario`, `seed`, `sample_rate`, `noise_power`).
- Uniform JSON error rendering (`ChronosWeb.ErrorJSON`) so API 404/406/413
  responses share the `{"error": message}` shape; browsers that accept HTML
  still receive HTML error pages.
- CSV export endpoints (`GET /api/export/metrics`, `/api/export/history`,
  `/api/export/samples`): single-frame metrics, a bounded multi-tick metrics
  history (at most 1000 rows, stepped incrementally), and the first receiver's
  complex samples. CSV-only content negotiation; parameters from the query
  string.
- Named-scene store (`Chronos.SceneStore`) and JSON API (`GET/POST/DELETE
  /api/scenes`): file-backed pretty-JSON scenes with traversal-safe names,
  atomic writes, and atom-safe ids. Capped for the anonymous showcase (100
  scenes, 10 MiB total, 64 KiB/scene, 1 KiB descriptions, 256 vertices/wall)
  with oldest-first eviction and orphan cleanup; ephemeral by default (ADR 0001),
  `SCENE_DIR` for a persistent volume.
- Release smoke test (`bin/smoke`): boots a fresh build (docker image, an
  existing image, or `--local` mix release) and verifies NIF-loaded readiness
  (`/readyz` with `require_nif=true`), `/healthz`, the dashboard HTML, and
  static assets. The release workflow's `smoke` job runs it against the
  just-pushed amd64 image and gates the GitHub Release.
- Contributor documentation: `CONTRIBUTING.md` (setup, checks, PR
  expectations), GitHub issue forms (bug/feature) with `needs-triage` labels
  and a contact-links config, a pull-request template, and an expanded
  `GLOSSARY.md` (scene store, eviction, telemetry event, coverage gate,
  property test, smoke test).

### Changed

- `ChronosWeb.ApiParams` rejects query strings on mutating `/api/*` requests
  and reserved `_`-prefixed body fields on every `/api/*` route, before
  `Plug.MethodOverride` and format negotiation.
- `Chronos.SimFrame.metrics_and_dsp/2` exposes the metrics/DSP computation so
  the API reuses it without building display geometry.
- `Chronos.SimFrame.metrics/2` computes metrics without the DSP snapshot, so
  CSV export avoids the spectrum transform.
- The scenario whitelist is sourced from `Chronos.Scenario.ids/0` in both the
  simulation and export controllers instead of duplicated literals.
- CSV export errors use the uniform `{"error": message}` JSON shape, and the
  export pipeline accepts CSV only (a JSON `Accept` header returns 406).
- Scene walls carry a `Chronos.Material` id; `attenuation_db` is an explicit
  reflection override (finite, non-negative) rather than a baked loss, so
  transmission and diffraction use the wall's material.
- `SCENE_DIR` runtime wiring; DEPLOYMENT.md, fly.toml, and render.yaml document
  the ephemeral scene contract and multi-machine divergence.
- `Chronos.Channel.paths_for_rx/3` now returns line-of-sight, reflection,
  diffraction, and transmission paths, capped by `:max_paths` (default 32) with
  the strongest paths kept first. `:diffraction` and `:transmission` can be
  disabled per call.
- `Chronos.SimFrame` builds its display paths from `Chronos.Channel` instead
  of duplicating the geometry code.

### Fixed

- `Chronos.Packing.unpack_complex/1` and `unpack_paths/1` no longer crash on
  well-sized binaries containing non-finite float bit patterns (±inf, NaN):
  such payloads return `{:error, :invalid_binary}` (non-finite float terms
  are unconstructible on this OTP), matching the Rust decoder's never-crash
  behavior on arbitrary bytes.
- `Chronos.Geometry.segment_plane_intersect/4` is now symmetric in its two
  endpoints: an intersection beyond either endpoint is `:outside` (it was
  `:behind` in one direction and `:outside` in the other). Callers only
  branch on `{:ok, point, t}`, so path results are unchanged.

## [0.2.0] - 2026-10-28

### Added

- `Chronos.Scenario` with two built-in scenes:
  - `orbit`: a receiver circles a transmitter in front of two reflective walls.
  - `open_field`: the same motion in free space, for a line-of-sight baseline.
- Supervised simulation sessions: each browser connection owns a
  `Chronos.SimServer` started under `Chronos.SimSupervisor` (a
  `DynamicSupervisor` with `:temporary` children), and the session stops when
  its owner exits.
- Dashboard controls: play/pause, single step, reset, speed (0.5x/1x/2x/5x),
  noise level (off/low/medium/high), and live scenario switching.
- Canvas 2D scene renderer with device-pixel-ratio scaling, grid, scale bar,
  wall attenuation labels, and distinct LOS/reflection styling.
- Vendored ECharts (`priv/static/vendor/echarts.min.js`) for constellation,
  waveform, spectrum, and BER-history panels, including a 120-sample BER
  history that is cleared when a reset decreases the tick counter.
- Bounded metrics history helper (`Chronos.Metrics.push_history/3`).
- Readiness that reports `require_nif` and returns `503` when the NIF is
  required but not loadable.
- Native artifact validation: `Chronos.DSP.nif_loaded?/0` checks common artifact
  names and verifies the file magic (ELF, Mach-O, or PE) before attempting a
  load, so a stray dummy/foreign file cannot crash development or tests.
- Pure-Elixir reference renderer parity: the same xorshift64* RNG, tick order,
  delay interpolation, Doppler rotation, and noise scaling as the Rust NIF.
- Deployment tooling: multi-stage Docker image, Docker Compose, Fly.io
  configuration, Render blueprint, and `docs/DEPLOYMENT.md`.
- GitHub Actions: CI for Elixir and Rust on `master`, and a tag-triggered
  release workflow that publishes a multi-arch image to GHCR and creates a
  GitHub Release.
- Project documentation: rewritten README, architecture/operations/security
  notes, UI architecture note, and an updated completion roadmap.
- MIT license.

### Changed

- Replaced the PixiJS scene renderer with dependency-free Canvas 2D drawing;
  ECharts is now served from the repository instead of a CDN.
- Simplified the browser bootstrap: one `app.js` registers both LiveView hooks
  and connects the socket, and all third-party scripts are served locally.
- Dashboard layout and styling were rebuilt around the scene/telemetry
  workspace, with light/dark-friendly tokens and a compact control panel.
- `Chronos.SimFrame` frames now include viewport bounds, sorted nodes/walls,
  display paths, metrics, and a DSP snapshot; frame construction failures are
  caught in `Chronos.SimServer` and surfaced to the UI instead of crashing the
  session.
- `Chronos.Scene` derives stable bounds from nodes and wall vertices, expands
  degenerate axes, and raises a clear error for zero-span projections.
- Release configuration now requires only `SECRET_KEY_BASE` (at least 64
  bytes) in production. Signing salts are derived from it when unset,
  `CHECK_ORIGIN` defaults to the configured public origin, and
  `FORCE_SSL`/`PHX_SCHEME`/`PHX_URL_PORT`/`LOG_LEVEL` are supported. SSL with
  HSTS is the default behind a TLS-terminating proxy, and `/healthz`/`/readyz`
  are excluded from the redirect.

### Fixed

- Missing or unloadable NIFs no longer crash development/test; they log once
  and fall back to `Chronos.DSP.Reference`. Production still fails fast when
  `require_nif` is enabled.
- Simulation frame errors no longer take down the owning LiveView.
- Scene projection no longer divides by zero for single-point or axis-aligned
  worlds.
- Metrics history no longer grows without bound when a limit is supplied.

### Removed

- The PixiJS CDN dependency and the old server-rendered SVG dashboard
  prototype.

## [0.1.0] - 2026-02-04

- Initial prototype: Elixir control plane, Rust NIF data plane with Elixir
  fallback, deterministic channel paths, QPSK modem, and a first LiveView
  dashboard.
