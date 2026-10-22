# Security

## Secrets and Salts

Do not hardcode credentials or cryptographic material in tracked files.

Required in production:

- `SECRET_KEY_BASE`
- `LIVEVIEW_SIGNING_SALT`
- `SESSION_SIGNING_SALT`

These values are loaded from `config/runtime.exs`.

## Origin and Transport Controls

- `CHECK_ORIGIN` is required in production and defines the allowed origin allowlist.
- `force_ssl` is enabled with HSTS and `rewrite_on: [:x_forwarded_proto]`.
- TLS termination is expected at the edge proxy or load balancer.

## Native Artifact Policy

- Native binaries (`.so`, `.dylib`, `.dll`) are not committed.
- Artifacts are built in CI/release pipelines to preserve reproducibility and traceability.
