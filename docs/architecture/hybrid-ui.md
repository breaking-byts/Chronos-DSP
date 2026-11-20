# Browser UI Architecture

The dashboard is a Phoenix LiveView page with two client hooks. It has no Node
build step, no bundler, and no CDN dependencies.

## Assets

Served by `ChronosWeb.Endpoint` from the application's `priv/static`:

- `/assets/app.js`: `SimCanvas` and `DspCharts` hooks plus LiveSocket setup.
- `/assets/app.css`: layout, palette, controls, and chart cards.
- `/assets/vendor/echarts.min.js`: vendored ECharts build (Apache-2.0; see
  `priv/static/vendor/ECHARTS-LICENSE.txt` and `README.md`).
- `/phoenix/phoenix.js`, `/live/phoenix_live_view.js`: served from the Phoenix
  and LiveView dependencies.
- `/favicon.svg`.

There is no PixiJS dependency. Earlier revisions loaded PixiJS and ECharts from
a CDN; v0.2.0 replaced the scene renderer with Canvas 2D and vendored ECharts.

## Frame flow

1. `ChronosWeb.SimLive` owns a supervised `Chronos.SimServer`.
2. On each tick it calls `SimServer.next_frame/1` and pushes the returned
   `Chronos.SimFrame` with `push_event("sim_frame", frame)`.
3. Both hooks subscribe to `sim_frame`; each keeps its own latest frame.

A frame contains:

```text
%{
  tick, time_s,
  bounds: %{min: [x, y], max: [x, y]},
  nodes: [%{id, type, pos: [x, y, z], vel: [x, y, z]}],
  walls: [%{id, vertices: [[x, y, z], ...], normal: [x, y, z], attenuation_db,
           material, loss_db}],
  paths: [%{kind: "los" | "reflection" | "diffraction" | "transmission",
            bounces, points: [[x, y, z], ...]}],
  metrics: %{ber, path_count, received_power, rx_id},
  dsp: %{constellation: [[i, q], ...], waveform: [f32, ...], spectrum: [f32, ...]}
}
```

## SimCanvas

- Finds the child `<canvas>`; the container must keep `phx-update="ignore"`.
- Uses `ResizeObserver` and caps device pixel ratio at 2.5.
- Draws on `requestAnimationFrame`; a new frame replaces the pending one.
- Fits `frame.bounds` into the element with padding, flips Y for screen
  coordinates, then draws grid, walls, paths, nodes, and a scale bar.
- LOS paths are solid cyan; reflections are dashed orange; diffracted paths
  are long-dashed violet; penetrating paths are dotted pink.
- Wall labels show the material, its effective reflection loss, and the
  wall's reference height (mean vertex z). Node size and lightness encode z
  (higher nodes are larger and lighter, lower nodes smaller and darker) while
  the hue keeps the tx/rx type readable — height-aware 2D without a new
  dependency (#35).
- Before the first frame it draws a "Waiting for the first simulation frame"
  placeholder.

## DspCharts

- Initializes four ECharts instances (constellation, waveform, spectrum, BER)
  with `animation: false`.
- Coalesces updates through `requestAnimationFrame`; only the changed series
  data is applied.
- Keeps a 120-entry BER history keyed by tick. A frame whose tick is less than
  or equal to the last tick (a reset or scenario switch) clears the history.
- Disposes charts and disconnects the observer on hook teardown.
- If ECharts fails to load, each chart container shows "Chart library failed to
  load." rather than leaving a blank panel.

## Controls

`SimLive` handles `toggle`, `step`, `reset`, `speed`, `noise`, `scenario`,
`toggle_snap`, `commit_geometry`, and the editing-panel events `set_tx_power`,
`set_wall_attenuation`, `set_wall_auto`, `set_node_z`, `set_wall_z`,
`set_wall_material`, `add_wall`, and `remove_wall`. Speed and noise values are
validated against fixed allowlists before being forwarded to `SimServer`. The
scenario handler rejects unknown ids and resets the tick counter.
`toggle_snap` flips the snap-to-grid assign (default off) and pushes
`snap_state` to the canvas hook. `commit_geometry` re-validates the dragged
geometry server-side via `Chronos.SceneEdit` (bounds clamp, minimum wall
length, optional grid snap), replaces the world through
`SimServer.update_world/2`, and re-renders through the normal `sim_frame`
flow. Panel events parse their form strings and validate through
`ChronosWeb.ApiParams` (`tx_power` 0..30 integer, attenuation override 0..40
finite, z −5..+5 finite, material id in the catalogue), then apply the edit
through `Chronos.PanelEdit` and `SimServer.update_world/2`; `set_tx_power`
goes to `SimServer.set_tx_power/2` (a render option, like noise).

## Interactive editing (design lock #20)

The full spec is [interactive-editing.md](../design/interactive-editing.md),
with the rendering-mode decision in
[ADR 0002](../adr/0002-interactive-editing-2d-projection.md). Drag editing
(slice 2, issue #34) and the editing panel (slice 3, issue #35) are
implemented; the save/load and undo slices are still pending.

- `SimCanvas` has drag editing: pointer-event hit-testing (~12 px screen
  radius, DPR-scaled) over nodes, wall endpoints, and whole walls; a
  client-side preview that redraws immediately with zero server round-trips
  per move; and ONE `commit_geometry` event pushed on release, which the
  server re-validates (`Chronos.SceneEdit`) before re-rendering the frame
  through the existing `sim_frame` flow. Drag stays in the XY plane — frames
  already carry z, and height will be edited via a panel numeric field, not
  by dragging. Desktop mouse only; touch pointers are ignored. A snap-to-grid
  toggle (default off) snaps drags to the drawn grid spacing; drags clamp to
  the frame bounds plus a 0.25 m margin, and endpoint drags keep wall edges
  above a 0.1 m minimum length. Once a world is edited, the session steps by
  node velocity instead of scenario kinematics so edits are not overwritten;
  Reset restores the pre-edit baseline and the original stepping.
- The editing panel (#35) adds a TX-power slider (0..30 dBm, default 10,
  debounced `phx-change`, wired to `SimServer.set_tx_power/2`), a per-wall
  attenuation override (0..40 dB) with an "Auto (use material)" checkbox
  (Auto = `attenuation_db: nil`, the material's reflection loss applies;
  unchecking Auto seeds the override with the material's value), a z-height
  field (−5..+5 m) per node and per wall, a per-wall picker over the
  11-material catalogue, and add/remove-wall buttons bounded by the scene
  item cap (1024). A wall's single z field edits its reference height (mean
  vertex z) by a pure z translation, keeping the wall's shape and vertical
  extent; node z edits preserve x/y. Drag never edits z. The TX/RX node count
  stays fixed. Ranges clamp server-side via `ChronosWeb.ApiParams` and
  `Chronos.PanelEdit` re-guards every commit before `SimServer.update_world/2`.
- Scene save/load uses the existing `/api/scenes` API, with a dirty indicator
  against the last saved/loaded snapshot; undo (~50 entries, cleared on
  load/reset) and an Export CSV menu over the existing `/api/export`
  endpoints round out the controls.

## Styling

`app.css` defines a dark-first palette with CSS custom properties, a responsive
two-column workspace (scene + side panel), compact stat tiles, segmented
controls, and a four-card telemetry grid. Chart colors are mirrored in the
JavaScript `COLORS` object.
