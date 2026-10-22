# Chronos-DSP

Monolithic, real-time wireless propagation simulator with an Elixir control-plane and Rust NIF data-plane.

## Layout

- `lib/` Elixir control-plane and geometry
- `native/chronos_dsp/` Rust NIF data-plane
- `test/` ExUnit tests
- LiveView dashboard panels: scene, constellation, BER/power history

## Setup

- Install toolchain via `mise` or `asdf`, then run `bin/setup`
- Run tests with `bin/test`
- Start UI with `mix phx.server` and visit `http://localhost:4000`
- Quick perf check with `bin/profile`

## Runtime Environment Variables

- `SECRET_KEY_BASE`: endpoint secret key base
- `LIVEVIEW_SIGNING_SALT`: signing salt for LiveView
- `SESSION_SIGNING_SALT`: signing salt for cookie sessions
- `PORT`: HTTP port (default `4000`)
- `PHX_HOST`: public host for URL generation
- `PHX_SERVER`: set to `true`/`1` to start endpoint in release
- `CHECK_ORIGIN`: comma-separated origin allowlist (required in prod)
- `RUNTIME_ENV`: runtime environment label for health payloads (optional)
- `ERL_EI_INCLUDE_DIR`: optional override for Rustler include path
- `ERL_EI_LIBDIR`: optional override for Rustler lib path

See `.env.example` for a concrete template.

## Health Endpoints

- `GET /healthz`: liveness endpoint
- `GET /readyz`: readiness endpoint (fails when NIF is required but unavailable)

Both endpoints return JSON with version, env metadata, NIF status, timestamp, and uptime.

## Releases

- Build release: `MIX_ENV=prod mix release`
- Ensure Rust toolchain is available in CI/build environment so `native/chronos_dsp` compiles.
- Native binaries are not tracked in git and must be produced during build/release.

## Prototype Defaults

- Sample rate: 48 kHz
- Block size: 1024 samples
- 3D walls as planar polygons

## Next Steps

- Add multi-wall reflection + diffraction models
- Profile NIF hot paths and SIMD-ize
- Expand UI with plots (constellation, BER over time)
