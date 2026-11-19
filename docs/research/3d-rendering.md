# Research: 3D / height-aware rendering under the no-build vendored constraint

- **Ticket:** [#28](https://github.com/breaking-byts/Chronos-DSP/issues/28) (wayfinder research)
- **Date:** 2026-11-20 · research branch `research/3d-rendering`, no code changes
- **Question:** how to render the 3D physics world (or make height visible) given:
  no frontend build step, vendored assets only, no CDN, Canvas 2D + vendored
  ECharts today, teaching-first clarity, shared-CPU 512 MB scale-to-zero demo
  hosting, heterogeneous browser clients.

## TL;DR — recommendation

**Ship height-aware 2D first (Option D), with an optional Canvas 2D
isometric/painter's-algorithm mode (Option C) as a follow-up. Do not add a
rendering dependency now.** Keep three.js (Option A) as the documented escape
hatch if free-orbit 3D becomes a hard requirement — vendored r185 minified
builds via import map, gated on WebGL 2, with the existing Canvas 2D renderer
as fallback. Reject ECharts GL (Option B) for *scene* rendering: it is a
charting extension, not a scene renderer, and it costs ~625 KB min / ~171 KB
gzip plus a WebGL requirement for semantics that fit this scene poorly.

All four options need **zero server changes**: `sim_frame` already carries
`z` on nodes, walls, and paths (§1).

## 1. Current state (repo facts)

| Fact | Source |
|---|---|
| Scene hook `SimCanvas`: Canvas 2D, `ResizeObserver`, DPR capped at 2.5, `requestAnimationFrame`, container `phx-update="ignore"`; `project([x, y])` ignores z | `priv/static/app.js` (L36–119); [hybrid-ui.md](../architecture/hybrid-ui.md) |
| Frame contract is already 3D: `nodes[].pos/vel = [x,y,z]`, `walls[].vertices = [[x,y,z],…]`, `paths[].points = [[x,y,z],…]`; `bounds` are XY-only | [hybrid-ui.md §Frame flow](../architecture/hybrid-ui.md); `lib/chronos/sim_frame.ex` |
| Server-side projection helper discards z: `Scene.project({x, y, _z}, …)` | `lib/chronos/scene.ex` L66 |
| Demo geometry has real height: orbit-scenario walls span z −1.0…+1.0 (2 m tall), TX at z 0 | `lib/chronos/scenario.ex` L103–135 |
| Known limitation: "The page renders a top-down projection; Z affects geometry and path delays but not the rendered layout." | [ARCHITECTURE.md §Known limitations](../ARCHITECTURE.md) |
| Roadmap item 6: "Optional 3D/height-aware rendering instead of the current XY projection." | `docs/plans/project-completion-roadmap.md` L71 |
| Vendored ECharts **5.6.0** (Apache-2.0): `echarts.min.js` = **1,034,102 B raw / 335,614 B gzip** (measured locally, gzip −9) | `priv/static/vendor/README.md`; local measurement |
| No Node build step, no bundler, no CDN; scripts served from `priv/static` | [ARCHITECTURE.md §Web/UI](../ARCHITECTURE.md); [hybrid-ui.md](../architecture/hybrid-ui.md) |
| Showcase posture: single-tenant public demo, ephemeral state | [ADR 0001](../adr/0001-public-showcase-posture.md) |

Scene size today is tiny: 1 TX + 1 RX, 2 walls, ≤ 3 display paths per frame
(`sim_frame.ex`). Any per-frame sort or projection over this is negligible
work on the client; the differentiators are bundle size, browser reach,
clarity, and maintenance — not raw rendering throughput.

## 2. Option A — three.js, vendored

### 2.1 Verified facts (primary sources)

- **Version/license:** latest is **0.187.0 (r187)** [2]; **MIT** — full license
  text [1] and `SPDX-License-Identifier: MIT` headers in the build files
  themselves. Vendoring requires keeping the copyright/permission notice [1].
- **Build layout matters under no-build.** Current releases ship **only
  unminified ES builds**; the minified builds were removed in **r186**
  (present in r185, absent in r186 — jsDelivr file listings [3]). The legacy
  UMD `three.min.js` (global `THREE`, plain `<script src>`) was deprecated in
  r150 and **removed in r161** [4].
- **WebGL 2 only since r163.** WebGL 1 support was deprecated in r153 and
  removed in r163 [4][5]; the `WebGLRenderer` docs state "WebGL 1 is not
  supported since r163" [6]. **r162 is the last WebGL 1-capable release** [3].
- **Sizes** (raw bytes from jsDelivr package metadata [3]; gzip measured
  locally at −9 on the exact CDN bytes; bundlephobia as cross-check [7]):

| File (release) | Raw | gzip −9 | Notes |
|---|---:|---:|---|
| `three.core.js` (r187) | 1,474,799 B | 290,019 B | core, unminified |
| `three.module.js` (r187) | 658,900 B | 129,393 B | WebGL renderer entry; imports core |
| **r187 core+module, as-is** | **2,133,699 B** | **≈419,412 B** | no upstream minified option |
| `three.core.min.js` (r185) | 385,390 B | 100,958 B | last release with upstream min builds |
| `three.module.min.js` (r185) | 365,552 B | 86,549 B | |
| **r185 core+module min** | **750,942 B** | **≈187,507 B** | best no-build vendoring today |
| `OrbitControls.js` (r185 addon) | 40,504 B | 8,440 B | optional orbit camera |
| r187 whole entry, minified by bundlephobia | 742,263 B | 185,679 B | cross-check [7]; upstream ships no such file |
| `three.module.min.js` (r162) | 678,491 B | — | only if WebGL 1 reach is required [3] |
| `three.min.js` (r128, UMD) | 603,445 B | — | legacy global-script path; 2021-era API [3] |

  (`three.cjs` in r187 is a 631 B re-export shim [3]; gzip totals are sums of
  per-file streams, accurate to within a few hundred bytes.)

### 2.2 No-build integration pattern

The official manual's build-free path is an **import map + ES module
script** [8]; the map can point at same-origin vendored paths instead of a
CDN, satisfying the no-CDN rule:

```html
<script type="importmap">
{ "imports": {
    "three": "/assets/vendor/three/three.module.min.js",
    "three/addons/": "/assets/vendor/three/addons/"
} }
</script>
```

- Import maps are Baseline "widely available", across browsers since
  **March 2023** [9] — older clients (e.g. Safari < 16.4) need the fallback.
- Addons (e.g. `OrbitControls`) are separate vendored files under
  `examples/jsm/`; the manual warns to keep **all files on one version** [8].
- **LiveView hook integration** mirrors `SimCanvas` exactly: hook on a
  container with `phx-update="ignore"` (LiveView then leaves its DOM alone,
  merging only `data-*` attributes) [10][11]; `mounted()` creates
  `WebGLRenderer`/scene/camera, `handleEvent("sim_frame", …)` updates object
  positions (frames already 3D), a rAF loop renders, `destroyed()` calls
  `renderer.dispose()` and disposes geometries/materials (three.js ships
  explicit cleanup guidance [12]). `ResizeObserver` + DPR cap carry over
  unchanged from `app.js`.
- Because `app.js` is a plain IIFE today, the three.js code would live in a
  separate `<script type="module">` file (e.g. `priv/static/scene3d.js`) that
  registers the hook before `LiveSocket` connects — still no build step.

### 2.3 WebGL fallback

three.js ships the detection helper `WebGL.isWebGL2Available()`
(`three/addons/capabilities/WebGL.js`): try
`canvas.getContext('webgl2')` behind `window.WebGL2RenderingContext`, catch →
false; plus `getWebGL2ErrorMessage()` for a user-facing notice [13]. The
natural fallback here is **the existing `SimCanvas` renderer** — keep it, and
only mount the 3D hook when WebGL 2 is available. This matches the repo's
existing degrade-cleanly posture (cf. the NIF fallback and the "Chart library
failed to load" panels).

### 2.4 Trade-offs

- **Clarity:** full orbit/zoom 3D is impressive but adds camera-navigation
  cognitive load; a teaching demo must keep the geometry readable at a
  glance. Lighting/materials can obscure the LOS/reflection story.
- **Performance:** GPU rendering is cheap for this scene *when a GPU exists*;
  on software-GL clients (VMs, old laptops, some mobile) it is worse than
  Canvas 2D. Context creation + shader compile adds first-frame latency.
  Server cost is unchanged (frames already 3D); the cost is **+≈188 KB gzip
  transfer per cold visit** (r185 min) on scale-to-zero hosting.
- **Bundle:** +750,942 B raw minimum today (r185 min), or +2.13 MB raw if
  vendoring r187 as-is; +40.5 KB for OrbitControls.
- **Maintenance:** monthly releases with breaking changes (the migration
  guide is long [4]); scene-graph sync + disposal discipline is real ongoing
  code; pinning r185 means freezing an API that no longer gets fixes.
- **No-build fit:** works (import map), but is the most machinery of the four
  options; r186+ forces either a version pin or a one-time vendoring-time
  minification step.

## 3. Option B — ECharts GL

### 3.1 Verified facts

- **Version/cadence:** latest **2.1.0**, published **2026-05-28**; previous
  2.0.9 was **2022-03-01** — a 4-year gap, then one recent release [14].
- **Compatibility with the vendored ECharts:** peer dependency
  `echarts: ^5.1.2 || ^6.0.0` [14]; README: "ECharts GL 2.x is compatible
  with ECharts 5.x" [15]. **The vendored 5.6.0 satisfies this**
  (`priv/static/vendor/README.md`).
- **No-build fit:** official script-tag usage — `echarts.min.js` then
  `echarts-gl.min.js` [15]. The dist is UMD with **only `echarts` external**;
  claygl and zrender are bundled inside [16]. One more vendored file + one
  more `<script>` tag; no import map needed.
- **Size:** `dist/echarts-gl.min.js` = **639,846 B raw / 174,754 B gzip**
  (jsDelivr metadata [17]; gzip measured locally on the exact CDN bytes).
  bundlephobia cross-check: 626,965 B min / 171,643 B gzip [18].
- **License — inconsistency to flag:** the repo `LICENSE` is
  **BSD-3-Clause** (Baidu, 2017) [19] and the README says "BSD license" [15],
  but the **published `package.json` and npm metadata declare `MIT`** [20].
  Both are permissive and vendoring-compatible, but the vendor README must
  record the discrepancy and ship the actual texts. The dist also bundles
  **claygl (BSD-2-Clause)** [21], **zrender (BSD-3-Clause)** [22], and
  TypeScript helper code under **Apache-2.0** (the dist's extracted
  `LICENSE.txt` is the Microsoft/tslib notice) [23].
- **WebGL requirement:** rendering goes through claygl, which creates a
  **WebGL 1** context (`getContext('webgl') || 'experimental-webgl'`) [24] —
  broader device reach than three r163+, but still no GPU-less fallback, and
  ECharts GL offers no Canvas-2D mode for the 3D series.

### 3.2 Fit for this scene

ECharts GL provides `scatter3D`, `line3D`, `lines3D`, `bar3D`, `surface`,
`grid3D`, globe, etc. [15] — **chart types on 3D axes, not scene primitives**.
Nodes map fine to `scatter3D` and paths to `lines3D`, but there is **no
first-class representation for attenuating wall polygons**; walls would need
`surface`/custom-series contortions, and the existing palette/scale-bar/
placeholder conventions would be re-implemented inside ECharts options.
Per-tick `setOption` on 3D series re-runs chart layout — heavier than the
current direct Canvas 2D draw, though `animation: false` (already the repo
convention) helps.

### 3.3 Trade-offs

- **Clarity:** axis-box 3D scatter reads as "a chart", not "a room with
  walls"; orbit interaction exists but the teaching narrative (LOS vs
  reflection, attenuation) is harder to overlay than in the hand-rolled canvas.
- **Performance:** WebGL required; per-frame chart-option diffing overhead;
  +≈171 KB gzip per cold visit on top of the existing ≈328 KB ECharts.
- **Maintenance:** version coupling to ECharts via peer range; 4-year release
  gap then a single 2026 release [14] — bus-factor and cadence risk; license
  metadata ambiguity adds vendor-bookkeeping work.
- **Verdict:** reject for the scene. Reconsider only if **3D telemetry
  charts** (e.g. a spectrum surface) are ever wanted — that is its actual
  sweet spot, and it would drop into the existing vendored ECharts cleanly.

## 4. Option C — pure Canvas 2D 3D projection (painter's algorithm)

### 4.1 Technique

- **Painter's algorithm / list-priority rendering:** sort primitives by
  depth and paint far-to-near so nearer overdraws farther. This is the
  classic "list-priority" class of hidden-surface algorithms (Newell,
  Schumacker) characterized in Sutherland, Sproull & Schumacker,
  *A Characterization of Ten Hidden-Surface Algorithms*, ACM Computing
  Surveys 6(1):1–55, 1974, DOI [10.1145/356625.356626][25].
- **Known failure modes:** cyclic overlaps and intersecting polygons break a
  pure depth sort and require splitting [25]. This scene is benign: a handful
  of convex, mostly disjoint primitives (2 walls, 2 node markers, ≤ 3
  polylines). Sorting by centroid depth with a stable tie-break is adequate;
  walls can be split into per-face quads if a future scenario interleaves
  geometry. Cost is O(n log n) on n ≈ 10 — microseconds.
- **Isometric/axonometric projection:** a fixed-angle parallel projection —
  a 2×3 linear map, no perspective divide, parallel lines stay parallel,
  equal lengths stay comparable. E.g. screen = `(x·cos30° − y·cos30°,
  x·sin30° + y·sin30° − z·k)`; this is the standard axonometric construction
  (orthographic camera in graphics texts; cf. three.js's own
  `OrthographicCamera` documentation for the parallel-projection model [26]).
  A slow auto-rotation or drag-to-rotate is just a changing angle in the same
  map — no matrix library needed.
- Everything else (grid, scale bar, dashed reflections, colors, placeholder)
  is reused from `SimCanvas` verbatim.

### 4.2 Trade-offs

- **Clarity:** isometric reads as "3D" instantly and keeps parallel
  geometry honest; but depth ambiguity is inherent (no occlusion cues beyond
  paint order), and rotating views can confuse the top-down mental model the
  lessons currently build. Best offered as a **toggle**, not the default.
- **Performance:** identical cost class to today's renderer; no GPU, no
  context creation, no shader compile. Works on every client that runs the
  current dashboard.
- **Bundle:** **+0 bytes.** No new vendored asset, no license file.
- **Maintenance:** ~150–250 lines inside the existing `app.js` renderer;
  the projection math is testable in isolation (mirror `Chronos.Scene`'s
  helper-test convention). No upstream version churn.
- **No-build fit:** perfect — it is the existing architecture.

## 5. Option D — hybrid: top-down 2D + height encoding (recommended default)

Keep the top-down XY view as the primary teaching view (it matches bounds,
scale bar, and the existing lesson flow) and make **z visible through
redundant 2D cues**:

1. **Stems/drop-lines:** a thin vertical tick from each node's ground
   position plus a ground marker; node drawn at `y_screen − z·k` with a
   connector to its XY footprint. Height becomes position — the most
   accurate visual channel for magnitude judgments (channel-effectiveness
   ranking: position > length > angle/slope > area > color luminance;
   Munzner, *Visualization Analysis and Design*, CRC Press, 2014 [27]).
2. **z labels:** small `z=+0.8 m` annotations on nodes (text is already
   drawn by the hook).
3. **Wall height cue:** draw each wall's top edge offset by its z-span
   (walls already carry z −1…+1 vertices) with a light fill between bottom
   and top edges — an extrusion hint without leaving 2D.
4. **Ground shadow/ellipse** under elevated nodes; optional luminance ramp
   for path height.
5. Optional small **side-elevation inset** (X–Z or Y–Z strip) when a scenario
   has meaningful altitude spread.

All cues are derivable client-side from the existing frame; `bounds` stay
XY (z-range computed from frame contents, or added to `bounds` later as a
non-breaking server extension).

**Trade-offs:** clarity stays teaching-first (no camera navigation, no
occlusion ambiguity, palette unchanged); performance identical to today;
**+0 bytes**; maintenance is a few dozen lines in `app.js`; universal browser
support; no fallback path needed. Limitation: it is height-*aware*, not
true 3D — no orbiting, and large z-spans compress into the same viewport.
That is acceptable for the roadmap's "optional 3D/height-aware" wording and
can be upgraded with Option C's toggle later.

## 6. Comparison

| Criterion | A: three.js | B: ECharts GL | C: Canvas 2D iso | D: hybrid 2D+height |
|---|---|---|---|---|
| Added bundle (gzip) | ≈188 KB (r185 min) / ≈410 KB (r187 as-is) | ≈171 KB | **0** | **0** |
| Browser reach | WebGL 2 + import maps (≈2023+) | WebGL 1 + existing ECharts | universal | universal |
| Fallback needed | yes (keep SimCanvas) | yes (no 2D mode for 3D series) | none | none |
| Scene semantics (walls/paths) | full freedom | poor fit (chart types only) | full freedom | full freedom |
| Teaching clarity | high wow, camera load | chart-like, axis box | good, depth ambiguity | best continuity with lessons |
| Client perf risk | software-GL clients | software-GL + setOption churn | negligible | negligible |
| Server cost | unchanged | unchanged | unchanged | unchanged |
| Maintenance | version churn + disposal + sync | peer coupling + slow cadence + license ambiguity | ~200 LOC, no deps | ~50 LOC, no deps |
| No-build fit | import map + module file | one script tag | native | native |
| License | MIT, clean | BSD/MIT metadata conflict + 3 bundled licenses | none | none |

## 7. Recommendation and sequencing

1. **Now — Option D (hybrid height cues)** in `SimCanvas`: stems, z labels,
   wall-top extrusion hint. Zero dependencies, zero bundle, zero server
   change; directly closes the "Z affects geometry but not the rendered
   layout" limitation for the common case.
2. **Next — Option C as an optional view toggle** ("Top-down / Isometric")
   using painter's-algorithm depth sort in the same hook. Still zero
   dependencies; gives genuine 3D perception for the showcase without
   committing to a GPU stack.
3. **Only if free-orbit 3D becomes a requirement — Option A**, vendoring
   **r185** `three.core.min.js` + `three.module.min.js` (+ `OrbitControls.js`)
   with license texts, import map to same-origin paths, a module-script hook
   per §2.2, `WebGL.isWebGL2Available()` gate and `SimCanvas` fallback per
   §2.3. If a newer release is required, either vendor unminified r187
   (+≈410 KB gzip) or minify once at vendoring time (a one-off asset-prep
   step, not a runtime build) — record whichever choice in
   `priv/static/vendor/README.md`.
4. **Do not adopt Option B for the scene.** Keep it on the shelf for 3D
   telemetry charts only.

What would change this recommendation: a product requirement for interactive
orbit/zoom or photoreal materials (→ A), scenarios with dense interleaved
geometry that break depth sorting (→ A, or face-splitting in C), or a desire
for 3D chart panels (→ B).

## 8. Measurement method

- Raw sizes: jsDelivr package file listings (exact published bytes) [3][17],
  cross-checked against locally measured vendored ECharts.
- gzip: `gzip −9` on the exact CDN-downloaded files (three r187/r185 builds,
  OrbitControls, echarts-gl dist) and on the local vendored
  `echarts.min.js`. Sum-of-streams totals noted where applicable.
- bundlephobia API used only as a cross-check for minified-equivalent sizes
  [7][18]; it minifies with its own pipeline, which is why its r187 number
  (742,263 B) differs slightly from upstream r185 min builds (750,942 B).
- All library facts traced to first-party sources: license texts, npm
  registry metadata, upstream READMEs/webpack config/source, official docs
  and migration guide. Retrieved 2026-11-20.

## 9. Sources

Repo (this branch): `priv/static/app.js`; `priv/static/vendor/README.md`;
`lib/chronos/sim_frame.ex`; `lib/chronos/scene.ex`; `lib/chronos/scenario.ex`;
`docs/ARCHITECTURE.md`; `docs/architecture/hybrid-ui.md`;
`docs/plans/project-completion-roadmap.md`; `docs/adr/0001-public-showcase-posture.md`.

1. three.js LICENSE (MIT) — https://raw.githubusercontent.com/mrdoob/three.js/dev/LICENSE
2. npm registry, `three` latest (0.187.0) — https://registry.npmjs.org/three/latest
3. jsDelivr file listings (sizes): https://data.jsdelivr.com/v1/package/npm/three@0.187.0/flat · …@0.186.0/flat · …@0.185.0/flat · …@0.162.0/flat · …@0.128.0/flat
4. three.js Migration Guide (r150 UMD deprecation; r161 UMD removal; r153/r163 WebGL 1) — https://github.com/mrdoob/three.js/wiki/Migration-Guide
5. three.js r163 release notes ("Remove WebGL 1 support") — https://github.com/mrdoob/three.js/releases/tag/r163
6. `WebGLRenderer` docs ("WebGL 1 is not supported since r163") — https://threejs.org/docs/pages/WebGLRenderer.html.md
7. bundlephobia API, three@0.187.0 — https://bundlephobia.com/api/size?package=three@0.187.0
8. three.js manual, *Installation* (import-map / no-build path; same-version rule) — https://threejs.org/manual/#installation (source: https://raw.githubusercontent.com/mrdoob/three.js/dev/manual/pages/installation.html)
9. MDN, `<script type="importmap">` (Baseline widely available since March 2023) — https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script/type/importmap
10. Phoenix LiveView v1.2.13, *JavaScript interoperability* (hooks lifecycle, `handleEvent`) — https://hexdocs.pm/phoenix_live_view/js-interop.html
11. Phoenix LiveView v1.2.13, *Bindings* §DOM patching (`phx-update="ignore"`) — https://hexdocs.pm/phoenix_live_view/bindings.html#dom-patching
12. three.js manual, *Cleanup* / *How to dispose of objects* — https://raw.githubusercontent.com/mrdoob/three.js/dev/manual/pages/cleanup.html · https://raw.githubusercontent.com/mrdoob/three.js/dev/manual/pages/how-to-dispose-of-objects.html
13. three.js `WebGL.js` capability helper (r187 source) — https://cdn.jsdelivr.net/npm/three@0.187.0/examples/jsm/capabilities/WebGL.js
14. npm registry, `echarts-gl` (2.1.0; peer deps; publish times 2.0.9 = 2022-03-01, 2.1.0 = 2026-05-28) — https://registry.npmjs.org/echarts-gl/latest · https://registry.npmjs.org/echarts-gl
15. echarts-gl README (script include; 2.x ↔ ECharts 5.x; BSD) — https://raw.githubusercontent.com/ecomfe/echarts-gl/master/README.md
16. echarts-gl `webpack.config.js` (UMD; only `echarts` external) — https://raw.githubusercontent.com/ecomfe/echarts-gl/master/webpack.config.js
17. jsDelivr listing, echarts-gl@2.1.0 — https://data.jsdelivr.com/v1/package/npm/echarts-gl@2.1.0/flat
18. bundlephobia API, echarts-gl@2.1.0 — https://bundlephobia.com/api/size?package=echarts-gl@2.1.0
19. echarts-gl LICENSE (BSD-3-Clause) — https://raw.githubusercontent.com/ecomfe/echarts-gl/master/LICENSE
20. echarts-gl published package.json (`"license": "MIT"`) — https://cdn.jsdelivr.net/npm/echarts-gl@2.1.0/package.json
21. claygl LICENSE (BSD-2-Clause) — https://raw.githubusercontent.com/pissang/claygl/master/LICENSE
22. zrender LICENSE (BSD-3-Clause) — https://raw.githubusercontent.com/ecomfe/zrender/master/LICENSE
23. echarts-gl dist license extract (Apache-2.0 tslib notice) — https://cdn.jsdelivr.net/npm/echarts-gl@2.1.0/dist/echarts-gl.min.js.LICENSE.txt
24. claygl `Renderer.js` (WebGL 1 context creation) — https://raw.githubusercontent.com/pissang/claygl/master/src/Renderer.js
25. Sutherland, Sproull, Schumacker (1974), *A Characterization of Ten Hidden-Surface Algorithms*, ACM Comput. Surv. 6(1):1–55 — https://doi.org/10.1145/356625.356626 (PDF: https://web.archive.org/web/20160103063614if_/http:/design.osu.edu/carlson/history/PDFs/ten-hidden-surface.pdf)
26. three.js `OrthographicCamera` docs (parallel projection) — https://threejs.org/docs/pages/OrthographicCamera.html.md
27. Tamara Munzner, *Visualization Analysis and Design*, CRC Press, 2014 (visual-channel effectiveness ranking; design reference, not fetched).
