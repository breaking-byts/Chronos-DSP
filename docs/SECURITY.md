# Security

## Secrets and salts

Do not hardcode credentials or cryptographic material in tracked files.

Required in production:

- `SECRET_KEY_BASE`, at least 64 bytes. `config/runtime.exs` refuses to boot
  without it.

Optional but recommended for independent rotation:

- `LIVEVIEW_SIGNING_SALT`
- `SESSION_SIGNING_SALT`

When unset, both salts are derived from `SECRET_KEY_BASE` with HMAC-SHA256 and
app-specific labels. Rotating `SECRET_KEY_BASE` therefore rotates them too.
Generate independent values where possible; do not reuse development salts.
`CHECK_ORIGIN` is optional and defaults to the public origin derived from
`PHX_HOST`, scheme, and URL port. See [DEPLOYMENT.md](DEPLOYMENT.md) for
generation commands and per-platform secret storage. `.env` files are for local
Compose use only and must not be committed.

## Origin and transport controls

- `CHECK_ORIGIN` is a comma-separated allowlist of browser origins (scheme +
  host + optional port). It is enforced by LiveView for WebSocket connections.
  When unset, the public origin is derived from `PHX_HOST`, scheme, and URL
  port.
- `force_ssl` is enabled by default in production with HSTS and
  `rewrite_on: [:x_forwarded_proto]`. `FORCE_SSL=false` (or
  `PHX_SCHEME=http`) disables it and should only be used for local containers.
  `/healthz` and `/readyz` are excluded from the redirect.
- TLS termination is expected at the edge proxy or load balancer. Forward
  `X-Forwarded-Proto: https`, `X-Forwarded-For`, and `X-Forwarded-Host`
  correctly; do not expose the container's HTTP port directly to the internet.
- The browser pipeline enables CSRF protection, secure browser headers, and
  signed cookie sessions.
- There is no user authentication or authorization. Treat a deployment as a
  single-tenant, trusted-user demo; do not place sensitive data in scenarios or
  URLs.

## Native artifact policy

- Native binaries (`.so`, `.dylib`, `.dll`) are not committed; `.gitignore`
  excludes `priv/native/*`.
- Artifacts are built in CI/release pipelines to preserve reproducibility and
  traceability, and the runtime validates file magic before loading.
- Production requires the NIF (`require_nif: true`). A missing artifact fails
  readiness and raises on DSP calls instead of silently using the slower
  reference implementation.
- `dtolnay/rust-toolchain` and the Elixir/OTP versions are pinned so build
  inputs are reproducible. Dependency integrity is anchored by `mix.lock` and
  `Cargo.lock`.

## Input and resource limits

- The dashboard only accepts fixed control values: known scenario ids, four
  speed values, and four noise levels. Unknown values are ignored in
  `ChronosWeb.SimLive`.
- `Chronos.SimServer` clamps tick interval (20-2000 ms) and noise power
  (0.0-1.0) even when called outside the UI.
- Binary payloads are length-checked by `Chronos.Packing` and the NIF
  (`BadArg` on malformed complex/path blocks).
- Each browser can start one session per connected LiveView. There is no
  global admission control; if you expose the app publicly, add a reverse-proxy
  connection/rate limit.

## Reporting

Open a private security advisory on
<https://github.com/breaking-byts/Chronos-DSP/security/advisories> or contact
the maintainers before filing a public issue for a vulnerability.
