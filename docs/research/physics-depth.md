# Physics depth: diffraction (knife-edge vs UTD), tapped-delay-line channels, Friis link budget

Research findings for wayfinder ticket #24. Branch `research/physics-depth` (throwaway, no PR).
Date: 2026-11-20. Method: primary sources only (ITU-R recommendations, original papers,
author-hosted texts, 3GPP spec), with every quoted number recomputed analytically by
[`physics-depth-verify.exs`](physics-depth-verify.exs) (pure Elixir, no deps — run
`elixir docs/research/physics-depth-verify.exs`). Posture per ADR 0001: plausible +
documented + analytically verified; **no measurement-calibration claims** anywhere below.

## TL;DR — recommendations

1. **Diffraction: keep ITU-R P.526 knife-edge, but correct it.** Signed obstruction height
   `h` (P.526-16 Eq. 26 explicitly defines `h` negative below the line), drop the additive
   material "diffraction loss" (double count), stop exempting the blocking wall from leg
   occlusion checks, and combine multiple edges per P.526-16 §5.1 instead of picking one.
   All four PR #8 quirks are fixed by this, it is cheap, and every step is mirrorable in the
   Rust NIF + Elixir reference. **True UTD is not required to fix the quirks** — it is the
   next-depth option (wedge angles, polarization, material, complex field). P.526-16 §6
   already publishes a complete implementable UTD formulation; we verified numerically that
   its `n=2, R=0` screen case reproduces the exact knife-edge curve to **≤ 0.034 dB**
   (the ITU itself states this equivalence after Eq. 106).
2. **TDL: the data plane already *is* a tapped-delay line** (per-path fractional delay +
   Doppler + gain in `render_samples`, mirrored in `Chronos.DSP.Reference`). The biggest
   physics gap is the **missing static carrier phase** `−2πf_cτ_p` per path; without it,
   geometry-induced frequency selectivity is essentially absent. Add reference profiles
   (ITU-R M.1225, 3GPP TR 38.901) as fixtures/optional statistical mode, and be honest that
   at the current 48 kHz sample rate indoor geometric channels are flat (single tap).
3. **Friis: add the `λ/(4π)` factor and antenna gains** (−40.05 dB at 1 m, 2.4 GHz vs the
   current 1/r-at-1 m normalization), optionally an absolute-power mode
   (`Pt + Gt + Gr − FSPL`, noise from −174 dBm/Hz + NF). All terms analytically verified
   below against Friis 1946, ITU-R P.525-5, Balanis, and Goldsmith's two-ray model.

---

## 0. Baseline: what the code does today

Facts from the PR #8 digest plus direct reads of `master` and `origin/feat/advanced-propagation`
(PR #8 is open; `master` still has the single-file `Chronos.Channel`):

- `Chronos.Channel.Diffraction` (PR #8): per blocking wall, picks the polygon edge point
  closest to the infinite Tx–Rx line, computes
  `v = height * sqrt(2/λ * (1/d1 + 1/d2))` with `height = Geometry.distance(edge_point, line_point)`
  — **unsigned**, so `v ≥ 0` always; `knife_edge_loss_db/1` implements P.526 Eq. (31)
  `J(v) = 6.9 + 20log10(sqrt((v−0.1)²+1) + v−0.1)` with a `v < −0.78 → 0` branch that is
  unreachable. Adds `Material.diffraction_loss_db(wall)` on top. Leg occlusion checks pass
  `ignored_ids = MapSet.new([wall_id])`, i.e. **the blocking wall itself is exempt**, so a
  diffraction leg may cross its face. Edges lying exactly on the line are skipped.
- `Chronos.Channel.Physics` (PR #8): amplitude `1/d` normalized at 1 m; dB losses via
  `10^(−dB/20)`; `c = 299792458`, `f = 2.4e9` defaults; Doppler from first/last-leg velocity
  projections. No wavelength/gain/power term in path gain.
- `native/chronos_dsp/src/lib.rs` `render_samples` (master): for each path,
  `delay_samples = delay_s * sample_rate`, floor index + **linear interpolation** between
  adjacent TX samples, rotation `exp(j2π·doppler_hz·t)`, scale by `gain` (f32), sum, add
  seeded Gaussian noise. `Chronos.DSP.Reference.delayed_sample/3` mirrors the interpolation.
  **There is no static propagation phase term** — only Doppler·t.
- UI/profile scripts use `sample_rate: 48_000.0` (T_s = 20.833 µs).
- Material catalogue: 11 materials, fixed illustrative dB triples
  (reflection/transmission/diffraction), explicitly not calibrated.

---

## A. Diffraction: corrected knife-edge vs true UTD

### A.1 What ITU-R P.526 actually specifies

Source: **ITU-R P.526-16 (11/2025), "Propagation by diffraction"** [S1], Annex 1.
(P.526-15 is the edition incorporated by reference in the Radio Regulations 2024; -16 is
current and in force. The knife-edge material below is unchanged between them.)

- **Signed Fresnel parameter** (§4.1, Eq. 26):
  `ν = h·sqrt( (2/λ)·(1/d1 + 1/d2) )`, where *h is the height of the obstacle top above the
  straight line joining the path ends; "If the height is below this line, h is negative"*
  (verbatim definition under Eqs. 26–29). `d1, d2` are distances from the terminals to the
  obstacle top. Equivalent angle forms (Eqs. 27–29) carry the sign of `h`; the diffraction
  angle θ is assumed ≲ 0.2 rad (~12°).
- **Exact loss** (Eq. 30): `J(ν) = −20log10( sqrt([1−C(ν)−S(ν)]² + [C(ν)−S(ν)]²) / 2 )`
  with the Fresnel integrals `C, S` of §2.7 (Eqs. 7a/7b).
- **Approximation** (Eq. 31): `J(ν) ≈ 6.9 + 20log10( sqrt((ν−0.1)²+1) + ν−0.1 )` for
  `ν > −0.78`; the recommendation itself uses `J = 0` below that (§4.5.1, §4.6.1). This is
  exactly the formula PR #8 implements — the formula is right; the *input* `v` is wrong.
- **Fresnel evaluation** (§2.7, Eqs. 8a/8b/9): the recommendation publishes the **Boersma
  rational approximation** with all 48 coefficients, split at `x = πν²/2 = 4`, plus odd
  symmetry for negative ν (Eqs. 10a/10b). This is an ITU-blessed, fully deterministic
  algorithm — ideal for a bit-parity mirror (verified accuracy in A.5).
- **Isolated-obstacle caveat** (§2.5): knife-edge theory assumes ≥ 0.6·R₁ Fresnel clearance
  on both sides and *no specular reflection* near the obstacle. Chronos emits reflection
  paths alongside diffraction; that superposition is an approximation, fine for teaching,
  worth a docstring.
- **Finite-width screen** (§5.1, Eqs. 71–72): a finite screen is modeled as **three
  knife-edges (top + both sides)**; minimum loss from *amplitude* addition
  `Jmin = −20log10(1/j1 + 1/j2 + 1/j3)`, average loss from *power* addition
  `Jav = −10log10(1/j1² + 1/j2² + 1/j3²)`, `ji = 10^(J(νi)/20)`. The recommendation notes
  the model "has been tested against accurate calculations using the uniform theory of
  diffraction (UTD) and high-precision measurements."
- **Rectangular apertures/screens** (§5.2, Eqs. 75–89): complex normalized field via Fresnel
  integrals over the aperture edges; a screen is the Babinet complement `es = 1 − ea`
  (Eq. 89); arbitrary shapes approximated by rectangle combinations. This yields **complex
  fields (amplitude + phase)** — the natural bridge to a phase-aware TDL.
- **Finitely conducting wedge** (§6, Eqs. 90–106): a complete **UTD** formulation — see A.3.

### A.2 The four PR #8 quirks and their fixes

| # | Quirk (PR #8) | Fix | Source |
|---|---|---|---|
| 1 | Unsigned edge-to-line distance ⇒ `v ≥ 0`, ≥ 6 dB even for non-obstructing edges; `v < −0.78` branch unreachable | Signed `h` in the diffraction plane (below); keep edges on the line (`v = 0`) | P.526-16 Eq. 26 definition [S1] |
| 2 | `Material.diffraction_loss_db` added on top of `J(v)` | Remove it from diffraction; `J(v)` is already the total edge loss. Material stays on reflection/transmission. Material-dependent edge loss ⇒ UTD with εr, σ (A.3) | P.526-16 §4.1/§6 [S1] |
| 3 | Diffraction legs exempt the blocking wall ⇒ legs may cross its face | Legs may intersect the blocking wall **only at the diffraction edge point** (ε-tolerance); reject interior crossings | geometry of edge diffraction; P.526 §4.1 isolated-edge idealization [S1] |
| 4 | One "least-loss edge" per wall | Combine top + side edges per §5.1 (power sum for the scalar-gain model), or §5.2 screen field | P.526-16 Eqs. 71–72, 75–89 [S1] |

**Fix 1 — signed h in 3D.** For edge point `E`, let `P` be the closest point on the
(infinite) Tx–Rx line, `ê = (E−P)/‖E−P‖`, and `ŵ` the unit direction from `E` into the wall
interior, perpendicular to the edge (for a convex polygon: project `centroid − E` off the
edge direction and normalize). Then

```
h = −‖E − P‖ · dot(ê, ŵ)
```

- Wall extends from the edge *toward* the line (edge protrudes into the path): `dot(ê,ŵ) < 0`
  ⇒ `h > 0` ⇒ obstructing knife-edge, `J(v) > 0`.
- Wall extends *away* from the line (edge on the clearance side): `h < 0` ⇒ `J ≈ 0`
  (exact Fresnel gives small ripples, A.5).
- LOS pierces the wall face: top and bottom edges both read `h > 0` (each is a knife-edge
  with the screen between it and the line) — combine them per Fix 4 rather than picking one.
- `E` exactly on the line: `h = 0`, `v = 0`, `J = 6.02 dB`. **The 6 dB grazing floor is
  correct physics** (an opaque half-plane on the LOS removes half the field amplitude);
  the bug is imposing it on edges that do *not* obstruct. The current code also *skips*
  on-line edges; it should keep them at `v = 0`.

Magnitude of the bug (verified): edge 0.5 m **below** the LOS, `d1 = d2 = 10 m`, 2.4 GHz:
signed `v = −0.8947 → J = 0 dB`; unsigned `v = +0.8947 → J = 13.23 dB` of phantom loss.

**Fix 2 — no material dB on diffraction.** `J(v)` is the complete loss of the canonical
opaque-screen problem relative to free space; adding a heuristic material term double
counts (verified example: `J(1) = 13.93 dB` + concrete 6 dB = 19.93 dB vs 13.93 dB).
P.526's only material-dependent diffraction route is §6, where εr and σ enter through the
wedge-face reflection coefficients (A.3). The current catalogue stores illustrative dB, not
εr/σ, so a material-aware UTD would need a new parameterization — a separate decision.
Keep `Material.diffraction_loss_db/1` in the catalogue API if other code reads it, but stop
applying it in `Diffraction`; document the field as deprecated/illustrative.

**Fix 3 — legs must not cross the blocking face.** Replace the blanket `ignored_ids`
exemption with: intersect each leg (Tx→E, E→Rx) with the wall plane; if the intersection is
strictly inside the polygon and farther than ε from `E`, reject the candidate. The leg
endpoint `E` itself lies on the boundary and is allowed. Other walls keep the existing
occlusion check. Deterministic, mirrorable, O(1) per leg.

**Fix 4 — combine edges.** For a rectangular wall the §5.1 three-edge model is directly
applicable (top + two sides; for a wall whose bottom edge is also exposed, include it —
§5.1's construction is "the edges of the screen transverse to propagation"). With equal
`v` on three edges (verified): `Jmin = J − 9.54 dB`, `Jav = J − 4.77 dB` — picking a single
edge overstates loss by up to ~9.5 dB. Recommend **power sum (`Jav`)** for today's
scalar-gain paths (it is the recommendation's "average" estimate and avoids implying
phase coherence we do not model); switch to phasor sum when paths carry complex fields.
§5.2 (rectangular screen, `es = 1 − ea`) is the more accurate successor and produces the
complex field a phase-aware TDL wants; it needs Boersma C/S + complex arithmetic, both
already specified in this doc.

### A.3 True UTD (Kouyoumjian–Pathak 1974): what it adds, what it costs

**Origin.** R. G. Kouyoumjian and P. H. Pathak, "A uniform geometrical theory of diffraction
for an edge in a perfectly conducting surface," *Proc. IEEE* 62(11):1448–1461, Nov. 1974,
doi:10.1109/PROC.1974.9651 [S5]. From the paper's abstract (NASA NTRS record 19750029381):
a compact dyadic diffraction coefficient for oblique incidence on curved or plane PEC
edges, **valid in the transition regions adjacent to shadow and reflection boundaries where
Keller's original GTD coefficients fail**, built from the canonical wedge problem; in the
proper **ray-fixed coordinate system** the dyadic coefficient is the sum of two dyads
(acoustic-soft and acoustic-hard), with Fresnel integrals ensuring continuity of the total
field at the boundaries. (Full text is IEEE-paywalled; the abstract is public at NTRS. The
implementable formulation below comes from ITU-R P.526-16 §6, which is UTD-based, and from
Balanis [S8] Ch. 13, which reproduces the KP coefficient and its oblique-incidence form.)

**What UTD buys over corrected knife-edge:**
- wedge angle ≠ 180° (building corners, roof ridges) via `n` (exterior angle / π);
- polarization (soft/hard, ⊥/∥) and **material** via face reflection coefficients
  `R0, Rn` computed from εr, σ — the principled home for "material diffraction loss";
- uniform, finite field across shadow/reflection boundaries (no ad-hoc clamps);
- **complex diffracted field** (amplitude + phase) → feeds the TDL properly;
- oblique incidence handled by ray-fixed coordinates (KP74; Balanis §13.3.3 [S8]).

**Implementable primary formulation — P.526-16 §6 (Eqs. 90–106) [S1]:**

```
e_UTD = e0 · exp(−jks1)/s1 · D⊥∥ · sqrt( s1 / (s2(s1+s2)) ) · exp(−jks2)      (90)

D⊥∥ = −exp(−jπ/4)/(2n·sqrt(2πk)) · [
    cot((π+(Φ2−Φ1))/(2n))·F(kL·a⁺(Φ2−Φ1))
  + cot((π−(Φ2−Φ1))/(2n))·F(kL·a⁻(Φ2−Φ1))
  + R0⊥∥·cot((π−(Φ2+Φ1))/(2n))·F(kL·a⁻(Φ2+Φ1))
  + Rn⊥∥·cot((π+(Φ2+Φ1))/(2n))·F(kL·a⁺(Φ2+Φ1)) ]                              (91)

F(x) = 2j·sqrt(x)·exp(jx)·∫_{sqrt(x)}^∞ exp(−jt²) dt                          (92)
∫_{sqrt(x)}^∞ exp(−jt²) dt = sqrt(π/8)·(1−j) − ∫_0^{sqrt(x)} exp(−jt²) dt     (93)
L = s1·s2/(s1+s2)                                                             (96)
a±(β) = 2·cos²((2nπN± − β)/2),  N± = nearest integer to (β±π)/(2nπ)        (97–99)
R⊥ = (sinΦ − sqrt(η−cos²Φ))/(sinΦ + sqrt(η−cos²Φ))                           (100)
R∥ = (η·sinΦ − sqrt(η−cos²Φ))/(η·sinΦ + sqrt(η−cos²Φ))                       (101)
η = εr − j·18×10⁹·σ/f   (f in Hz; Φ = Φ1 for R0, Φ = nπ−Φ2 for Rn)
```

At a boundary one cotangent is singular but the product is finite; Eq. (102) gives the
limit `n·[sqrt(2πkL)·sign(ε) − 2kLε·exp(jπ/4)]·exp(jπ/4)` with ε per Eqs. (103–104).
Eq. (105) adds the LOS ray in the lit region (`Φ2 < Φ1+π`); Eq. (106) expresses the result
in dB relative to free space. **The recommendation states: "for n = 2 and zero reflection
coefficients, this should give the same results as the knife edge diffraction loss curve"
(Fig. 9)** — we verified this numerically (A.5): max deviation 0.033 dB over v ∈ [−4.93, 4.93].

For computation, `F(x)` reduces to the same Boersma C/S: with `u = sqrt(2x/π)`,
`∫_0^{sqrt(x)} exp(−jt²)dt = sqrt(π/2)·(C(u) − jS(u))`, so
`F(x) = 2j·sqrt(x)·exp(jx)·sqrt(π/2)·[(½−C(u)) − j(½−S(u))]`.
No special functions beyond sqrt/cos/sin/tan/log10 and a 12-term polynomial are needed.

**Costs / caveats for Chronos:**
- Complex arithmetic throughout the diffraction path (NIF already has `Complex`; Elixir
  mirror is `{re, im}` tuples — the verify script does exactly this).
- Per-edge geometry: incidence/diffraction angles Φ1, Φ2 measured from the illuminated
  wall face; `n = 2` for zero-thickness wall edges (half-plane screen). Corner/vertex
  diffraction (where two edges meet) is higher-order and out of scope.
- **2D specialization**: P.526 §6 says "specializing to two dimensions". Chronos is 3D;
  for a straight edge the rigorous reduction is in the plane perpendicular to the edge
  with `k → k·sinβ0` (β0 = angle between edge and incident ray; KP74 ray-fixed coordinates,
  Balanis §13.3.3 [S8]). For vertical wall edges and near-horizontal rays β0 ≈ 90° and the
  2D form is a good approximation; steep rays need the skew correction. Document the
  approximation if shipped.
- Polarization: Chronos has no polarization state; pick one (e.g. soft/⊥) or average, and
  document it. Material-aware UTD needs εr/σ per material (new catalogue parameters).
- Cotangent singularity handling (Eq. 102) and integer `N±` selection are the only subtle
  numerics; both are deterministic and unit-testable.

### A.4 Options and trade-offs

| Option | Content | Effort | Accuracy vs canonical | Parity risk | Teaching value |
|---|---|---|---|---|---|
| **A. Corrected signed-v knife-edge** | Fixes 1–3; Eq. 31 + signed h; keep single edge | S | exact within Eq. 31's ≤ 0.13 dB; phantom-loss bug gone | low (real arithmetic only) | high: Fresnel zones, 6 dB grazing |
| **B. A + multi-edge §5.1** (recommended now) | also Fix 4, power-sum `Jav` | S | removes up-to-9.5 dB single-edge over-loss | low | high: interference of edge contributions |
| **C. Rectangular screen §5.2** | complex field via Boersma + Babinet `es = 1−ea` | M | exact Fresnel screen solution (small θp) | medium (complex mirror) | high: phase, aperture diffraction |
| **D. UTD §6 / KP74** | wedge D-coefficient, R0/Rn, boundaries, complex field | L | uniform; ≡ knife-edge at n=2, R=0 (verified ≤ 0.034 dB) | medium (complex + singular limits) | highest: "true UTD" roadmap item |

**Recommendation:** ship **B** as the physics-lock baseline (fixes every named quirk with
ITU-blessed formulas and trivial parity). Treat **C/D** as the follow-up that lands together
with complex path fields (needed anyway for the TDL static phase, B.2); **D** is the
showcase "true UTD" item and P.526 §6 means it can be built without ever touching the
paywalled KP74 text. Do **not** market B/C as UTD.

### A.5 Verification cases (all recomputed by the script)

Constants: `c = 299792458 m/s`, `f = 2.4 GHz`, `λ = 0.124913524 m`.

1. **Boersma accuracy** (P.526 Eqs. 8–9 vs composite-Simpson reference): max |err| in C or S
   over ν ∈ [0, 6] step 0.01 = **3×10⁻⁹**. Production-safe.
2. **Canonical J values** (Eq. 31 approximation — what PR #8 tests assert):
   `J(0) = 6.0329`, `J(1) = 13.9257`, `J(2) = 19.0429` dB (tests round to 6.03/13.93/19.04 ✓).
   Exact Eq. (30): `6.0206 / 13.8641 / 19.0910` dB. Approximation error vs exact:
   ≤ 0.123 dB for ν ≥ −0.78 (worst at ν = 5: −0.1226 dB; at ν = −0.5: +0.1006 dB).
3. **Negative-v physics** (exact Eq. 30; unreachable in current code):
   `J(−1) = −1.0010 dB`, `J(−1.2) = −1.3661 dB`, `J(−2) = +0.7366 dB`, `J(−3) = −0.4439 dB`.
   Fine sweep over [−3, 0]: peak *gain* 1.3685 dB at v = −1.22 (obstacle focusing). The Eq. 31 clamp to 0 below −0.78 is the
   recommendation's own engineering simplification; the ripples are physical.
4. **UTD ↔ knife-edge equivalence** (P.526 §6, n=2, R0=Rn=0; geometry: edge at origin,
   screen along +x, Tx=(0,100 m), Rx=(100·sinδ, −100·cosδ), δ ∈ [−10°, +10°]):
   max |UTD_loss − J_exact| = **0.03312 dB** over v ∈ [−4.932, +4.932]; ≤ 0.0014 dB for
   |v| ≤ 1. Shadow boundary (v=0): total field **−6.0206 dB from both sides** (continuous,
   = the 6 dB grazing loss). Boersma-based F(x) and Simpson-based F(x) agree to 4 decimals.
5. **Material matters in UTD**: same geometry with PEC faces (R0=Rn=−1, soft pol):
   at v=4.932, −27.646 dB vs −26.851 dB absorbing (0.80 dB); lit-region values shift by
   ≤ 0.03 dB here. This is the principled replacement for the heuristic material dB.
6. **Signed-v fix magnitude**: edge 0.5 m below LOS, d1=d2=10 m: signed v=−0.8947 → 0 dB;
   unsigned → **13.2281 dB phantom loss**.
7. **Multi-edge combination** (§5.1, three equal-v edges): at v=1, single-edge 13.9257 dB →
   Jmin 4.3833 dB (−9.5424), Jav 9.1545 dB (−4.7712). Same offsets at v=0 and v=2.
8. **Double-count magnitude**: J(1) + concrete 6 dB = 19.9257 dB vs 13.9257 dB physical.

---

## B. Tapped-delay-line frequency-selective channel

### B.1 What already exists

`render_samples` (Rust NIF) is a per-path TDL: delay in samples `τ_p·f_s`, fractional tap
via linear interpolation, per-path Doppler rotation, per-path gain, coherent sum, seeded
noise. The Elixir reference mirrors it (`delayed_sample/3`). So "per-path delay → taps"
is **already implemented**; the roadmap gap is physics fidelity and reference models, not
the tap machinery itself.

### B.2 The missing physics: static carrier phase

Each path should carry `φ_p = −2πf_c·τ_p (mod 2π)` (plus interaction phase shifts, e.g. π
for a PEC-like reflection) in addition to the Doppler term. Today all paths start in phase
at t=0, so interference is dictated only by baseband sample-grid delays — the RF phase
interference that *makes* a channel frequency-selective is absent.

- Why it matters: at 2.4 GHz, `f_c·τ ≫ 1` for any macroscopic path (Goldsmith [S7] Ch. 3
  Problem 4 asks the reader to prove exactly this: f_c=1 GHz, d>10 m ⇒ f_cτ > 33).
  A path-length difference of **λ/2 = 6.2457 cm** (Δτ = 0.20833 ns) flips two equal paths
  from constructive to a **DC null**. Verified analytically: two equal-amplitude paths give
  `|H(f)| = 2a·|cos(π(f+f_c)Δτ)|`; with `f_cΔτ = 0.5` the notch sits at f=0, notch spacing
  `1/Δτ = 4.8 GHz`. Without the static phase the same geometry is constructive at t=0.
- Implementation: one `fmod` per path in Elixir, one `%` in Rust; add to the packed path
  record or recompute from `delay_s` inside the NIF (deterministic either way). Reflection
  phase: start with 0 or π per material class, documented as illustrative.
- This is the single highest-value TDL change; it also makes the diffraction complex field
  (A.4 C/D) meaningful once it lands.

### B.3 Fractional-delay filter quality

Linear interpolation is a two-tap FIR `H(f) = (1−α) + α·e^{−j2πf/f_s}` (α = fractional
part). Verified droop at α = 0.5: **−0.44 dB at f=0.1f_s, −3.01 dB at 0.25f_s, −10.20 dB at
0.4f_s, exact null at 0.5f_s**. Options:

| Option | Effort | Notes |
|---|---|---|
| Keep linear interp, document the droop | S | fine at 48 kHz where signal band ≪ f_s; dishonest at high rates |
| 3rd/4th-order Lagrange interpolation | S | polynomial, trivially mirrorable, much flatter passband |
| Windowed-sinc (e.g. 8–16 taps, Kaiser) | M | best flatness; fixed coefficient table, mirrorable |
| Farrow structure | M | continuous fractional delay; more state, same parity discipline |

Recommendation: Lagrange-3 now (cheap, mirrorable), windowed-sinc if/when a wideband mode
ships. Whatever is chosen, pin the exact polynomial/coefficient order in both languages.

### B.4 Delay-spread models and reference profiles

**ITU-R M.1225 (1997) [S3], Annex 2 §1.2.2, Tables 2–5** — IMT-2000 evaluation TDLs.
Each tap: relative delay (ns), average power relative to strongest tap (dB), Doppler
spectrum. "A small variation, ±3%, in the relative time delay is allowed so that the
channel sampling rate can be made to match some multiple of the link simulation sample
rate." Indoor taps use a **Flat** Doppler spectrum; pedestrian/vehicular use **Classic**
(Jakes): `G(υ) = 1/(π·υ_max·sqrt(1−((υ−υ_sat)/υ_max)²))`, `υ_max = V/λ`, with test speeds
3 km/h (pedestrian) and 70 km/h (vehicular) (Appendix 1 to Annex 2, §2.1.3).

Table 2 — rms delay spread and occurrence:

| Environment | A: σ (ns) / time % | B: σ (ns) / time % |
|---|---|---|
| Indoor office | 35 / 50 | 100 / 45 |
| Outdoor-to-indoor & pedestrian | 45 / 40 | 750 / 55 |
| Vehicular, high antenna | 370 / 40 | 4000 / 55 |

Table 3 — Indoor office (Flat Doppler):

| Tap | A delay (ns) | A power (dB) | B delay (ns) | B power (dB) |
|---|---|---|---|---|
| 1 | 0 | 0 | 0 | 0 |
| 2 | 50 | −3.0 | 100 | −3.6 |
| 3 | 110 | −10.0 | 200 | −7.2 |
| 4 | 170 | −18.0 | 300 | −10.8 |
| 5 | 290 | −26.0 | 500 | −18.0 |
| 6 | 310 | −32.0 | 700 | −25.2 |

Table 4 — Outdoor-to-indoor & pedestrian (Classic Doppler):

| Tap | A delay (ns) | A power (dB) | B delay (ns) | B power (dB) |
|---|---|---|---|---|
| 1 | 0 | 0 | 0 | 0 |
| 2 | 110 | −9.7 | 200 | −0.9 |
| 3 | 190 | −19.2 | 800 | −4.9 |
| 4 | 410 | −22.8 | 1200 | −8.0 |
| 5 | — | — | 2300 | −7.8 |
| 6 | — | — | 3700 | −23.9 |

Table 5 — Vehicular, high antenna (Classic Doppler):

| Tap | A delay (ns) | A power (dB) | B delay (ns) | B power (dB) |
|---|---|---|---|---|
| 1 | 0 | 0.0 | 0 | −2.5 |
| 2 | 310 | −1.0 | 300 | 0 |
| 3 | 710 | −9.0 | 8900 | −12.8 |
| 4 | 1090 | −10.0 | 12900 | −10.0 |
| 5 | 1730 | −15.0 | 17100 | −25.2 |
| 6 | 2510 | −20.0 | 20000 | −16.0 |

**3GPP TR 38.901 v16.1.0 [S4], §7.7** — the modern reference (0.5–100 GHz, ≤ 2 GHz BW):
- **TDL-A/B/C** (NLOS, Rayleigh taps): 23/23/24 taps, Tables 7.7.2-1/-2/-3 give
  *normalized* delays and powers. **TDL-D/E** (LOS): 13/14 taps; first tap Ricean with
  K₁ = 13.3 dB / 22 dB; Doppler is classical Jakes with `f_D = v/λ₀`, and the LOS tap adds a
  spectral peak at `f_S = 0.7·f_D` (§7.7.2).
- **Delay scaling** (§7.7.3, Eq. 7.7-1): `τ_scaled = τ_model · DS_desired`. Example presets
  (Table 7.7.3-1): very short 10 ns, short 30 ns, nominal 100 ns, long 300 ns, very long
  1000 ns. Scenario medians at 2 GHz (Table 7.7.3-2): Indoor office 20/39/59 ns
  (short/normal/long), UMi 65/129/634 ns, UMa 93/363/1148 ns, RMa 32/37/153 ns.
- **CDL-A…E** (§7.7.1, Tables 7.7.1-1…5) add per-cluster angles (AOD/AOA/ZOD/ZOA) — the
  spatial extension if Chronos ever models antenna patterns; TDLs are the isotropic-antenna
  reduction (§7.7.4).
- Verified: recomputing rms DS of the normalized TDL-A and TDL-C tables gives **1.0001 /
  1.0000** — confirming the normalization convention (scale by desired DS directly).

**How these plug into Chronos:** the geometric channel already produces per-path delays;
the profiles serve as (a) golden fixtures for the tap machinery, (b) an optional
"statistical channel" mode (seeded Rayleigh/Rice tap fading + Jakes Doppler) independent of
geometry, and (c) sanity bounds for scene design (indoor σ ~ 35–100 ns).

### B.5 Frequency selectivity: the 48 kHz reality check

- rms delay spread `σ_τ = sqrt( Σp_iτ_i²/Σp_i − (Σp_iτ_i/Σp_i)² )`, `p_i = 10^(dB_i/10)`
  (standard power-delay-profile moments; Goldsmith [S7] §3.3).
- **Coherence bandwidth** (Goldsmith §3.3, citing Lee): `Bc ≈ 0.2/σ_τ` (correlation > 0.5),
  `Bc ≈ 0.02/σ_τ` (correlation > 0.9). Verified: Indoor A (σ=37.0 ns recomputed) →
  **5.40 MHz / 0.54 MHz**; Indoor B → 2.02 MHz / 0.20 MHz.
- Flat vs selective: signal bandwidth B ≪ Bc ⇒ flat fading; B ≫ Bc ⇒ frequency-selective
  (Goldsmith §3.3). Equivalently symbol time T_s ≫ σ_τ ⇒ negligible ISI. Goldsmith
  Example 3.6: σ=30 ns ⇒ ISI-free symbol rate ≤ 3.33 Mbps (T_s ≥ 10σ).
- **Chronos at 48 kHz**: T_s = 20.833 µs ≫ 310 ns (max indoor excess delay) ⇒ the geometric
  channel collapses to a single tap; fading is flat. This is physically correct, not a bug —
  but it means frequency-selective effects cannot be demonstrated at the current rate.
  Options to teach selectivity (all documentable without calibration claims):
  1. a high-sample-rate mode (e.g. ≥ 10 MHz) where taps resolve;
  2. an explicit **delay-scaling knob** ("time magnification", labeled illustrative — the
     same trick as 38.901's DS scaling, Eq. 7.7-1);
  3. the statistical TDL profile mode (B.4) with a chosen DS preset.
  Recommendation: (3) + (2); keep the geometric mode honest about being flat at 48 kHz.

### B.6 Verification cases (script output)

1. rms DS recomputed from M.1225 tap tables: Indoor A **37.03 ns** (Table 2 nominal 35),
   Indoor B **99.25** (100), Pedestrian A **45.99** (45), Vehicular A **370.39** (370) —
   tables internally consistent to rounding (the ±3% delay tolerance explains the rest).
2. TDL-A/TDL-C normalized rms DS = 1.0001 / 1.0000 (normalization check).
3. TDL-C scaled to DS = 100 ns: max delay 8.6523·100 = **865.2 ns**.
4. Nearest-tap binning of Indoor A at f_s = 100 MHz (T_s = 10 ns): indices **0, 5, 11, 17, 29, 31**.
5. Linear-interp droop at α=0.5: −0.4359 / −3.0103 / −10.2004 dB at f/f_s = 0.1/0.25/0.4;
   null at 0.5.
6. Two equal paths, ΔL = λ/2 = 6.2457 cm (Δτ = 0.20833 ns): with static phase → DC null
   (`f_cΔτ = 0.5`); without → constructive at t=0 (current behavior).

---

## C. Friis link budget

### C.1 The terms, from the primary sources

**Friis 1946 [S6]** (original, open-access copy): `Pr/Pt = Ar·At/(d²λ²)` (Eq. 1), with
effective areas; isotropic antenna `A_isotr = λ²/(4π)` (Eq. 6); lossless half-wave dipole
`A = 0.1305λ²` (Eq. 5) ⇒ gain `4π·0.1305 = 1.640 → 2.148 dBi` (the familiar 2.15 dBi);
small dipole `3λ²/(8π) = 0.1193λ²` (Eq. 4, directivity 1.5 = 1.76 dBi). Limitations stated
in the paper: plane-wave front assumed, valid for `d ≳ 2a²/λ` (a = largest antenna
dimension, Eq. 11), free space only.

**Modern gain form** (Balanis, *Antenna Theory*, 4th ed., §2.15–2.17 [S8];
`Ae = Gλ²/(4π)` §2.16):

```
Pr = Pt · Gt · Gr · (λ / (4πd))²
Pr[dBm] = Pt[dBm] + Gt[dBi] + Gr[dBi] − 20log10(4πd/λ)
```

**ITU-R P.525-5 (11/2024) [S2], Eqs. (5)/(6)** — free-space basic transmission loss:
`L_bf = 20log10(4πd/λ) = 32.4 + 20log10(f_MHz) + 20log10(d_km)` dB. The printed 32.4 is a
rounded constant: exact value `20log10(4π·10⁹/c) = 32.4478` (verified), so the practical
formula reads **0.0478 dB low** at any distance/frequency — worth knowing when comparing
implementations.

**Absolute-power context** (M.1225 Table 6 link-budget template [S3]): thermal noise
density **−174 dBm/Hz**, receiver noise figure 5 dB (template default), indoor antenna
gains 2 dBi, cable/connector losses 2 dB. Noise power = −174 + 10log10(B_hz) + NF.

### C.2 What Chronos should add

Current `free_space_gain(d) = 1/d` (unit at 1 m) is Friis with `λ/(4π) := 1` — i.e. a
normalized model, fine for relative path structure but with no frequency or antenna
dependence in the spreading term. Proposed:

1. **Amplitude factor** `g_fs(d) = (λ/(4πd))·sqrt(Gt·Gr)` replacing `1/d`
   (equivalently: keep `1/d` and multiply by `λ/(4π)·sqrt(GtGr)`). At 2.4 GHz this shifts
   every path by **−40.052 dB** relative to today (λ/(4π) = 0.009940302). Frequency and
   gain dependence become real: doubling f or d adds 6.0206 dB loss (verified).
2. **Opts**: `tx_gain_dbi`, `rx_gain_dbi` (default 0), and an opt-in absolute mode
   `tx_power_dbm` + `noise_figure_db` + bandwidth → received SNR per path/aggregate via the
   M.1225-style budget. Keep the normalized mode as default initially so existing scenes,
   noise defaults and BER demos don't shift under users; document the conversion.
3. Interaction note: PR #11 bakes material reflection loss into `attenuation_db`; the Friis
   factor is independent of that, but any absolute-power mode should be built after the
   #8/#11 material reconciliation the digest flags.

### C.3 Verification cases (script output)

1. FSPL at 2.4 GHz: d = 1/2/10/100 m → **40.0520 / 46.0726 / 60.0520 / 80.0520 dB**
   (exact Eq. 5); P.525 practical (32.4) gives 40.0042 etc., constant offset 0.0478 dB.
2. Link example: Pt = 20 dBm, Gt = Gr = 0 dBi, d = 10 m → **Pr = −40.0520 dBm**.
3. Scaling laws: +6.0206 dB per distance doubling; +6.0206 dB per frequency doubling at
   fixed gains (Goldsmith §2.3 example: doubling f_c requires 4× transmit power for the
   same Pr — verified numerically in the book's own example, λ=0.12 m → 0.06 m).
4. Half-wave dipole gain from Friis's own effective area: 10log10(4π·0.1305) = **2.1482 dBi**.
5. **Two-ray ground reflection** (Goldsmith §2.4, Eqs. 2.13–2.22 [S7]):
   `Pr = Pt(λ/4π)²·|√G0/d0 + R·√G1·e^{−jΔφ}/d1|²`, `Δφ ≈ 4πh_t h_r/(λd)`,
   asymptote `Pr ≈ Pt·G·h_t²h_r²/d⁴` (d⁴, wavelength-independent), critical distance
   `d_c = 4h_t h_r/λ`. Verified at h_t = h_r = 1.5 m, R = −1, unit gains, 2.4 GHz:
   **d_c = 72.0498 m**; exact vs asymptotic Pr/Pt: d=50 m → −70.28 vs −60.92 dB (9.36 dB
   gap — still in the interference region), d=100 m → −74.90 vs −72.96 dB (1.94 dB),
   d=200 m → −85.47 vs −85.00 dB (0.47 dB). Teaching point: the d⁴ law only holds for
   d ≫ d_c; inside d_c the two-ray channel oscillates (maxima at odd Δφ/π, minima at even).
   Goldsmith Example 2.2 cross-check: h_t=10, h_r=3, f=2 GHz ⇒ d_c=800 m; indoor 3×2 m ⇒ 160 m.

---

## D. Rust NIF + Elixir mirror: implementation notes

- **Algorithm choice for parity**: Boersma Horner evaluation with the exact P.526 coefficient
  table and fixed summation order; knife-edge Eq. 30/31; UTD Eqs. 90–106 with the Eq. 102
  singular limit. All operations are `+, −, ×, ÷, sqrt, cos, sin, tan, log10, exp` and
  12-term polynomials — no library special functions, no RNG, no platform-dependent
  iteration. The verify script is the Elixir-side prototype of exactly these algorithms.
- **Precision discipline**: compute physics in f64 on both sides; pack to f32 only at the
  existing boundary (gain/doppler f32, delay f64 — unchanged). Transcendentals (`log10`,
  `cos`, …) can differ by 1 ulp across libm implementations/platforms; same-host Rust and
  Erlang both call the system libm and agree in practice, but the parity contract for
  physics outputs should pin operation order and allow ~1e-9 relative tolerance on dB
  values, keeping strict bit-parity for the packing layer. (Design decision for the lock.)
- **Complex fields** (options A.4-C/D, B.2): NIF already has `Complex`; Elixir side uses
  `{re, im}` tuples as in the verify script. Add phase to the path record (or derive from
  delay inside the NIF) — one extra f64 per path, packing format version bump.
- **Fixtures**: promote the A.5/B.6/C.3 cases into the parity test suite as golden values
  (the script prints them). The digest flags that current parity fixtures are synthetic and
  Channel-generated paths are untested — these canonical cases close that gap with
  externally-anchored numbers.
- **Determinism**: statistical TDL mode (B.4) must use the existing seeded RNG approach on
  both sides (NIF `Rng`, Elixir mirror) — same seed ⇒ same taps.

## E. Prioritized recommendation

| Priority | Change | Sections | Effort | Depends on |
|---|---|---|---|---|
| 1 | Signed-v knife-edge + drop material double-count + blocking-wall leg check | A.2 fixes 1–3 | S | PR #8 merged |
| 2 | Static carrier phase per path (+ reflection phase convention) | B.2 | S | packing format decision |
| 3 | Multi-edge §5.1 power-sum diffraction | A.2 fix 4 | S | 1 |
| 4 | Friis λ/(4π)·√(GtGr) factor + gain opts (normalized default kept) | C.2 | S | — |
| 5 | M.1225 / 38.901 profile fixtures + statistical TDL mode + delay-scaling knob | B.4–B.5 | M | 2 |
| 6 | Lagrange-3 fractional delay (replace linear interp) | B.3 | S | parity fixtures |
| 7 | Absolute-power/noise mode (−174 dBm/Hz + NF) | C.2 | M | 4, #11 reconciliation |
| 8 | Complex-field screen diffraction (§5.2) then UTD (§6/KP74) | A.4 C→D | L | 2, complex path fields |

Items 1–4 fix every named quirk and add the two missing physical terms (carrier phase,
wavelength/gain) with pure real arithmetic and ITU-blessed formulas. Item 8 delivers the
roadmap's "true UTD" as a documented, analytically verified showcase — P.526 §6 supplies the
full formulation, and the n=2/R=0 equivalence case (≤ 0.034 dB) is its acceptance test.

## F. Sources

- **[S1] ITU-R P.526-16 (11/2025), "Propagation by diffraction."** In force.
  PDF: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.526-16-202511-I!!PDF-E.pdf
  (landing: https://www.itu.int/rec/R-REC-P.526-16-202511-I/en).
  Used: §2.5 isolated obstacle; §2.7 Eqs. 6–10 (Fresnel, Boersma coefficients);
  §4.1 Eqs. 26–31 (signed h, exact/approx J); §4.3 double edges; §5.1 Eqs. 71–72
  (finite-width screen); §5.2 Eqs. 75–89 (rectangular aperture/screen, Babinet);
  §6 Eqs. 90–106 (UTD finitely conducting wedge) incl. the n=2/R=0 knife-edge equivalence
  note after Eq. 106. Equations with radicals were cross-checked against rendered PDF pages
  (text extraction drops some radicals). P.526-15 (10/2019) is the edition referenced by the
  Radio Regulations 2024; knife-edge content identical for our purposes.
- **[S2] ITU-R P.525-5 (11/2024), "Calculation of free-space attenuation."**
  PDF: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.525-5-202411-I!!PDF-E.pdf
  Used: Eqs. (5)/(6) free-space basic transmission loss and the 32.4 practical constant.
- **[S3] ITU-R M.1225 (1997), "Guidelines for evaluation of radio transmission technologies
  for IMT-2000."** PDF: https://www.itu.int/dms_pubrec/itu-r/rec/m/R-REC-M.1225-0-199702-I!!PDF-E.pdf
  Used: Annex 2 §1.2.2 Tables 2–5 (TDL profiles, rms DS, ±3% delay tolerance);
  §1.3.1 Table 6 (link-budget template: −174 dBm/Hz, NF 5 dB, gains);
  Appendix 1 to Annex 2 §2.1.3 (Classic/Rice Doppler spectra, υ_max = V/λ, 3/70 km/h).
- **[S4] 3GPP TR 38.901 v16.1.0 (2020-11), "Study on channel model for frequencies from
  0.5 to 100 GHz."** ETSI PDF: https://www.etsi.org/deliver/etsi_tr/138900_138999/138901/16.01.00_60/tr_138901v160100p.pdf
  Used: §7.7.1 CDL-A…E; §7.7.2 Tables 7.7.2-1…5 (TDL-A…E, K-factors, Jakes + 0.7f_D LOS
  peak); §7.7.3 Eq. 7.7-1 + Tables 7.7.3-1/-2 (delay scaling, scenario DS); §7.7.4
  (TDL as isotropic-antenna CDL reduction).
- **[S5] R. G. Kouyoumjian and P. H. Pathak, "A uniform geometrical theory of diffraction
  for an edge in a perfectly conducting surface," Proc. IEEE 62(11):1448–1461, Nov. 1974.**
  doi: https://doi.org/10.1109/PROC.1974.9651 (IEEE, paywalled). Public abstract record:
  https://ntrs.nasa.gov/citations/19750029381 (used for the ray-fixed-coordinate /
  oblique-incidence / boundary-continuity claims). Implementable coefficient formulas taken
  from [S1] §6 and [S8] Ch. 13 instead of the paywalled text.
- **[S6] H. T. Friis, "A Note on a Simple Transmission Formula," Proc. IRE 34(5):254–256,
  May 1946.** doi: https://doi.org/10.1109/JRPROC.1946.234568. Open copy consulted:
  https://capmimo.ece.wisc.edu/capmimo_papers/friis_original_1946.pdf
  Used: Eqs. 1–6, 8–11 (effective areas, isotropic λ²/4π, dipole 0.1305λ², far-field
  d ≥ 2a²/λ, free-space-only limitation).
- **[S7] A. Goldsmith, *Wireless Communications*, Cambridge Univ. Press, 2005**
  (ISBN 9780521837163; TOC: https://assets.cambridge.org/97805218/37163/toc/9780521837163_toc.pdf).
  Author-hosted second-edition draft (Chapters 1–7, Feb 8 2020) consulted:
  https://web.stanford.edu/class/ee359/doc/WirelessComm_Chp1-7_Feb82020.pdf
  Used: §2.3 free-space example (4× power per frequency doubling); §2.4 Eqs. 2.13–2.22
  (two-ray, d_c = 4h_th_r/λ, d⁴ asymptote), Example 2.2; §3.3 (rms delay spread, coherence
  bandwidth Bc ≈ 0.2/σ_τ and 0.02/σ_τ after Lee, flat vs frequency-selective, Example 3.6,
  discrete-bin model T ≈ 1/B with MT ≥ σ_τ, Problem 4 on f_cτ ≫ 1).
- **[S8] C. A. Balanis, *Antenna Theory: Analysis and Design*, 4th ed., Wiley, 2016**
  (publisher TOC: https://catalogimages.wiley.com/images/db/pdf/9781118642061.toc.pdf):
  §2.15–2.16 equivalent areas / Ae = Gλ²/4π, §2.17 Friis transmission equation;
  §12.8 Babinet's principle; §12.10 GTD edge effects. And **C. A. Balanis, *Advanced
  Engineering Electromagnetics*, 2nd ed., Wiley, 2012**: Ch. 13 GTD/UTD
  (§13.3.2 straight edge normal incidence, §13.3.3 oblique incidence, §13.4.1 wedge
  diffraction coefficients, §13.4.2 Fresnel transition function), Ch. 14 impedance wedges.
- **[S9] ITU-R P.528-3 (02/2012), "Propagation curves for aeronautical mobile and
  radionavigation services using the VHF, UHF and SHF bands."**
  PDF: https://www.itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.528-3-201202-S!!PDF-E.pdf
  **Reviewed for scope, not used**: curve-interpolation (IF-77) basic transmission loss for
  125–15 500 MHz ground-air/air-air/satellite links at time percentages 1–95%, antenna
  heights above mean sea level, distances to 1800 km. It is an aeronautical statistical
  model, not an indoor geometric one — wrong tool for Chronos; listed because the ticket
  named it. (For short-range indoor/RLAN, ITU-R P.1411 is the relevant sibling recommendation.)

## Appendix: reproducing the numbers

```
elixir docs/research/physics-depth-verify.exs
```

Prints every table quoted above (Boersma error bound, J(v) exact/approx, UTD-vs-knife-edge
sweep, PEC comparison, finite-screen offsets, FSPL/two-ray, rms-DS recomputations, tap
binning, interpolation droop, quirk magnitudes). The script's `Fresnel`/`UTD` modules are
deliberately written as the mirror-side prototype: same coefficient tables, same operation
order proposed for the Rust NIF.
