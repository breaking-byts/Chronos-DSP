# Interactive Scene Editing — Design Lock

Status: locked · issue #20 · 2026-11-20

Posture: the intended primary use is users running Chronos-DSP on their own
laptop — single-user, capable client. A hosted server is a secondary fallback,
not the intended path. This design optimizes for a smooth local experience,
not the 512 MB shared-CPU demo. This sharpens the local-first stance of
[ADR 0001](../adr/0001-public-showcase-posture.md).

This is the settled design for interactive scene editing, transcribed from the
grilling session; it is a spec, not code. Rendering-mode rationale is recorded
in [ADR 0002](../adr/0002-interactive-editing-2d-projection.md); the frame
contract it builds on is in
[hybrid-ui.md](../architecture/hybrid-ui.md).

## Editing model

Hybrid: direct manipulation on the canvas plus a precision panel.

- Drag TX/RX nodes on the canvas.
- Drag a wall to move it whole; drag its endpoints to reshape it. A minimum
  wall-length guard prevents a wall from collapsing to zero length.
- Add/remove walls via panel buttons.
- Per-wall material picker over the 11-material `Chronos.Material` catalogue.
- TX/RX node count is FIXED for v1; add/remove nodes is deferred.

Direct manipulation teaches geometry; the panel gives precision and
accessibility.

## Rendering mode

Height-aware 2D (see [ADR 0002](../adr/0002-interactive-editing-2d-projection.md)):

- Drag is constrained to the XY plane. z is edited via a panel numeric field
  (−5..+5 m), NOT by dragging.
- Height is shown by node size/color and wall labels.
- The isometric Canvas view toggle is deferred to the #27 prototype.
- Full 3D is a future aspiration, recorded in the
  [roadmap](../plans/project-completion-roadmap.md): the vendored three.js
  r185 escape hatch per `docs/research/3d-rendering.md` (branch
  `research/3d-rendering`, issue #28), gated on WebGL2 with the existing
  Canvas2D renderer as fallback. ECharts GL is rejected.
- No new rendering dependency now.

## Drag mechanics

- Pointer-event hit-testing with a ~12 px screen radius, DPR-scaled.
- Snap-to-grid is an optional toggle, default OFF; it snaps to the grid
  spacing already drawn on the canvas.
- Drag clamps to the frame bounds plus a small margin.
- Whole-wall drag translates every vertex; endpoint drag moves one vertex,
  subject to the minimum wall-length guard.

## Event budget (client preview)

- The `SimCanvas` hook tracks the drag locally and redraws immediately: zero
  server round-trips per move.
- On release it pushes ONE event committing the new geometry; the server
  re-renders the frame.
- Sliders use debounced `phx-change`.
- A throttled ~10 Hz live-commit (paths update mid-drag) is a possible later
  enhancement, not v1.
- Designed for a capable local laptop client.

## Parameter sliders

| Parameter | Range | Default | Backend note |
|---|---|---|---|
| TX power | 0..30 dBm | 10 dBm | Requires ADDING a `tx_power` channel opt, wired server-side |
| Per-wall attenuation override | 0..40 dB | Auto (use material) | "Auto (use material)" checkbox defaults to the material's value; an explicit `wall.attenuation_db` overrides the material's reflection loss (`Chronos.Material`) |
| z height | −5..+5 m | current z | Panel numeric field, not drag |
| Wall material | 11-material catalogue | concrete (catalogue default) | Per-wall picker over `Chronos.Material` |

Keep the existing noise and speed controls. All ranges are clamped
server-side via the shared `ChronosWeb.ApiParams` validation.

## Scene save/load interplay

- A "Save scene" button (name prompt) POSTs to the existing `/api/scenes`.
- A scene picker lists `GET /api/scenes`; loading a scene loads-and-replaces
  the world.
- A dirty indicator (dot) shows when the live world differs from the last
  saved/loaded snapshot (see **Dirty state** in [GLOSSARY.md](../../GLOSSARY.md)).
- An "N/100 scenes" counter with an eviction note.
- Loading or resetting clears the undo history.
- Ephemeral, no auth ([ADR 0001](../adr/0001-public-showcase-posture.md)).
  Caps: 100 scenes / 64 KiB each / 10 MiB backstop, oldest-first-by-mtime
  eviction.

## Undo/reset

- Undo stack depth ~50, covering drag commits, slider changes, add/remove
  wall, and material changes.
- Ctrl/Cmd+Z plus an Undo button.
- Undo-only for v1; redo is deferred.
- The existing Reset reloads the current built-in scenario.
- A separate "Revert to saved" reloads the last saved/loaded snapshot.
- Loading a scene or resetting clears the undo stack.

## Export affordance

- An "Export CSV" control in the existing control bar, next to Reset.
- It opens a menu for metrics / history / samples, hitting the existing
  `/api/export/{metrics,history,samples}` endpoints with the live
  scenario/seed.
- No new backend work.

## Explicitly deferred

- Add/remove TX/RX nodes (node count fixed for v1).
- Redo.
- Isometric Canvas view toggle (the #27 prototype).
- Touch/mobile support: desktop mouse only. Pointer Events may still be used
  for mouse, but no touch-specific work, no mobile drawer, no pinch-zoom.
- Full 3D (future aspiration; see the roadmap and ADR 0002).
- Mid-drag live-commit (~10 Hz throttled).

## Implementation slices

1. Backend: add the `tx_power` channel opt (with `ChronosWeb.ApiParams`
   clamping).
2. `SimCanvas` drag editing + geometry commit events.
3. Panel sliders/pickers + add/remove walls.
4. Scene save/load UI + dirty state.
5. Undo/reset + export control.
6. The #27 prototype validates drag feel.

## References

- [ADR 0001 — Public showcase posture](../adr/0001-public-showcase-posture.md)
- [ADR 0002 — Interactive editing stays a 2D XY projection](../adr/0002-interactive-editing-2d-projection.md)
- [hybrid-ui.md — frame contract and hooks](../architecture/hybrid-ui.md)
- [project-completion-roadmap.md](../plans/project-completion-roadmap.md)
- `docs/research/3d-rendering.md` (branch `research/3d-rendering`, issue #28;
  not yet on `master`, so cited by path rather than linked)