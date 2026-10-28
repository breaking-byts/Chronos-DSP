# Deployment

Chronos-DSP ships as a single stateless container: a Phoenix release plus the
compiled Rust NIF. Simulation state lives in supervised processes inside the
BEAM and is discarded when a session or the container stops. There is no
database and no migration step.

This document is the contract for the deployment files at the repository root
(`Dockerfile`, `docker-compose.yml`, `fly.toml`, `render.yaml`). If those files
and this document disagree, treat the files as authoritative and update this
document.

## Prerequisites

- Docker 24+ with BuildKit (or Podman with a Docker-compatible CLI).
- For Fly.io: `flyctl` and a Fly account.
- For Render: a Render account and this repository connected as a Blueprint.
- A TLS-terminating edge (Fly, Render, or your own proxy) for public
  deployments.
- A `SECRET_KEY_BASE` of at least 64 bytes:

  ```bash
  mix phx.gen.secret
  # or, without Elixir installed:
  openssl rand -base64 48
  ```

The image is built from pinned `hexpm/elixir:1.19.5-erlang-28.3.3` and
`rust:1.89.0` images. `.tool-versions` pins Erlang 28.3.1 for local asdf/mise
use; the image uses 28.3.3, the closest published 28.3.x patch, which is
ABI-compatible for this project.

## Runtime configuration

`config/runtime.exs` runs on every production boot. Only one value is
genuinely required; optional settings are normalized and ignored when invalid
so a typo cannot take the node down.

| Variable | Required in prod | Default | Notes |
| --- | --- | --- | --- |
| `SECRET_KEY_BASE` | yes | — | Must be at least 64 bytes. Boot fails with an actionable message if missing or short. |
| `LIVEVIEW_SIGNING_SALT` | no | derived from `SECRET_KEY_BASE` | HMAC-SHA256-derived salt (`chronos:live_view`). Set explicitly to rotate independently. |
| `SESSION_SIGNING_SALT` | no | derived from `SECRET_KEY_BASE` | HMAC-SHA256-derived salt (`chronos:session`). Set explicitly to rotate independently. |
| `CHECK_ORIGIN` | no | derived from `PHX_HOST`/scheme/port | Comma-separated origins. Accepts `example.com` or `https://example.com`; entries without a scheme use the active scheme. Malformed entries are dropped. |
| `PHX_HOST` | no | `localhost` | Public host for URL generation. Accepts a bare host or a full URL; the path is stripped. |
| `PORT` | no | `4000` | HTTP listen port. Must be an integer 1-65535 or boot fails. |
| `PHX_SERVER` | no | `true` | Set `false`/`0` for release tasks that should not start the endpoint. |
| `FORCE_SSL` | no | `true` | When set, wins over `PHX_SCHEME`. `false`/`0` disables the redirect and HSTS (local containers). |
| `PHX_SCHEME` | no | `https` if SSL is forced, else `http` | Used only when `FORCE_SSL` is unset. Unknown values fall back. |
| `PHX_URL_PORT` | no | `443` if SSL is forced, else `PORT` | Public URL port; independent of the listen port. |
| `RUNTIME_ENV` | no | `prod` | Free-form label in health JSON; useful for staging. |
| `LOG_LEVEL` | no | `info` | `debug`, `info`, `notice`, `warning`/`warn`, `error`, or `critical`. |
| `ERLANG_ROOT` | no | Erlang root | Build-time base for Rustler include/lib paths. |
| `ERL_EI_INCLUDE_DIR` | no | `$ERLANG_ROOT/usr/include` | Build-time override for Erlang headers. |
| `ERL_EI_LIBDIR` | no | `$ERLANG_ROOT/usr/lib` | Build-time override for Erlang libraries. |

Minimal production environment:

```dotenv
SECRET_KEY_BASE=<64+ byte secret>
PHX_HOST=chronos.example.com
CHECK_ORIGIN=https://chronos.example.com
```

Explicit salts are recommended for independent rotation:

```dotenv
LIVEVIEW_SIGNING_SALT=<32+ byte random value>
SESSION_SIGNING_SALT=<32+ byte random value>
```

## Docker

Build and run locally:

```bash
docker build -t chronos-dsp:0.2.0 .

docker run --rm -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=localhost \
  -e FORCE_SSL=false \
  chronos-dsp:0.2.0
```

Then open <http://localhost:4000>. The image:

- builds the Rust NIF and the Elixir release in a builder stage;
- runs as the unprivileged `chronos` user (uid 10001) with `tini` as PID 1;
- listens on `PORT` (default `4000`);
- includes `curl` and a `HEALTHCHECK` against `http://127.0.0.1:${PORT}/healthz`.

Do not copy a host-built `priv/native/*.so` or `.dylib` into a Linux image; the
architecture and C library ABI must match.

For a production-like run, leave `FORCE_SSL` at its default and put the
container behind TLS:

```bash
docker run --rm -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=chronos.example.com \
  -e CHECK_ORIGIN=https://chronos.example.com \
  chronos-dsp:0.2.0
```

`/healthz` and `/readyz` are excluded from the SSL redirect, so plain-HTTP
probes on the internal port still work when SSL is forced.

### Docker Compose

`docker-compose.yml` builds the image and runs a single `web` service with a
development-only `SECRET_KEY_BASE` fallback:

```bash
docker compose up --build
# http://localhost:4000
```

The compose file sets `FORCE_SSL=false`, `PHX_SCHEME=http`,
`PHX_URL_PORT=4000`, and `PORT=4000`, so local plain HTTP works without a
proxy. It also sets `PHX_SERVER=true` and a `/healthz` health check. For a real
deployment, override the secret instead of relying on the fallback:

```bash
SECRET_KEY_BASE="$(openssl rand -base64 48)" docker compose up --build
```

The application is stateless; scaling out is safe only with sticky WebSocket
routing. Each browser session is pinned to one BEAM node for the life of its
LiveView, so do not run multiple nodes behind a plain round-robin load balancer.

## Fly.io

When `fly.toml` is present, a typical first deploy:

```bash
fly auth login
fly launch --no-deploy          # reuses fly.toml; review the app name/region
fly secrets set SECRET_KEY_BASE="$(openssl rand -base64 48)"
# recommended:
fly secrets set \
  LIVEVIEW_SIGNING_SALT="$(openssl rand -base64 32)" \
  SESSION_SIGNING_SALT="$(openssl rand -base64 32)"
fly deploy --remote-only
fly logs
```

Set `PHX_HOST` to the public hostname in `fly.toml` under `[env]` (preferred)
or with `fly secrets set PHX_HOST=<your-app>.fly.dev`. `PHX_SERVER` defaults to
`true`, so it does not need to be set unless you want to disable the endpoint.
Then confirm:

```bash
fly status
curl -fsS https://<your-app>.fly.dev/healthz
curl -fsS https://<your-app>.fly.dev/readyz
```

### Health checks

The checked-in `fly.toml` already probes `GET /healthz` (liveness) and
`GET /readyz` (readiness). Both paths bypass forced SSL, so Fly's plain-HTTP
internal checks work without special headers. If you probe `/` instead, it
redirects to HTTPS and the check will fail.

If the Fly check is too aggressive during first boot, increase `grace_period`.
NIF loading is fast, but a cold release boot plus scheduler startup can take a
few seconds.

## Render

Deploy with a Blueprint using `render.yaml`:

1. Push the repository to GitHub.
2. In Render, choose **New → Blueprint** and select the repository.
3. Render reads `render.yaml`, builds the Docker image, and creates the web
   service.
4. Review `PHX_HOST`: `render.yaml` fills it from the service hostname. If you
   attach a custom domain, set it explicitly (without the scheme).
5. Provide `SECRET_KEY_BASE` as a generated/synced secret. Explicit signing
   salts are optional but recommended. `CHECK_ORIGIN` is optional because the
   runtime derives it from `PHX_HOST`, but set it if the browser origin differs
   from the service hostname.
6. The checked-in `render.yaml` probes `/healthz`. Switch `healthCheckPath` to
   `/readyz` if you want Render to withhold traffic until the NIF is loadable.

Render terminates TLS and forwards the original protocol, so forced SSL does
not affect its probes.

## Health and readiness

Both endpoints return JSON with `app`, `version`, `build_env`, `runtime_env`,
`nif_loaded`, `timestamp`, and `uptime_s`.

| Endpoint | Status | Behavior |
| --- | --- | --- |
| `GET /healthz` | always `200` | Process is alive. `status: "ok"`, `ready: true`. Does not check the NIF. |
| `GET /readyz` | `200` or `503` | `200` with `status: "ready"` when ready; `503` with `status: "not_ready"` when `require_nif` is true and the NIF is not loadable. Includes `require_nif`. |

Use `/healthz` for liveness and `/readyz` for readiness. In production
`require_nif` is `true`, so `/readyz` is the meaningful gate. Both paths are
excluded from the forced-SSL redirect.

## SSL and origin behavior

- Production defaults to `FORCE_SSL=true`:
  `force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true, exclude: [paths: ["/healthz", "/readyz"]]]`.
- `FORCE_SSL=false` or `PHX_SCHEME=http` disables the redirect. Use this only
  for local containers or when TLS is terminated by something that rewrites
  the scheme incorrectly.
- `CHECK_ORIGIN` is a comma-separated allowlist. Include the scheme and port
  when non-default: `https://chronos.example.com`. Entries without a scheme
  inherit the active scheme.
- `CHECK_ORIGIN` is checked by Phoenix LiveView for browser WebSocket
  connections. A wrong value produces a connect-time rejection, not a 404.
- `PHX_HOST` drives generated URLs (`scheme://<PHX_HOST>:<PHX_URL_PORT>`). Keep
  it on the same public hostname as the browser origin.
- TLS is expected at the edge. Forward `X-Forwarded-Proto: https` from the
  proxy so `Plug.SSL` sees the original scheme.

## Troubleshooting

### The NIF does not load

Symptoms: the dashboard badge says `Reference fallback`, logs contain
`Chronos DSP NIF unavailable`, and `/readyz` returns `503` in production.

Check:

```bash
# Inside the container or release
ls -l "$(dirname "$(readlink -f "$(which beam.smp)")")/../lib/chronos-*/priv/native/"
file "$(...)/priv/native/chronos_dsp.so"
```

- The file must be a native shared object for the container architecture
  (`ELF 64-bit LSB shared object, x86-64` or `ARM aarch64`).
- `Chronos.DSP.nif_loaded?/0` validates the first four bytes; a text file,
  truncated download, or `.dylib` copied from macOS is rejected.
- Rebuild the image; Rustler compiles the crate during `mix compile`. A release
  assembled without `cargo` on `PATH` silently lacks the artifact.
- If Rustler cannot find Erlang headers, set `ERL_EI_INCLUDE_DIR` and
  `ERL_EI_LIBDIR` to the Erlang `usr/include` and `usr/lib` directories used by
  the build stage.
- Production intentionally fails fast: `require_nif` is true and
  `render_rx_block/5` raises rather than returning reference output. Fix the
  artifact; do not disable the requirement in production.

### `exec format error` or wrong architecture

The image was built for a different CPU or a host artifact was copied into the
image. Build with BuildKit for the target platform, or let the release workflow
build `linux/amd64` and `linux/arm64`:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t chronos-dsp:test .
```

On Apple Silicon, `docker build` for `linux/amd64` works under emulation but is
slow; native `linux/arm64` is faster.

### The container exits at boot with a missing or short secret

`config/runtime.exs` raises when `SECRET_KEY_BASE` is absent or shorter than 64
bytes. Generate a valid value (`mix phx.gen.secret` or
`openssl rand -base64 48`), set it in the platform's secret store, and
redeploy. Restarting the same container will not help.

A bad `PORT` (non-integer or outside 1-65535) also raises at boot. Optional
values such as `FORCE_SSL`, `PHX_SCHEME`, `CHECK_ORIGIN`, and `LOG_LEVEL` are
normalized or ignored, so they do not crash the node.

### Health checks fail

- Connection refused: the endpoint is not running (`PHX_SERVER=false`), the app
  is listening on a different `PORT`, or the probe is hitting the wrong
  internal port. Confirm the app logs the endpoint port.
- `503` on `/readyz`: the NIF is missing or not loadable. Check logs and the
  artifact as above.
- `301` on `/healthz` or `/readyz`: unexpected, because both paths are excluded
  from forced SSL. If you see it, you are probably probing `/` or a custom path,
  or a proxy is rewriting the scheme. Probe the documented paths.
- Timeouts: the readiness probe may be blocked behind a slow boot; raise the
  grace period. Do not point a liveness check at `/readyz`, or a NIF problem
  will restart-loop a healthy process.

### The page loads but the canvas never updates

- Check the browser console for a failed `/live` WebSocket.
- Verify `CHECK_ORIGIN` includes the exact browser origin, including scheme.
- Ensure the proxy forwards WebSocket upgrades (`Upgrade`/`Connection`
  headers). Render and Fly do this automatically; custom nginx needs
  `proxy_set_header Upgrade $http_upgrade;`.
- If the badge says `Paused`, press **Play**.

## Rollback

The app is stateless, so rollback is a redeploy of the previous image or
release. No data migration is required.

**Docker / GHCR**

```bash
docker pull ghcr.io/breaking-byts/chronos-dsp:<previous-tag>
docker run ... ghcr.io/breaking-byts/chronos-dsp:<previous-tag>
```

**Fly.io**

```bash
fly releases
fly deploy --image ghcr.io/breaking-byts/chronos-dsp:<previous-tag>
# or, if available in your flyctl version:
fly releases rollback <version>
```

**Render**

Use **Rollback** on the service's deploy history in the dashboard, or redeploy
the previous commit. Environment variables are unchanged by a rollback.

After any rollback, verify `/healthz` and `/readyz`, and confirm the engine
badge reports `Native NIF`.

## Upgrading

1. Read `CHANGELOG.md` for breaking changes or new required variables.
2. Pull the new image tag (avoid `:latest` for production pinning).
3. Compare the environment with the table above. A missing or short
   `SECRET_KEY_BASE` causes a boot failure, not a silent degradation.
4. Deploy during a low-traffic window if sessions matter: a deploy terminates
   open LiveView sessions and their in-memory simulations.
5. Verify `/healthz`, `/readyz`, the dashboard tick counter, and the NIF badge.
6. Keep the previous image tag available until the new one has served traffic
   successfully.

Rolling back a release does not restore simulation state, because none is
persisted.
