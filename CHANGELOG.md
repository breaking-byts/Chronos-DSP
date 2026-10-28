# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
- `Chronos.Channel.Transmission`: wall penetration paths whose loss comes from
  the wall material's transmission loss.
- `Chronos.Channel.Physics`: the propagation conventions shared by the path
  models (free-space gain, dB conversion, path length, Doppler).
- `Chronos.Channel.Path`: a path struct that carries the path kind, bounce
  count, polyline, and interactions alongside the DSP fields.
- Dashboard overlays for diffraction and transmission paths, and wall labels
  showing the material and its effective reflection loss.

### Changed

- `Chronos.Channel.paths_for_rx/3` now returns line-of-sight, reflection,
  diffraction, and transmission paths, capped by `:max_paths` (default 32) with
  the strongest paths kept first. `:diffraction` and `:transmission` can be
  disabled per call.
- `Chronos.SimFrame` builds its display paths from `Chronos.Channel` instead
  of duplicating the geometry code.

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
