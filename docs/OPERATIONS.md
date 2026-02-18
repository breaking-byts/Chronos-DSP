# Operations

## Build and Test

- Elixir tests: `mix test`
- Coverage: `mix test --cover`
- Rust tests: `cd native/chronos_dsp && cargo test`
- Rust lint: `cd native/chronos_dsp && cargo clippy --all-targets --all-features -- -D warnings`
- Format checks:
  - `mix format --check-formatted`
  - `cd native/chronos_dsp && cargo fmt --check`

## Release

- Build: `MIX_ENV=prod mix release`
- Start endpoint in release by setting `PHX_SERVER=true`.
- Provide all required runtime variables (see `.env.example`).

## Health

- `GET /healthz`: process is alive.
- `GET /readyz`: process is ready to serve traffic.

Readiness checks include NIF availability when `require_nif` is enabled (default in prod).

## NIF Requirement

- `require_nif` is `true` in production and `false` in dev/test.
- If NIF is required and unavailable, DSP rendering raises and readiness reports not ready.
