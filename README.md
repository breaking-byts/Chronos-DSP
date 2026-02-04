# Chronos-DSP

Monolithic, real-time wireless propagation simulator (prototype scaffold).

## Layout

- `lib/` Elixir control-plane and geometry
- `native/chronos_dsp/` Rust NIF data-plane
- `test/` ExUnit tests

## Setup

- Install toolchain via `mise` or `asdf`, then run `bin/setup`
- Run tests with `bin/test`
- Start UI with `mix phx.server` and visit `http://localhost:4000`
- Quick perf check with `bin/profile`

## Prototype Defaults

- Sample rate: 48 kHz
- Block size: 1024 samples
- 3D walls as planar polygons

## Next Steps

- Add multi-wall reflection + diffraction models
- Profile NIF hot paths and SIMD-ize
- Expand UI with plots (constellation, BER over time)
