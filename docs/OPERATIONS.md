# Operations

## Build and test

```bash
mix deps.get
mix compile --warnings-as-errors

mix test
(cd native/chronos_dsp && cargo test)

bin/test          # Elixir + Rust suites
bin/profile       # throughput profile (scripts/profile.exs)
```

Lint/format:

```bash
mix format --check-formatted
(cd native/chronos_dsp && cargo fmt --check)
(cd native/chronos_dsp && cargo clippy --all-targets --all-features -- -D warnings)
```

The NIF is compiled by Rustler during `mix compile`; `cargo` must be on `PATH`.
`priv/native/*.so`, `*.dylib`, and `*.dll` are ignored by git and must be
produced by the build.

## Release

```bash
MIX_ENV=prod mix release
```

- `PHX_SERVER` defaults to `true` in production; set it to `false` for release
  tasks that should not start the endpoint.
- Set `SECRET_KEY_BASE` (at least 64 bytes). `LIVEVIEW_SIGNING_SALT` and
  `SESSION_SIGNING_SALT` are optional and derived from it when unset;
  `CHECK_ORIGIN` defaults to the public origin derived from `PHX_HOST`.
- Deploy the container image rather than a host-built release when possible;
  the image guarantees the NIF matches the runtime architecture.

See [DEPLOYMENT.md](DEPLOYMENT.md) for Docker, Compose, Fly.io, Render,
rollback, and troubleshooting.

## Health

- `GET /healthz`: liveness. Always `200` while the process can answer.
- `GET /readyz`: readiness. `503` when `require_nif` is true and the NIF is not
  loadable.

Both return JSON with `app`, `version`, `build_env`, `runtime_env`,
`nif_loaded`, `timestamp`, and `uptime_s`. `/readyz` also returns
`require_nif` and `ready`.

Point liveness probes at `/healthz` and readiness probes at `/readyz`. In
production, SSL is forced by default, but both health paths are excluded from
the redirect, so plain-HTTP internal probes work. Probing `/` will redirect.

## NIF operations

- `require_nif` is `true` in production and `false` in dev/test.
- In dev/test a missing or unloadable artifact logs one warning and uses
  `Chronos.DSP.Reference`; the dashboard badge shows `Reference fallback`.
- In production, DSP rendering raises if the NIF is unavailable, and `/readyz`
  reports `not_ready`. This is intentional: do not silently serve reference
  output under production load.
- Artifact validation checks file magic before loading, so an empty, truncated,
  or wrong-platform file is rejected rather than crashing the VM.

## Simulation runtime

- Each connected LiveView owns a `Chronos.SimServer` under
  `Chronos.SimSupervisor`; sessions are `:temporary` and stop when the owner
  exits.
- Tick interval is clamped to 20-2000 ms; noise power to 0.0-1.0.
- Frame build errors are logged and returned to the LiveView as an error banner;
  they do not crash the session.
- State is in-memory. A deploy, restart, or disconnect discards the simulation.

## Observability

There is no metrics backend. Current signals:

- Phoenix request logs and endpoint telemetry events.
- `Logger` warning when the DSP NIF is unavailable (once per VM).
- `Logger` error with a stacktrace when frame construction fails.
- `/healthz` and `/readyz` JSON for external probes.

`bin/profile` measures the render path; `Chronos.Runtime.status/0` supplies the
health payload.
