# Chronos-DSP

Monolithic, real-time wireless propagation simulator (prototype scaffold).

## Layout

- `lib/` Elixir control-plane and geometry
- `native/chronos_dsp/` Rust NIF data-plane
- `test/` ExUnit tests

## Setup

- Install toolchain via `mise` or `asdf`, then run `bin/setup`
- Run tests with `bin/test`

## Prototype Defaults

- Sample rate: 48 kHz
- Block size: 1024 samples
- 3D walls as planar polygons

## Next Steps

- Implement wall polygons and path enumeration
- Define DSP path format for Rust NIF
- Add BER integration tests
