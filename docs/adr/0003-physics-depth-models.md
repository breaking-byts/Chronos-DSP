# Physics depth: corrected knife-edge, static carrier phase, normalized link-budget default

Status: accepted

Chronos deepens its propagation physics while staying teaching-first and
analytically verifiable (design lock #21,
[docs/design/physics-depth.md](../design/physics-depth.md)). The decisions:

- **Diffraction stays the ITU-R P.526 knife-edge model, corrected.** The
  obstruction height is signed, the additive material diffraction loss is
  removed (it double-counted), and each blocking wall keeps its least-loss
  edge. Walls stay independent paths: combining series obstacles needs a
  multiple-knife-edge method, not the §5.1 finite-width-screen power sum, so
  multi-edge combination is deferred. True UTD was also rejected for now: it
  needs complex path fields and a polarization convention, while the research
  verified the `n = 2, R = 0` equivalence to knife-edge within 0.034 dB
  (`docs/research/physics-depth.md`, branch `research/physics-depth`). The
  knife-edge model is never described as UTD.
- **Every path carries its static carrier phase `-2π·f_c·τ`.** Without it all
  paths start in phase at `t = 0`, so geometry-driven frequency selectivity is
  absent. Reflection phase is fixed at `π` (the hard-boundary convention) and
  documented as illustrative; the catalogue has no complex reflection
  coefficients. The packed path record grows from 16 to 24 bytes (phase as
  `f64`) on both the Rust NIF and the Elixir reference.
- **The link-budget default stays normalized (unit gain at one metre).** Friis
  `λ/(4π)` and antenna-gain terms land behind an opt-in `:physical` mode, so
  existing scenes, noise defaults, BER demonstrations, and the golden export
  remain bit-identical. A physical default was rejected because it would shift
  every render by about −40 dB and silently change the demo.
- **Frequency selectivity is taught through an optional statistical TDL**
  (ITU-R M.1225 profiles, seeded and deterministic) plus an explicitly
  illustrative delay-scaling control. A high-sample-rate mode was deferred:
  at 48 kHz the geometric channel is honestly flat.
- **Rendering stays height-aware 2D** per [ADR 0002](0002-interactive-editing-2d-projection.md).
  The isometric Canvas toggle and full three.js 3D were deferred again; no
  rendering dependency is added.

## Considered options

- UTD now instead of corrected knife-edge: highest fidelity, but the complex
  field, polarization, and cotangent-singularity work is a large, risky
  increment for a teaching showcase. Deferred to a dedicated slice.
- Exact Fresnel Eq. 30 instead of the Eq. 31 approximation: within 0.123 dB of
  Eq. 31 for the useful range; the approximation is easier to mirror and the
  clamp is P.526's own engineering choice. Deferred.
- Physical Friis as the default: rejected for the silent −40 dB shift; opt-in
  preserves existing behaviour and goldens.
- three.js r185 vendored 3D: rejected again on bundle (~187 KB gzip),
  WebGL2-only reach, and teaching clarity.

## Consequences

- `#61` (corrected diffraction) and `#62` (static phase) intentionally change
  rendered output; both regenerate their affected goldens in the same change
  and note it in `CHANGELOG.md`.
- The parity contract is explicit: strict bit-equality on packing, ≤ 1e-9
  relative tolerance on dB, delay, and Doppler outputs, and ≤ 1e-9 rad absolute
  tolerance (modulo 2π) on phase.
- Deferred work that needs a ticket is tracked as map children #66–#73 and
  #75; the remaining approximations are recorded in the design doc's deferred
  table.
- Council review (2026-11-25) corrected the grilling answer on multi-edge
  combination: the §5.1 power sum applies to parallel edges of one screen, so
  applying it across blocking walls would reduce loss as obstacles are added.
  The design keeps independent per-wall paths and defers multi-edge models.
- No new runtime dependency, no new vendored asset, and no calibration claim.
