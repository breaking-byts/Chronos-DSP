# Architecture

## Overview

Chronos-DSP is a single Elixir/Phoenix application with a Rust NIF for the
sample-level signal path. The simulator is fully three-dimensional; the default
dashboard renders a top-down XY view.

- `lib/`: control plane (world modeling, channel/path computation, simulation
  orchestration, metrics) and the Phoenix web UI.
- `native/chronos_dsp/`: Rust NIF data plane, compiled by Rustler into
  `priv/native/chronos_dsp.so` during `mix compile`.

## Module map

| Module | Responsibility |
| --- | --- |
| `Chronos.World` | Immutable-by-replacement world state: `Node` (`:tx`/`:rx`) and planar `Wall` structs, lookup, kinematic `step/2`, and `to_scene/3` serialization. |
| `Chronos.Geometry` | Vector, plane, reflection, polygon containment, and segment/polygon intersection math. |
| `Chronos.Channel` | Orchestrates the four path models (LOS, reflections, diffraction, transmission) per receiver; occlusion tests; strongest-first path cap across all transmitters; shared-option validation. |
| `Chronos.Channel.Physics` | Shared propagation conventions: free-space gain, dB conversion, transmit-power gain (`:tx_power`), path length, Doppler, finite guards, and `validate_opts!/1`. |
| `Chronos.Channel.Path` | Path struct: delay/gain/Doppler plus kind, bounce order, polyline, and interactions. |
| `Chronos.Channel.MultiBounce` | Image-source reflections over distinct-wall sequences up to `:max_bounces`, deduplicated before the cap. |
| `Chronos.Channel.Diffraction` | ITU-R P.526-style knife-edge paths around blocking-wall edges. |
| `Chronos.Channel.Transmission` | One transmission path per blocked segment, summing crossed-wall transmission losses. |
| `Chronos.Material` | Illustrative 11-material catalogue: reflection, transmission, and diffraction losses in dB. |
| `Chronos.Scenario` | Built-in `orbit` / `open_field` worlds, viewport bounds, and per-tick kinematics. |
| `Chronos.Packing` | Little-endian binary format for complex blocks (8 bytes/sample) and paths (16 bytes/path). |
| `Chronos.DSP` | NIF entry point, artifact presence/magic validation, one-time fallback warning, and fail-fast in production. |
| `Chronos.DSP.Native` | Rustler declarations: `nif_loaded/0`, `render_rx_block/5`. |
| `Chronos.DSP.Reference` | Pure-Elixir renderer with the same tick order and xorshift64* RNG as the NIF. |
| `Chronos.Sim` | Renders one complex block per receiver, packing that receiver's paths. |
| `Chronos.Modem` | QPSK modulation/demodulation and BER. |
| `Chronos.Metrics` | Mean complex power and bounded history. |
| `Chronos.Export` | Deterministic RFC 4180 CSV formatting for metrics rows and complex samples. |
| `Chronos.SceneStore` | File-backed named scenes: traversal-safe names, atomic writes, atom-safe ids, material-aware walls, capped storage with oldest-first eviction (ephemeral, ADR 0001). |
| `Chronos.Scene` | Stable XY bounds from nodes/walls and projection into pixels. |
| `Chronos.SceneEdit` | Pure server-side validation/application of drag commits (node move, wall translation, vertex move): bounds clamp, min-edge guard, z preserved. |
| `Chronos.PanelEdit` | Pure server-side validation/application of panel property edits (attenuation/Auto, z, material, add/remove wall); bounds and catalogue guards. |
| `Chronos.SceneSnapshot` | Normalized geometry snapshot (node/wall positions, material, attenuation; no `time_s`/velocities) used to compute the dirty-state indicator. |
| `Chronos.SimFrame` | JSON-safe frame (`from_world/2`); `metrics_and_dsp/2` (API) and `metrics/2` (CSV export) skip scene/display geometry; `default_tx_block/1` is the shared deterministic QPSK test block. |
| `Chronos.SimServer` | GenServer owning one session: world, tick, scenario, seed, sample rate, tick interval, noise power, transmit power; `update_world/2`/`get_world/1` for editing (keeps an initial-world baseline). Emits session lifecycle telemetry. |
| `Chronos.SimSupervisor` | `DynamicSupervisor` for per-connection sessions (`:temporary` children). |
| `Chronos.Runtime` | App version, build/runtime env, NIF status, timestamp, uptime for health JSON. |
| `Chronos.Config` | Production environment helpers: fail-closed `FORCE_SSL` resolution, scheme normalization, and port parsing for `config/runtime.exs`. |
| `Chronos.Config.UrlPort` | Optional `PHX_URL_PORT` normalizer (warns and falls back to `443` or `PORT` on invalid input). |
| `Chronos.Telemetry` | Idempotent `:telemetry` handler attachment; logs Chronos events via stdlib Logger with structured metadata (no JSON-formatter dependency). |
| `ChronosWeb.SimLive` | LiveView that starts/stops a session and pushes frames to two hooks. |
| `ChronosWeb.HealthController` | `/healthz` and `/readyz`. |
| `ChronosWeb.SimulationController` | `POST /api/simulate`: stateless JSON metrics + DSP snapshot. |
| `ChronosWeb.ExportController` | `GET /api/export/{metrics,history,samples}`: CSV-only export. |
| `ChronosWeb.SceneController` | `GET/POST/DELETE /api/scenes`: named-scene CRUD with uniform JSON errors. |
| `ChronosWeb.ApiParams` | Endpoint-wide `/api/*` request rules (query/reserved-field rejection), JSON parser, shared seed ceiling + tx-power bounds/validation + query-integer validation. |
| `ChronosWeb.TelemetryPlug` | Emits `[:chronos, :api, :request]` start/stop events (duration, method, path, status) for `/api/*` requests; halt-safe. |
| `ChronosWeb.ErrorHTML` | HTML error pages (`404`, `405`, `406`, `413`, `500`, and fallback) for browser requests. |
| `ChronosWeb.ErrorJSON` | Uniform `{"error": message}` JSON error rendering. |
| `ChronosWeb.Endpoint` / `Router` | Static asset serving, LiveView socket, browser/API pipelines. |

## Supervision tree

```text
Chronos.Supervisor (one_for_one)
├── Phoenix.PubSub (Chronos.PubSub)
├── Chronos.SimSupervisor (DynamicSupervisor, one_for_one)
│   └── Chronos.SimServer (temporary, one per connected LiveView; monitors owner)
└── ChronosWeb.Endpoint
```

`SimLive.mount/3` starts a session only for connected sockets. The session
monitors the LiveView process and stops on `:DOWN`; `SimLive.terminate/2` also
stops it explicitly. A crashed session is not restarted, because its world and
tick are UI-local state.

## Data flow

1. `SimLive` starts a `SimServer` with a scenario id, seed `7`, tick interval,
   and noise power.
2. On each tick, `SimServer.next_frame/1` calls `SimFrame.from_world/2` for the
   current world, then advances it by `tick_ms / 1000` seconds — via the
   scenario's kinematics for an unedited built-in, or `World.step/2` (linear
   velocity) once the world has been edited.
3. `SimFrame`:
   - computes display paths directly from `Channel` (LOS lines, reflection,
     diffraction, and transmission polylines);
   - builds a deterministic QPSK block, packs it, and calls `Sim.render/3`;
   - demodulates the first receiver's samples and computes BER, path count, and
     mean received power;
   - builds a DSP snapshot (128 constellation points, 128 waveform samples,
     64-bin naive DFT magnitude).
4. `Sim.render/3` asks `Channel.paths_for_rx!/3` for each receiver, packs paths,
   and calls `Chronos.DSP.render_rx_block/5`.
5. `Chronos.DSP` uses the NIF when loaded; otherwise it falls back to
   `Reference` outside production and raises when `:require_nif` is true.
6. `SimLive` assigns the frame and pushes it as the `sim_frame` event. The
   `SimCanvas` hook draws it with Canvas 2D; `DspCharts` updates ECharts and
   keeps a 120-point BER history.

## Channel model

`Chronos.Channel` composes four path models that share the conventions in
`Chronos.Channel.Physics`:

| Model | Module | Produces |
| --- | --- | --- |
| Line of sight | `Chronos.Channel` | `kind: :los` when the direct segment is clear |
| Reflections | `Chronos.Channel.MultiBounce` | `kind: :reflection`, orders 1..`:max_bounces` |
| Diffraction | `Chronos.Channel.Diffraction` | `kind: :diffraction` around a blocking wall |
| Transmission | `Chronos.Channel.Transmission` | `kind: :transmission` through a blocking wall |

- Free-space amplitude is `1 / distance`, normalized so a one-metre path has
  unit gain. The `:tx_power` opt (integer `0..30` dBm, default `10`) is the
  transmit-power term of the link budget: every path gain is multiplied by
  `10 ** ((tx_power - 10) / 20)`, and the default calibrates the one-metre
  unit-gain normalization, so default renders are unchanged. It is still not a
  fully calibrated FSPL budget (no antenna gains or wavelength term; a
  calibrated free-space reference is −40.05 dB at 1 m / 2.4 GHz).
- A wall blocks the LOS path when the segment intersects its polygon. A point
  on the polygon boundary counts as inside the polygon, so a bounce or a
  transmission that lands exactly on an edge is a hit.
- Reflections use the image-source method: mirror the transmitter across the
  walls of an ordered sequence, intersect the mirrored segment with the last
  wall, then back-track the bounce points. Every bounce point must lie inside
  its wall polygon and every leg must be clear of the other walls.
- Reflection gain is `1 / total_distance` multiplied by the linear loss of
  every wall the path touches.
- Diffraction uses an ITU-R P.526-style single knife edge: for each blocking
  wall, the edge closest to the direct line gives a Fresnel parameter, and the
  knife-edge loss is added to the wall material's diffraction loss. A finite 3D
  wall can straddle the direct line, so the obstruction height is the
  (unsigned) distance from that line to the closest edge of the wall, and the
  cheapest edge wins.
- Transmission paths exist only when the direct segment is blocked. There is one
  per blocked segment, and it accumulates the transmission loss of every wall
  it crosses exactly once.
- Walls carry a material (`Chronos.Material`) with reflection, transmission, and
  diffraction losses in dB. An explicit `attenuation_db` on a wall overrides
  the material's reflection loss only when finite and non-negative; the other
  two always come from the material. The catalogue values are illustrative,
  not calibrated measurements.
- Doppler is `dot(relative_velocity, path_direction) / wavelength`, with carrier
  frequency defaulting to 2.4 GHz and `c` to 299,792,458 m/s. The transmitter
  velocity is projected on the first leg and the receiver velocity on the last.
- `Channel.paths_for_rx/3` caps the paths it returns (`:max_paths`, default 32)
  and keeps the strongest ones first. `:diffraction` and `:transmission` can be
  switched off per call.
- **Opts note — `:tx_power`:** validated by `Physics.validate_opts!/1`
  (integer `0..30` dBm; negatives, floats, and wrong types raise
  `ArgumentError`) and applied in `Physics.path_gain/3` *before* paths are
  packed for the DSP. Both the Rust NIF and the Elixir reference renderer
  therefore consume identically scaled paths, so parity is preserved without
  touching either renderer. Received power scales by
  `10 ** ((tx_power - 10) / 10)`; the additive noise floor is unchanged. The
  default `10` dBm anchors the existing unit-gain normalization, keeping all
  golden/parity fixtures bit-identical. The API surface clamps to the same
  range through `ChronosWeb.ApiParams` (`validate_tx_power/1` for the
  `POST /api/simulate` JSON body; `parse_query_integer/5` with
  `default_tx_power/0` and `tx_power_range/0` for the export query strings).
- Still missing: a frequency-selective channel, a fully calibrated FSPL link
  budget (antenna gains and the wavelength term), and height-aware 3D
  rendering.

## DSP contract

`render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed)`:

- `tx_block`: little-endian `{f32 re, f32 im}` per sample.
- `paths_block`: little-endian `{f64 delay_s, f32 gain, f32 doppler_hz}` per
  path.
- Output: the same complex layout as `tx_block`, one output sample per input
  sample.
- The renderer linearly interpolates fractional delays, multiplies each path by
  `gain * exp(j * 2π * doppler_hz * t)`, sums paths, and adds complex Gaussian
  noise with power `noise_power` (variance split across I/Q).
- Randomness is xorshift64* with the seed XORed by `0x9E3779B97F4A7C15`; the
  Elixir reference reproduces the NIF's sequence for differential testing.

## Native artifact handling

`Chronos.DSP.nif_loaded?/0` checks for `chronos_dsp` / `libchronos_dsp` with
`.so`, `.dylib`, `.dll`, or no extension in `priv/native`, then reads the first
four bytes and accepts ELF, Mach-O (32-bit and 64-bit, both endiannesses),
universal/fat Mach-O (`CAFEBABE` / `BEBAFECA`), or PE magic. Only then does it
call `Native.nif_loaded/0`, rescuing `:nif_not_loaded` and
`UndefinedFunctionError`. Tests can force the answer with the
`:nif_loaded_override` application env.

## Web/UI

- No Node build step. `priv/static/app.js` registers `SimCanvas` and
  `DspCharts`, connects the LiveView socket, and is served as a static file.
- Phoenix, LiveView, and ECharts scripts are served from the app or vendored
  under `priv/static/vendor/`; there are no CDN dependencies.
- The scene hook uses `ResizeObserver`, caps device pixel ratio at 2.5, and
  draws on `requestAnimationFrame`. ECharts updates are coalesced per frame.
- `/healthz` and `/readyz` use the `:api` pipeline; `/` is a LiveView in the
  `:browser` pipeline with CSRF protection and secure headers.
- `POST /api/simulate` is a stateless JSON endpoint in the `:api` pipeline.
  `ChronosWeb.ApiParams` parses JSON bodies, rejects query strings on mutating
  `/api/*` requests and reserved `_`-prefixed fields, and runs before
  `Plug.MethodOverride`. The optional `tx_power` body field (integer 0..30
  dBm, default 10) is validated by `ApiParams.validate_tx_power/1` and scales
  the rendered signal power. Errors render through `ChronosWeb.ErrorJSON`
  (`{"error": message}`) with JSON as the default fallback format; HTML error
  pages are kept for browsers.
- `GET /api/export/{metrics,history,samples}` are read-only CSV endpoints in the
  `:export` pipeline (CSV-only negotiation). They reuse `SimFrame.metrics/2`
  (no DSP snapshot) and source the scenario whitelist from `Scenario.ids/0`.
  All three accept the same `tx_power` query parameter (integer 0..30 dBm,
  default 10) via `ApiParams.parse_query_integer/5`.
  History steps the world incrementally and caps output at 1000 rows; errors
  share the uniform JSON shape.
- Production defaults to forced SSL with HSTS
  (`FORCE_SSL=true`/`PHX_SCHEME=https`). `/healthz` and `/readyz` are excluded
  from the redirect so internal probes work; `FORCE_SSL=false` is available for
  local containers. See [DEPLOYMENT.md](DEPLOYMENT.md).

## Telemetry

Chronos emits `:telemetry` events and logs them through the stdlib `Logger`
with structured metadata. **Design decision:** no JSON-formatter dependency is
added; metadata (`event`, `duration_ms`, `route`, `status`, scenario/session
ids, render options) rides on ordinary Logger events, so any formatter or
backend can consume it. A JSON formatter can be layered on later without
changing the event contract.

| Event | Emitter | Measurements | Metadata |
| --- | --- | --- | --- |
| `[:chronos, :sim, :render, :start]` | `Chronos.Sim.render/3` (`:telemetry.span`) | `system_time` | `receiver_count`, `sample_rate`, `seed` |
| `[:chronos, :sim, :render, :stop]` | same span | `duration` (native time) | start metadata + `noise_power` |
| `[:chronos, :sim, :render, :exception]` | same span, on raise | span exception measurements | start metadata + `kind`, `reason`, `stacktrace` |
| `[:chronos, :session, :start]` | `Chronos.SimServer.init/1` | `system_time` | `scenario`, `session` (pid), `custom_world` |
| `[:chronos, :session, :stop]` | `Chronos.SimServer.terminate/2` | `system_time`, `duration` | `scenario`, `session` (pid) |
| `[:chronos, :api, :request, :start]` | `ChronosWeb.TelemetryPlug` | `system_time` | `method`, `path` |
| `[:chronos, :api, :request, :stop]` | same plug, `register_before_send` | `duration` (native time) | `method`, `path`, `status` |

- `Chronos.Telemetry.attach/0` is called from `Chronos.Application.start/2`.
  It is idempotent (detaches any previous handler with the same id first) and
  logs `:stop` events at `info`, everything else at `debug`.
- The API plug sits after `Plug.Telemetry` and before the router, and only
  emits for `/api/*` paths. A mid-pipeline plug cannot wrap downstream plugs
  in `:telemetry.span/3`, so it emits the equivalent start/stop events
  directly; `register_before_send` also runs for halted conns, so error
  responses still produce a stop event with their status.
- Durations are native-time integers; the logging handler converts them to
  `duration_ms` for readability.

## Known limitations

- Reflections are distinct-wall sequences up to `:max_bounces` (default 2);
  there are no repeated-wall bounces and no full UTD diffraction (knife-edge
  only). The built-in scenarios use one transmitter and one receiver, though
  `World` and `Channel` support multiple nodes.
- The page renders a height-aware top-down projection: Z affects geometry, path
  delays, and node/wall height cues, but the layout stays planar (ADR 0002).
- The physics-depth roadmap is locked in
  [design/physics-depth.md](design/physics-depth.md) (ADR 0003) and lands in
  slices #61–#65; this page describes the code as it exists on `master`.
- Per-connection live sessions are in-memory only. Named scenes persist as
  ephemeral files (capped, lost on redeploy without a `SCENE_DIR` volume); there
  is no authentication or multi-user collaboration.
- CSV export is CPU-bound and anonymous, with no rate limiting yet. Metrics and
  samples re-simulate from t=0 per request (the orbit kinematics are not
  expressible as one big step without changing the floating-point trajectory);
  samples renders all receivers and keeps the first. History steps incrementally
  and caps output at 1000 rows, but a worst-case range (`to=100000`, `step=100`)
  still does ~100k steps plus 1000 render passes. Bounds: ticks 0..100000,
  history rows ≤ 1000, samples limit 1..512. Caching stepped worlds and
  first-receiver-only rendering are performance-track candidates (see #25).
