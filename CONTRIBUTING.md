# Contributing

Chronos-DSP is a public single-tenant showcase: no authentication, local-first,
teaching-first physics (see [docs/adr/0001-public-showcase-posture.md](docs/adr/0001-public-showcase-posture.md)).
Contributions keep that posture and the honest physics scope: knife-edge
diffraction is not full UTD, and material coefficients are illustrative, not
calibrated measurements.

Use the vocabulary in [GLOSSARY.md](GLOSSARY.md) when naming things in issues,
tests, and prose; [docs/agents/domain.md](docs/agents/domain.md) explains how the
domain docs fit together.

## Setup

Requirements (pinned in `.tool-versions`): Erlang/OTP 28.3.1, Elixir
1.19.5-otp-28, and Rust 1.89+. `cargo` must be on `PATH` — Rustler compiles the
NIF during `mix compile`.

```bash
asdf install        # or: mise install
bin/setup           # toolchain + mix deps.get/compile + cargo build
mix phx.server      # http://localhost:4000
```

Without asdf/mise, install the pinned toolchains yourself, then:

```bash
mix deps.get
mix compile         # Rustler builds the NIF here
```

In dev/test the NIF is optional: a missing artifact falls back to the
deterministic pure-Elixir reference renderer. Production requires the NIF.

## Checks

Run these before opening a pull request; CI runs the same gates.

```bash
bin/test                                  # MIX_ENV=test mix coveralls + cargo test
mix format --check-formatted
(cd native/chronos_dsp && cargo fmt --check)
(cd native/chronos_dsp && cargo clippy --all-targets --all-features -- -D warnings)
```

- `bin/test` enforces the coverage gate: at least 80% total Elixir coverage
  via ExCoveralls (`coveralls.json`). The suite includes StreamData property
  tests; add one when you state an invariant, not just an example.
- Rust changes need `cargo test` green and clippy clean at `-D warnings`.
- Release-affecting changes (Dockerfile, release config, assets, NIF loading):
  run `bin/smoke --local` (no docker) or `bin/smoke` (docker). The release
  workflow smokes the pushed image before creating the GitHub Release. See
  [docs/OPERATIONS.md](docs/OPERATIONS.md).
- `bin/profile` measures render throughput if you touch the DSP path.

## Issues and triage

File bugs and feature requests with the issue forms (`.github/ISSUE_TEMPLATE/`);
blank issues are disabled. New issues land as `needs-triage`.

The triage vocabulary is defined in
[docs/agents/triage-labels.md](docs/agents/triage-labels.md): `needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. Tracker
conventions (`gh` CLI, sub-issues, blocking edges) live in
[docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).

Security vulnerabilities: do not open a public issue. Follow the private
reporting path in [docs/SECURITY.md](docs/SECURITY.md).

## Pull requests

- Branch from `master` and keep the change scoped to one issue; reference it
  (`Closes #<n>`) in the PR body. The PR template lists the full checklist.
- **Tests**: add or update ExUnit tests (and Rust tests for NIF changes);
  `bin/test` must be green, including the coverage gate.
- **Docs**: update README and the relevant `docs/` page when behavior changes;
  add new domain terms to `GLOSSARY.md` rather than inventing synonyms.
- **CHANGELOG**: add an entry under `## [0.3.0] - Unreleased` in
  [CHANGELOG.md](CHANGELOG.md) (Keep a Changelog format). The release ticket
  stamps the date at tag time.
- **Formatting/lint**: `mix format --check-formatted`, `cargo fmt --check`,
  and clippy clean.
- **CI green**: the CI workflow checks formatting, compiles with
  `--warnings-as-errors`, runs `mix coveralls`, and runs the Rust gates.
- **Code review**: every PR passes a code review (standards and spec) before
  merge; address review findings rather than working around them.
- **Physics honesty**: no calibration claims, no implied UTD diffraction, no
  multi-user/auth features that contradict ADR 0001 without an explicit
  decision to revisit it.