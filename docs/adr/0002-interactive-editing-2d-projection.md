# Interactive editing stays a 2D XY projection with height cues

Status: accepted

The physics world is 3D — nodes, walls, and paths all carry z, and the
`sim_frame` contract already delivers it — but the dashboard renders a
top-down XY projection, and interactive editing (issue #20) has to stay
legible on that projection. The trade-off is teaching clarity, no new
rendering dependency, and broad browser reach versus full 3D. Alternatives
considered: full three.js 3D now, and an isometric view now. Both are deferred
per `docs/research/3d-rendering.md` (branch `research/3d-rendering`, issue
#28): the best no-build vendored three.js option (r185 minified core+module)
still costs ~750 KB raw / ~187 KB gzip, three.js has been WebGL2-only since
r163 (narrowing browser reach and forcing a fallback path), and a freely
orbitable 3D scene works against the teaching-first clarity of a planar
layout. ECharts GL is rejected for scene rendering: it is a charting
extension, not a scene renderer.

The decision: interactive editing stays a height-aware 2D XY projection.
Drag is constrained to the XY plane; z is edited via a panel numeric field
(−5..+5 m), not by dragging; height is conveyed through node size/color and
wall labels. The isometric Canvas toggle is deferred to the #27 prototype,
and full 3D is deferred as a future aspiration with the vendored three.js
r185 escape hatch (WebGL2-gated, Canvas2D fallback). No new rendering
dependency is added now. The full editing design is locked in
`docs/design/interactive-editing.md`.

## Consequences

- Drag math stays simple: hit-testing, clamping, and snapping operate in the
  existing XY screen-to-world fit; no camera or orbit state.
- Height is visible (size/color cues, wall labels, numeric field) but the
  scene is not freely orbitable.
- No frame-contract change is needed: frames already carry z on nodes, walls,
  and paths, so both editing and any later 3D mode consume the same events.
- Future full 3D goes through the vendored three.js r185 escape hatch per
  `docs/research/3d-rendering.md`, gated on WebGL2 with the existing Canvas2D
  renderer as fallback; the isometric Canvas mode is a separate follow-up
  validated by the #27 prototype.