# Physics Depth — Design Lock

Status: locked · issue #21 · 2026-11-25

This is the settled design for physics depth, transcribed from the grilling
session; it is a spec, not code. The decision record is
[ADR 0003](../adr/0003-physics-depth-models.md). Research findings and every
number quoted below are on `docs/research/physics-depth.md` (branch
`research/physics-depth`, issue #24), recomputed by
`docs/research/physics-depth-verify.exs`.

Posture (settled decision 6): teaching-first, plausible, deterministic, and
documented. Verification is analytic (ITU-R recommendations, Friis, canonical
cases). There are **no measurement-calibration claims** anywhere in this work.
Diffraction is knife-edge, not UTD; the material catalogue stays illustrative.

## Scope

Locked in this design:

1. Corrected ITU-R P.526 knife-edge diffraction: signed obstruction height,
   no material double-count, and per-wall edge selection.
2. Static carrier phase per path (the missing TDL physics).
3. An optional statistical TDL channel from ITU-R M.1225 profiles, plus an
   illustrative delay-scaling control.
4. Friis wavelength and antenna-gain terms behind an explicit physical mode,
   with the normalized default preserved.
5. The rendering approach (height-aware 2D, per
   [ADR 0002](../adr/0002-interactive-editing-2d-projection.md)).

Deferred work is listed in [Deferred](#deferred) with its ticket.

## 1. Diffraction

Model: ITU-R P.526-16 §4.1 single knife-edge, applied per blocking wall using
its least-loss edge (independent per-wall paths; see §1.4). Constants:
`c = 299792458 m/s`, default `f_c = 2.4 GHz`, `λ = 0.124913524 m`.

### 1.1 Signed obstruction height

`h` is the height of the selected edge point above the straight transmitter–
receiver line, and is **negative when the edge lies below that line**. Use the
shortest perpendicular distance with its sign; do not take an absolute value.

```
v = h * sqrt(2 / λ * (1 / d1 + 1 / d2))
```

`d1` and `d2` are the distances from the transmitter and receiver to the edge
point. The current model uses an unsigned height, so an edge clearing the path
still incurs loss. Regression fixture: an edge 0.5 m below the line with
`d1 = d2 = 10 m` gives `v = -0.8947` and `0 dB`; the unsigned model reports
13.2281 dB of phantom loss.

### 1.2 Loss function

Keep the P.526 Eq. 31 approximation:

```
J(v) = 6.9 + 20 * log10(sqrt((v - 0.1)^2 + 1) + v - 0.1)
J(v) = 0 for v < -0.78
```

The clamp is P.526's own engineering simplification. The approximation is
within 0.123 dB of the exact Eq. 30 Fresnel-integral form for `v >= -0.78`
(worst at `v = 5`: -0.1226 dB; at `v = -0.5`: +0.1006 dB).

Fixtures: `J(0) = 6.0329`, `J(1) = 13.9257`, `J(2) = 19.0429` dB. Exact Eq. 30
gives 6.0206 / 13.8641 / 19.0910 dB; the gap is accepted.

### 1.3 No material double-count

The knife-edge loss is the whole diffraction loss. **Do not add**
`Material.diffraction_loss_db/1`. Fixture: `J(1) + 6 dB concrete = 19.9257 dB`
against the physical 13.9257 dB. The material catalogue keeps its diffraction
coefficient as metadata for the deferred UTD work; the knife-edge path model
does not apply it.

### 1.4 Edges and multiple walls

Each blocking wall yields **one** diffraction path using its least-loss edge;
ties break by polygon vertex order. Multiple blocking walls yield independent
per-wall paths, which the DSP sums like any other paths.

Do **not** combine blocking walls with a parallel power sum. The P.526 §5.1
finite-width-screen result (`Jav = J - 10log10(N)` for `N` equal parallel
edges) applies to the edges of one screen, where their contributions add;
blocking walls in series are successive obstacles and must not reduce loss.
Applying the parallel formula across walls would make three blockers cost
9.15 dB against one blocker's 13.93 dB. Chronos treats walls as independent
alternative paths, which is an approximation, and defers both the finite-screen
edge summation and a multiple-knife-edge series model (Deygout and the other
ITU-R P.526 §4.3 methods) to #75.

> Council review correction (2026-11-25): the grilling answer originally called
> for one combined path across blocking walls. That applied a parallel
> finite-screen formula to series obstacles and was physically wrong; this
> design keeps independent per-wall paths and defers multi-edge models.

### 1.5 Occlusion

Both legs (transmitter→edge, edge→receiver) are checked against **every** wall,
including the blocking wall itself. The existing behaviour on `master` is
correct; keep it. Endpoint contact with a wall is allowed (it is the edge
touch); passing through a wall interior is not.

## 2. Static carrier phase and the TDL

### 2.1 Static carrier phase

Every path carries the phase it accumulates over its propagation delay:

```
phi_p = wrap(-2 * pi * f_c * delay_s)     # radians, wrapped to -pi..pi
```

The DSP rotation becomes `exp(j * (2*pi * doppler_hz * t + phi_p))` in both the
Rust NIF and `Chronos.DSP.Reference`. Without it, all paths start in phase at
`t = 0` and only baseband sample-grid delay shapes interference; the RF phase
that makes a channel frequency-selective is absent.

Reflection phase is `π` (the hard-boundary convention for a denser dielectric).
The catalogue has no complex reflection coefficients, so this is illustrative
and not calibrated; a per-material phase convention is deferred. Two
equal-gain paths whose path lengths differ by `λ/2` (6.2457 cm at 2.4 GHz,
`Δτ = 0.20833 ns`) cancel at DC once the static phase is applied; without it
they add.

### 2.2 Packing format

One path packs to 24 bytes:

```
<<delay_s::float-64-little, gain::float-32-little,
  doppler_hz::float-32-little, phase::float-64-little>>
```

The Elixir decoder stays total: non-finite float patterns return
`{:error, :invalid_binary}`. The Rust decoder keeps its never-crash guarantee.
This is an internal format; there is no on-disk contract.

### 2.3 Frequency selectivity at 48 kHz

At the default 48 kHz the sample time is 20.833 µs, far larger than any indoor
excess delay (M.1225 Indoor A max tap 310 ns; Indoor B 700 ns). The geometric
channel therefore collapses to a single tap and fading is flat. That is
physically correct, not a bug, and must be documented rather than hidden. The
statistical mode and delay scaling exist to teach selectivity without claiming
the geometric model demonstrates it at this rate.

### 2.4 Statistical TDL mode

Optional `:channel_model` on `Chronos.Channel.paths_for_rx/3`:
`:geometric` (default) or `{:statistical, profile}`. Profiles come from ITU-R
M.1225 Annex 2 §1.2.2 Tables 3–5:

- Indoor A, Indoor B — Flat Doppler spectrum.
- Pedestrian A — Classical (Jakes) Doppler, `f_D = v/λ`, 3 km/h.
- Vehicular A — Classical Doppler, 70 km/h.

Taps are deterministic from the session seed (same seed ⇒ same taps) and are
ordinary `Chronos.Channel.Path` values. Composition rule:

- Reference distance `d` is the geometric TX–RX distance; the reference delay
  is `d / c` and the strongest tap's gain is `Physics.path_gain(d, 0, opts)`.
- Tap `k` delay is `d/c + profile_delay_k * delay_scale`; its gain is the
  reference gain times `10^(power_k / 20)` (power dB to amplitude).
- Tap `k` carries the static carrier phase of its own delay (§2.1).
- Doppler uses the profile's mobile speed `v`, with `f_D = v/λ`. The per-tap
  `u_k` is a seeded uniform in `[0, 1]`: Flat gives
  `f_k = f_D (2u_k - 1)`; Classical/Jakes gives
  `f_k = f_D sin(π (u_k - 0.5))`. The tap's `doppler_hz` is `f_k`.
- The DSP noise RNG is untouched; the tap draw uses its own seeded stream.

Verification fixtures (rms delay spread recomputed from the tables):
Indoor A 37.03 ns, Indoor B 99.25 ns, Pedestrian A 45.99 ns, Vehicular A
370.39 ns. Coherence bandwidth uses `0.2/σ_τ` (correlation > 0.5) and
`0.02/σ_τ` (correlation > 0.9). 3GPP TR 38.901 TDL-A/TDL-C tables are fixtures
and validation only; they are not a second built-in mode.

### 2.5 Delay scaling

A `:delay_scale` option multiplies a statistical profile's **normalized** tap
delays by a desired rms delay spread (the 38.901 Eq. 7.7-1 idea). Chronos
labels it "illustrative time scaling — not a calibration" in the UI and docs.
It is the honest way to show a selective channel without pretending a 48 kHz
geometric channel is selective.

### 2.6 Parity contract

- Packing: strict bit-equality between Elixir and the Rust NIF.
- Physics outputs: ≤ 1e-9 relative tolerance on dB, delay, and Doppler values;
  phase is compared modulo 2π with ≤ 1e-9 rad absolute tolerance (a relative
  tolerance is ill-defined near a wrap). `log10`/`cos` can differ by one ulp
  across libm implementations.
- Algorithm choice stays mirrorable: no library special functions, no
  platform-dependent iteration, fixed operation order.

## 3. Link budget

### 3.1 Modes

`:link_budget` is `:normalized` (default) or `:physical`.

- `:normalized` keeps today's amplitude `1/d`, unit gain at one metre. Every
  existing scene, noise default, BER demo, and golden export stays
  bit-identical.
- `:physical` uses the Friis amplitude `(λ / (4πd)) * sqrt(Gt * Gr)` where
  `Gt = 10^(tx_gain_dbi / 10)` and `Gr = 10^(rx_gain_dbi / 10)`; the opts are
  `:tx_gain_dbi` and `:rx_gain_dbi` (default 0, validated finite). Negative dBi
  is allowed and yields a power gain below one.

Transmit power keeps its existing amplitude factor `10^((P - 10) / 20)`; the
default 10 dBm is unchanged, so power and gain terms compose multiplicatively.

### 3.2 Verification fixtures

Free-space path loss at 2.4 GHz: `40.0520 / 46.0726 / 60.0520 / 80.0520 dB` at
`1 / 2 / 10 / 100 m`; `+6.0206 dB` per distance doubling and per frequency
doubling. Link example: `Pt = 20 dBm`, `Gt = Gr = 0 dBi`, `d = 10 m` gives
`Pr = -40.0520 dBm`. Note that ITU-R P.525-5's practical `32.4` constant reads
0.0478 dB low; Chronos uses the exact form.

### 3.3 Exposure

The mode is selected by the `:link_budget` option (`:normalized` default,
`:physical`), a `link_budget` field on `POST /api/simulate`, and a control-bar
select in the LiveView. Gains stay at their default 0 until the deferred
slider work; they are not editable in this slice.

Read-only metrics `link_budget_mode`, `fspl_db`, `tx_gain_dbi`, `rx_gain_dbi`
appear in `Chronos.SimFrame.metrics/2`, the JSON API, and a LiveView readout.
The CSV metrics columns do not change in this work; versioning them is
deferred.

## 4. Rendering

Height-aware 2D stays the rendering mode ([ADR 0002](../adr/0002-interactive-editing-2d-projection.md)).
The isometric Canvas toggle and full 3D are deferred; full 3D keeps the
vendored three.js r185 escape hatch (WebGL2-gated, Canvas 2D fallback) from
`docs/research/3d-rendering.md`. This lock adds no rendering dependency.

## Deferred

| Item | Why not now | Ticket |
| --- | --- | --- |
| True UTD diffraction (P.526 §6) | Needs complex path fields and polarization; knife-edge covers the teaching case | #66 |
| Multiple-edge models (finite-screen §5.1 summation; P.526 §4.3 series methods) | Series obstacles need a multiple-knife-edge method, not a parallel power sum; slices keep one edge per wall | #75 |
| Exact Fresnel Eq. 30 and negative-v focusing gain | Eq. 31 is within 0.123 dB; the clamp is the P.526 engineering choice | #67 |
| High-sample-rate mode (>= 10 MHz) | 48 kHz is honestly flat; statistical mode teaches selectivity instead | #68 |
| Absolute-power link budget (−174 dBm/Hz + noise figure) | Follows the Friis terms and the material reconciliation | #69 |
| Antenna-gain sliders | Read-only metrics land first; sliders are a UX change | #70 |
| Isometric Canvas view toggle | Height-aware 2D is locked; this is polish, zero dependencies | #71 |
| Full 3D (three.js r185) | ~187 KB gzip, WebGL2-only, works against teaching clarity | #72 |
| Versioned CSV metrics contract | CSV stays stable in this work | #73 |
| Per-material complex reflection phase | Reflection phase is π here (hard-boundary convention), documented illustrative | — |
| Lagrange/windowed-sinc fractional delay | Linear interpolation is adequate at 48 kHz; droop documented | — |
| Corner/vertex diffraction (higher-order edges) | Out of scope for the single-edge model | — |

## Implementation slices

Each slice is one issue and one pull request:

1. Corrected knife-edge diffraction — #61.
2. Static carrier phase — #62 (blocked by #61 for golden/test sequencing).
3. Friis link-budget terms — #63.
4. Statistical TDL engine — #64 (blocked by #62).
5. Statistical scenario + delay-scaling control — #65 (blocked by #64).

Blocking edges on the map: #61–#65 wait for this lock (#21); #62 also waits
for #61, #64 for #62, and #65 for #64. Of the deferred set, #66 waits for #62,
#67 for #61, #68 for #62, #69/#70/#73 for #63, #72 for #71, and #71 for
nothing.

Every slice keeps the full checks green: `bin/test` (including the 80%
coverage gate), `mix format --check-formatted`, and the Rust `fmt`/`clippy`/
`test` gates. Behaviour-changing slices regenerate their affected goldens in
the same change and record it in `CHANGELOG.md` under `## [Unreleased]`.
