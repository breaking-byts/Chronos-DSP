# Architecture

## Overview

Chronos-DSP is split into two layers:

- `lib/`: Elixir control-plane for world modeling, channel/path computation, simulation orchestration, and web UI.
- `native/chronos_dsp/`: Rust NIF data-plane for sample-level DSP rendering.

## Module Map

- `Chronos.World`: world state, nodes, walls, and kinematic stepping.
- `Chronos.Geometry`: vector/plane/polygon math used by channel computations.
- `Chronos.Channel`: LOS/reflection path derivation between TX and RX nodes.
- `Chronos.Packing`: binary packing/unpacking between Elixir and NIF.
- `Chronos.DSP`: NIF wrapper with controlled fallback behavior.
- `Chronos.Sim`: per-RX block rendering orchestration.
- `ChronosWeb.*`: Phoenix endpoint/router/live view and health/readiness HTTP endpoints.

## Data Flow

1. UI or caller creates/updates a `Chronos.World`.
2. `Chronos.Sim.render/3` computes channel paths per RX via `Chronos.Channel`.
3. Paths and TX symbols are packed into binaries with `Chronos.Packing`.
4. `Chronos.DSP.render_rx_block/5` invokes Rust NIF (or reference fallback in non-prod).
5. RX sample blocks are returned to callers and optionally demodulated in UI metrics.
