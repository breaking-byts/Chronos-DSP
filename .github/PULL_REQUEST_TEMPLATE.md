## Summary

<!-- What does this change do, and why? Keep the physics honest: knife-edge
diffraction is not UTD, material values are illustrative, and the showcase
stays single-tenant with no auth (ADR 0001). -->

Closes #

## Testing

<!-- Commands actually run and their results, e.g. bin/test (coverage gate),
mix format --check-formatted, cargo fmt/clippy/test, bin/smoke --local for
release-affecting changes. -->

## Checklist

- [ ] Tests added/updated; `bin/test` green (Elixir suite incl. property tests, >=80% coverage gate; Rust suite)
- [ ] Docs updated where behavior or vocabulary changed (README, `docs/`, `GLOSSARY.md`)
- [ ] `CHANGELOG.md` entry added under `## [0.3.0] - Unreleased`
- [ ] `mix format --check-formatted`, `cargo fmt --check`, and clippy (`-D warnings`) clean
- [ ] CI green
- [ ] Code review passed (standards + spec); findings addressed
- [ ] No calibration claims or posture changes slipped in without an explicit decision (see `CONTRIBUTING.md`)