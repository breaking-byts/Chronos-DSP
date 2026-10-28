# UI Vertical Slice Design

> **Historical:** this document describes the February 2026 SVG prototype.
> The shipped v0.2.0 dashboard uses Canvas 2D for the scene and vendored
> ECharts for telemetry; see [../ARCHITECTURE.md](../ARCHITECTURE.md) and
> [../architecture/hybrid-ui.md](../architecture/hybrid-ui.md).

## Goal
Deliver a minimal LiveView dashboard that visualizes the monolithic simulator in 2D top-down view with deterministic metrics: path count, received power, constellation, and BER trend over time.

## Constraints
- Monolithic single-host sim with existing Elixir control plane + Rust DSP NIF.
- Prototype defaults: sample rate 48 kHz, block size 1024, deterministic seed.
- 2D top-down projection (drop Z) for v1.
- No new frontend build tooling; keep rendering in LiveView.

## UI Layout
- **Scene panel:** Inline SVG showing walls (polygons), TX/RX nodes (circles + labels), and optional line overlays for LoS/reflection paths.
- **Constellation panel:** SVG scatter of the most recent Rx block symbols.
- **Metrics panel:** Path count, received power (linear and/or dB), BER, plus a compact history plot (sparkline) for BER and power.
- **Controls:** Manual Step button; optional auto-tick toggle (off by default for test determinism).
- **Styling:** Define CSS variables for palette, use a purposeful font (e.g., Space Grotesk) and a subtle gradient background to avoid a flat layout.

## Data Flow
1. `World.step/2` advances kinematics.
2. `Channel.paths_for_rx/3` enumerates paths.
3. `Chronos.DSP.render_rx_block/5` produces Rx samples.
4. `Modem.qpsk_demodulate/1` + `Modem.ber/2` compute BER.
5. Derived metrics (received power, path count) update a fixed-length history buffer.
6. LiveView assigns update: `%{world, metrics, history}`.

## Determinism
- Read `SIM_SEED` (env/config) once and pass into all random sources.
- Keep bit stream deterministic (seeded RNG or fixed repeating pattern).
- Keep history buffer size fixed (e.g., 60 samples) for predictable rendering.

## Testing Strategy
- **Scene projection tests:** Ensure known points project to expected SVG coordinates.
- **Metrics tests:** Validate received power computation and BER determinism with fixed seed.
- **LiveView test:** Assert assigns contain expected keys and SVG contains node labels/path count.
- **End-to-end BER trend test:** Across multiple noise powers, BER should increase monotonically.

## Out of Scope
- Multi-bounce reflections, diffraction, or distributed simulation.
- High-fidelity 3D rendering or external charting libraries.
