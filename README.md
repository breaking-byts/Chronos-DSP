# Chronos-DSP

[![CI](https://github.com/breaking-byts/Chronos-DSP/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/breaking-byts/Chronos-DSP/actions/workflows/ci.yml)

Real-time wireless propagation simulator with an Elixir/Phoenix control plane
and a Rust NIF DSP data plane.

Chronos-DSP models a small 3D scene (transmitters, receivers, planar walls),
derives multipath channel paths, and renders complex baseband samples for each
receiver. A supervised LiveView dashboard drives the simulation in the browser;
all signal processing runs on the server, using the Rust NIF when available and
a deterministic pure-Elixir reference implementation otherwise.

## Features

- **Deterministic geometric channel** (`Chronos.Channel`): line-of-sight,
  specular reflections off planar wall polygons (first order and higher, via
  the image-source method), knife-edge diffraction around blocking walls,
  transmission through walls, wall occlusion, `1/r` free-space amplitude
  normalized at one metre, material-driven attenuation in dB, and Doppler from
  relative velocity projected onto each path. Path count is capped so a busy
  scene stays bounded.
- **QPSK DSP** (`Chronos.Modem`, `Chronos.DSP`): QPSK modulation/demodulation,
  fractional-delay interpolation, Doppler phase rotation, complex AWGN,
  received power, and BER. Noise uses an explicit xorshift64* seed, so runs are
  reproducible.
- **Rust NIF with a real fallback** (`native/chronos_dsp`,
  `Chronos.DSP.Reference`): `render_rx_block/5` runs on a dirty CPU scheduler.
  The Elixir reference mirrors the NIF's sample order, interpolation, rotation,
  and RNG. The NIF is required in production and optional in dev/test; artifact
  magic is checked before loading so a missing or foreign binary degrades
  cleanly instead of crashing.
- **Live dashboard** (`ChronosWeb.SimLive`): top-down Canvas 2D scene with LOS,
  reflection, diffraction, and transmission overlays, plus vendored ECharts
  panels for constellation, waveform, spectrum, and BER history. No PixiJS, no
  CDN, no frontend build step.
- **Controls**: play/pause, single step, reset, speed (0.5x/1x/2x/5x), noise
  (off/low/medium/high), and scenario switching (`orbit`, `open_field`).
- **Supervised sessions**: every browser connection owns a `Chronos.SimServer`
  under `Chronos.SimSupervisor`; sessions are `:temporary`, monitor their owner,
  clamp tick interval to 20-2000 ms and noise power to 0.0-1.0, and stop on
  disconnect.
- **Operational endpoints**: JSON liveness (`/healthz`) and readiness
  (`/readyz`), the latter failing with `503` when the NIF is required but not
  loadable.

Physics scope: the channel covers line-of-sight, multi-order reflections
(default up to two bounces), knife-edge diffraction, wall transmission, and a
material catalogue with per-material reflection, transmission, and diffraction
losses. The losses are illustrative rather than calibrated, and there is no
frequency-selective channel, no antenna/link budget, and no 3D height-aware
rendering yet. The signal chain is QPSK over a complex baseband block; there is
no OFDM or FEC.

## Architecture

```text
Browser
  LiveView events (toggle / step / reset / speed / noise / scenario)
  Canvas 2D scene  +  ECharts telemetry
          │
          ▼
ChronosWeb.SimLive ──owns──► Chronos.SimSupervisor (DynamicSupervisor)
          │                        └── Chronos.SimServer (one per session)
          │                               ├── Chronos.Scenario (orbit | open_field)
          │                               ├── Chronos.SimFrame
          │                               │     ├── Chronos.Channel + Geometry (paths)
          │                               │     └── Chronos.Sim
          │                               │           ├── Chronos.DSP (Rust NIF)
          │                               │           └── Chronos.DSP.Reference
          │                               └── tick / seed / noise / bounds
          ▼
Phoenix endpoint
  GET /healthz   GET /readyz   GET / (LiveView)
```

The Rust NIF is compiled and copied into `priv/native/` by Rustler during
`mix compile`; `cargo` must be on `PATH`.

## Quickstart

Requirements:

- Erlang/OTP 28.3.1 and Elixir 1.19.5-otp-28 (see `.tool-versions`; the project
  declares `elixir: "~> 1.15"`).
- Rust 1.89+ (the crate uses the 2021 edition and a Cargo lockfile v4).
- [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/).

```bash
git clone https://github.com/breaking-byts/Chronos-DSP.git
cd Chronos-DSP
asdf install        # or: mise install
bin/setup           # deps + native debug build
mix phx.server
```

Open <http://localhost:4000>. The dashboard connects, starts an `orbit` session,
and begins ticking. The engine badge shows `Native NIF` or `Reference fallback`
depending on whether the artifact loaded.

If you only want Elixir dependencies:

```bash
mix deps.get
mix compile        # Rustler builds the NIF here
mix phx.server
```

## Tests and checks

```bash
mix test                                  # Elixir test suite
(cd native/chronos_dsp && cargo test)     # Rust unit tests
bin/test                                  # both of the above

mix format --check-formatted
(cd native/chronos_dsp && cargo fmt --check)
(cd native/chronos_dsp && cargo clippy --all-targets --all-features -- -D warnings)

bin/profile                               # throughput profile script
```

The Elixir suite has 120 tests and the Rust crate has 2. The Elixir suite
includes channel/scenario geometry, DSP reference and NIF parity, packing,
modem, scene bounds, frame/server/supervisor behavior, LiveView controls, and
health endpoints.

## Docker

The release image is a multi-stage build: Rust compiles the NIF, Elixir builds
the release, and the runtime image contains only the release plus the native
artifact. The container listens on `PORT` (default `4000`).

```bash
docker build -t chronos-dsp .

docker run --rm -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=localhost \
  -e FORCE_SSL=false \
  chronos-dsp
```

`SECRET_KEY_BASE` must be at least 64 bytes and is the only required secret;
the signing salts are derived from it when unset. Production defaults to
forced SSL with HSTS (`FORCE_SSL=true`), so put a real deployment behind a
TLS-terminating proxy. `/healthz` and `/readyz` are excluded from the redirect,
which keeps container and platform probes working. Full instructions, Compose,
Fly.io, Render, environment variables, and troubleshooting are in
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

Published images: `ghcr.io/breaking-byts/chronos-dsp:<tag>` and `:latest`.

## Environment variables

Production (`MIX_ENV=prod`) reads these at boot in `config/runtime.exs`.

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `SECRET_KEY_BASE` | yes (prod) | — | Phoenix endpoint secret, minimum 64 bytes. Boot fails if missing or shorter. |
| `LIVEVIEW_SIGNING_SALT` | no | derived from `SECRET_KEY_BASE` | LiveView token signing salt. Set explicitly to rotate it independently. |
| `SESSION_SIGNING_SALT` | no | derived from `SECRET_KEY_BASE` | Cookie session signing salt. |
| `CHECK_ORIGIN` | no | derived from `PHX_HOST`/scheme/port | Comma-separated browser origins allowed for LiveView/WebSocket. Malformed entries are ignored. |
| `PHX_HOST` | no | `localhost` | Public host for URL generation. Accepts a bare host or URL. |
| `PORT` | no | `4000` | HTTP listen port. |
| `PHX_SERVER` | no | `true` in prod | Set `false`/`0` to skip starting the endpoint (release tasks). |
| `FORCE_SSL` | no | `true` in prod | Forces HTTPS/HSTS. Set `false` for plain-HTTP local containers. |
| `PHX_SCHEME` | no | `https` when `FORCE_SSL`, else `http` | Used when `FORCE_SSL` is unset. |
| `PHX_URL_PORT` | no | `443` when forced SSL, else `PORT` | Public URL port (not the listen port). |
| `RUNTIME_ENV` | no | `prod` | Label returned by the health endpoints. |
| `LOG_LEVEL` | no | `info` | `debug`, `info`, `notice`, `warning`, `error`, or `critical`. |
| `ERLANG_ROOT` | no | Erlang root | Base for Rustler include/lib paths at build time. |
| `ERL_EI_INCLUDE_DIR` | no | `$ERLANG_ROOT/usr/include` | Override Rustler `erl_nif.h` include path. |
| `ERL_EI_LIBDIR` | no | `$ERLANG_ROOT/usr/lib` | Override Rustler link path. |

In dev/test the endpoint uses `http://127.0.0.1:4000` (test: `4001`), does not
force SSL, and does not require secrets.

## Scenarios

| Id | Name | What it exercises |
| --- | --- | --- |
| `orbit` (default) | Orbit + corner walls | Receiver circles a transmitter in front of two walls; LOS, reflections, path loss, and Doppler all change each tick. |
| `open_field` | Open field | Same orbit without walls; clean line-of-sight baseline. |

## Project layout

```text
lib/chronos/              channel, geometry, world, scenarios, DSP, packing,
                          modem, metrics, scene projection, frames, supervision
lib/chronos_web/          endpoint, router, health controller, LiveView, layout
native/chronos_dsp/       Rust crate (rustler NIF, 2 unit tests)
priv/static/              app.js (LiveView hooks), app.css, vendored ECharts
config/                   compile-time and runtime configuration
test/                     ExUnit suites for channel, DSP, geometry, modem,
                          packing, scene, frames, server, LiveView, health
docs/                     architecture, deployment, operations, security, plans
bin/                      setup, test, profile helpers
```

## License

MIT. See [LICENSE](LICENSE).
