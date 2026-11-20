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
- **Headless JSON API** (`POST /api/simulate`): run a built-in scenario without
  a browser, with bounded, validated parameters and uniform JSON errors. See
  [JSON API](#json-api).
- **CSV export** (`GET /api/export/{metrics,history,samples}`): metrics, tick
  history, and complex samples as CSV. See [CSV export](#csv-export).
- **Named-scene store** (`GET/POST/DELETE /api/scenes`): capped, ephemeral
  file-backed scenes for the anonymous showcase (ADR 0001). See
  [Named scenes](#named-scenes).
- **Quality gates**: StreamData property tests, an >=80% coverage gate,
  `:telemetry` events with structured logging, and a release smoke test
  (`bin/smoke`). See [Tests and checks](#tests-and-checks).

Physics scope: the channel covers line-of-sight, multi-order reflections
(default up to two bounces), knife-edge diffraction, wall transmission, and a
material catalogue with per-material reflection, transmission, and diffraction
losses. Diffraction is the ITU-R P.526-style single knife-edge model, not full
UTD. The material losses are illustrative rather than calibrated measurements,
and there is no frequency-selective channel, no antenna/link budget, and no 3D
height-aware rendering yet. The signal chain is QPSK over a complex baseband
block; there is no OFDM or FEC.

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

## JSON API

`POST /api/simulate` runs a built-in scenario headlessly and returns its
metrics and a DSP snapshot. Parameters come from the JSON body only — query
strings are rejected on mutating `/api/*` requests, and top-level fields
starting with `_` are reserved (this closes Phoenix's `_method`/`_format`
overrides). The body must be `application/json` and at most 8 MB.

| Field | Type | Range | Default |
| --- | --- | --- | --- |
| `tick` | integer | 0–1,000,000 | required |
| `scenario` | string | `orbit`, `open_field` | `orbit` |
| `seed` | integer | 0–4,294,967,295 | `1` |
| `sample_rate` | number | 1,000–1,000,000 | `48000` |
| `noise_power` | number | 0–1 | `0.01` |
| `tx_power` | integer | 0–30 dBm | `10` |

```bash
curl -s localhost:4000/api/simulate \
  -H 'content-type: application/json' \
  -d '{"tick": 10, "scenario": "orbit", "seed": 7}'
```

The response is `{tick, time_s, metrics, dsp}`: `metrics` carries `ber`,
`path_count`, `received_power`, and `rx_id`; `dsp` carries `constellation`
(128 `[re, im]` pairs), `waveform` (128 real samples), and `spectrum` (64
magnitudes). Errors use a uniform `{"error": message}` JSON shape for 400,
404, 406, and 413; browsers that send `Accept: text/html` still receive HTML
error pages. There is no authentication or rate limiting yet.

## CSV export

Three read-only, CSV-only endpoints (`Accept: text/csv`) export simulation
results. Parameters come from the query string; errors use the same
`{"error": message}` JSON shape as the JSON API, and a JSON `Accept` header
returns 406. There is no authentication or rate limiting yet.

| Endpoint | Returns | Key parameters |
| --- | --- | --- |
| `GET /api/export/metrics` | one metrics row | `ticks` 0–100000 (default 0), `seed`, `scenario`, `tx_power` |
| `GET /api/export/history` | one row per sampled tick | `from`/`to` 0–100000 (defaults 0/100), `step` ≥ 1 (default 1), ≤ 1000 rows, `seed`, `scenario`, `tx_power` |
| `GET /api/export/samples` | first receiver's complex samples | `ticks`, `seed`, `scenario`, `limit` 1–512 (default 128), `tx_power` |

`scenario` is `orbit` (default) or `open_field`; `seed` is 0–4294967295;
`tx_power` is an integer 0–30 dBm (default 10) that scales the rendered signal
power while the noise floor stays unchanged. Each
tick advances the scenario by 0.1 s. History steps the world incrementally from
`from`, so its cost is bounded by `to` rather than re-simulating from zero per
row. Metrics CSV columns are `tick,time_s,rx_id,path_count,received_power,ber`;
samples CSV columns are `index,re,im`.

```bash
curl -s 'localhost:4000/api/export/history?from=0&to=50&step=5&scenario=orbit' \
  -H 'accept: text/csv'
```

Scene-snapshot export and a UI export button are planned follow-ups (they pair
with the scene store and interactive-editing tracks).

## Named scenes

`GET/POST/DELETE /api/scenes` stores named scenes as JSON files (one per scene)
for the showcase. `POST` parameters come from the JSON body; the endpoint-wide
`/api/*` rules reject query strings on writes and reserved `_`-prefixed fields.
Errors use the uniform `{"error": code}` JSON shape (`invalid_name`,
`invalid_scene`, `name_taken`, `not_found`, `storage_error`).

Storage is capped and **ephemeral by design** (ADR 0001): at most 100 scenes,
10 MiB total, 64 KiB per scene, 1 KiB descriptions, 256 vertices per wall;
writing beyond a cap evicts the oldest scenes (oldest first, by modification
time). The default directory
lives inside the release, so scenes are lost on redeploy unless `SCENE_DIR`
points at a persistent volume. Any visitor may delete any scene (single-tenant
showcase, no ownership). See [DEPLOYMENT.md](docs/DEPLOYMENT.md).

```bash
curl -s localhost:4000/api/scenes -H 'content-type: application/json' \
  -d '{"name":"my_scene","nodes":[{"id":"tx1","type":"tx","pos":[0,0,0],"vel":[0,0,0]}],"walls":[]}'
```

## Tests and checks

```bash
MIX_ENV=test mix coveralls                # Elixir suite + coverage gate (>= 80%)
(cd native/chronos_dsp && cargo test)     # Rust unit tests
bin/test                                  # both of the above

mix format --check-formatted
(cd native/chronos_dsp && cargo fmt --check)
(cd native/chronos_dsp && cargo clippy --all-targets --all-features -- -D warnings)

bin/profile                               # throughput profile script
bin/smoke --local                         # release smoke test (no docker)
```

The Elixir suite has 463 tests (including 32 StreamData property tests) and the
Rust crate has 4. The Elixir suite includes channel/scenario geometry, the
material catalogue and multi-bounce/diffraction/transmission models, uniform
option validation, DSP reference and NIF parity, packing, modem, scene bounds,
frame/server/supervisor behavior, LiveView controls, the headless JSON API, CSV
export (metrics/history/samples), the capped named-scene store, and their
uniform error shapes, and health endpoints. Property tests cover packing
round-trips and binary-decoder fuzzing, geometry invariants, scene bounds, and
channel-option validation. Coverage is gated at 80% via ExCoveralls
(`coveralls.json`), enforced in CI and `bin/test`. The release smoke test
(`bin/smoke`) boots a fresh build and verifies NIF-loaded readiness, the
dashboard HTML, and static assets; the release workflow runs it against the
pushed image before creating the GitHub Release. See
[docs/OPERATIONS.md](docs/OPERATIONS.md).

Telemetry: render timing (`chronos.sim.render`), session lifecycle
(`chronos.session`), and `/api/*` request metrics (`chronos.api.request`) are
emitted as `:telemetry` events and logged through the stdlib Logger with
structured metadata (no JSON-formatter dependency). See the Telemetry section
in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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
| `SCENE_DIR` | no | `priv/scenes` inside the release | Named-scene store directory. Ephemeral by default (ADR 0001); point at a persistent volume to survive redeploys. See [Named scenes](#named-scenes). |
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
lib/chronos/              channel + path models, material catalogue, geometry,
                          world, scenarios, DSP, packing, modem, metrics,
                          export, scene store, scene projection, frames,
                          supervision, telemetry logging
lib/chronos_web/          endpoint, router, health controller, API controllers
                          (simulate/export/scenes), LiveView, layout,
                          API telemetry plug
native/chronos_dsp/       Rust crate (rustler NIF, 4 unit tests)
priv/static/              app.js (LiveView hooks), app.css, vendored ECharts
config/                   compile-time and runtime configuration
test/                     ExUnit suites for channel, DSP, geometry, modem,
                          packing, scene, frames, server, LiveView, health,
                          telemetry, JSON API, CSV export, scene store, plus
                          StreamData property tests
docs/                     architecture, deployment, operations, security,
                          ADRs, agent docs, plans
bin/                      setup, test, smoke, profile helpers
```

## Contributing

Setup, checks, and PR expectations live in [CONTRIBUTING.md](CONTRIBUTING.md).
Issues use the bug/feature forms under `.github/ISSUE_TEMPLATE/`; the triage
vocabulary is in [docs/agents/triage-labels.md](docs/agents/triage-labels.md)
and tracker conventions in
[docs/agents/issue-tracker.md](docs/agents/issue-tracker.md). Domain language
is fixed by [GLOSSARY.md](GLOSSARY.md).

## License

MIT. See [LICENSE](LICENSE).
