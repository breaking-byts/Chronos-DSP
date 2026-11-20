(() => {
  "use strict";

  const COLORS = {
    background: "#0b0f14",
    grid: "rgba(148, 163, 184, 0.09)",
    gridStrong: "rgba(148, 163, 184, 0.18)",
    wallFill: "rgba(148, 163, 184, 0.22)",
    wallStroke: "rgba(203, 213, 225, 0.85)",
    los: "#22d3ee",
    reflection: "#fb923c",
    diffraction: "#a78bfa",
    transmission: "#f472b6",
    tx: "#22d3ee",
    rx: "#fb923c",
    text: "#cbd5e1",
    muted: "#64748b",
    panel: "#0f172a"
  };

  const clamp = (value, min, max) => Math.min(Math.max(value, min), max);

  function niceStep(span, scale, targetPx) {
    const raw = Math.max(targetPx / Math.max(scale, 1e-6), 1e-6);
    const power = Math.pow(10, Math.floor(Math.log10(raw)));
    const candidates = [1, 2, 5, 10].map((multiplier) => multiplier * power);
    return candidates.find((candidate) => candidate >= raw) || 10 * power;
  }

  function formatNumber(value) {
    if (value === null || value === undefined || Number.isNaN(Number(value))) return "—";
    const number = Number(value);
    if (Math.abs(number) >= 1000) return number.toFixed(0);
    if (Math.abs(number) >= 10) return number.toFixed(1);
    return number.toFixed(2);
  }

  // Drag editing (#34). These constants mirror Chronos.SceneEdit server-side.
  // Hit radius is in CSS pixels; the canvas transform scales by DPR, so the
  // effective device-pixel radius is HIT_RADIUS_PX * dpr (DPR-scaled).
  const HIT_RADIUS_PX = 12;
  const DRAG_BOUNDS_MARGIN = 0.25;
  const MIN_WALL_EDGE = 0.1;

  function dist2(ax, ay, bx, by) {
    const dx = ax - bx;
    const dy = ay - by;
    return dx * dx + dy * dy;
  }

  function pointSegmentDistance(px, py, ax, ay, bx, by) {
    const abx = bx - ax;
    const aby = by - ay;
    const len2 = abx * abx + aby * aby;
    const t = len2 > 0 ? clamp(((px - ax) * abx + (py - ay) * aby) / len2, 0, 1) : 0;
    return Math.sqrt(dist2(px, py, ax + abx * t, ay + aby * t));
  }

  function snapValue(value, step) {
    return Math.round(value / step) * step;
  }

  function clampAxis(value, lo, hi) {
    // lo > hi means the entity is wider than the clamp range; hold it still.
    return lo > hi ? 0 : clamp(value, lo, hi);
  }

  // Push a moved wall vertex away from its cyclic neighbours so no edge
  // collapses below MIN_WALL_EDGE. `vertices` are [x, y, z] arrays.
  function guardWallVertex(x, y, vertices, index) {
    const count = vertices.length;
    if (count < 2) return [x, y];
    const neighbours = [(index - 1 + count) % count, (index + 1) % count];
    neighbours.forEach((neighbour) => {
      const ax = vertices[neighbour][0];
      const ay = vertices[neighbour][1];
      let dx = x - ax;
      let dy = y - ay;
      let distance = Math.hypot(dx, dy);
      if (distance < MIN_WALL_EDGE) {
        if (distance < 1e-9) {
          dx = 1;
          dy = 0;
          distance = 1;
        }
        x = ax + (dx / distance) * MIN_WALL_EDGE;
        y = ay + (dy / distance) * MIN_WALL_EDGE;
      }
    });
    return [x, y];
  }

  const SimCanvas = {
    mounted() {
      this.canvas = this.el.querySelector("canvas");
      this.ctx = this.canvas ? this.canvas.getContext("2d") : null;
      this.frame = null;
      this.raf = null;
      this.width = 1;
      this.height = 1;
      this.dpr = 1;
      this.view = null;
      this.drag = null;
      this.snap = this.el.dataset.snap === "true";

      this.scheduleDraw = this.scheduleDraw.bind(this);
      this.onResize = this.onResize.bind(this);
      this.onPointerDown = this.onPointerDown.bind(this);
      this.onPointerMove = this.onPointerMove.bind(this);
      this.onPointerUp = this.onPointerUp.bind(this);
      this.onPointerCancel = this.onPointerCancel.bind(this);
      this.observer = new ResizeObserver(this.onResize);
      this.observer.observe(this.el);

      this.handleEvent("sim_frame", (frame) => {
        this.frame = frame;
        this.scheduleDraw();
      });

      this.handleEvent("snap_state", ({ enabled }) => {
        this.snap = Boolean(enabled);
      });

      if (this.canvas) {
        // Desktop mouse only (#34): touch/pen pointers are ignored.
        this.canvas.addEventListener("pointerdown", this.onPointerDown);
        this.canvas.addEventListener("pointermove", this.onPointerMove);
        this.canvas.addEventListener("pointerup", this.onPointerUp);
        this.canvas.addEventListener("pointercancel", this.onPointerCancel);
      }

      this.onResize();
    },

    onResize() {
      if (!this.canvas) return;
      // Use the content box (clientWidth/Height) so the container's border and
      // padding do not feed back into the canvas size. The stylesheet keeps the
      // canvas at 100% x 100%, so no inline sizing is needed.
      const dpr = clamp(window.devicePixelRatio || 1, 1, 2.5);
      const width = Math.max(1, Math.round(this.el.clientWidth));
      const height = Math.max(1, Math.round(this.el.clientHeight));
      if (width === this.width && height === this.height && dpr === this.dpr) {
        this.scheduleDraw();
        return;
      }
      this.width = width;
      this.height = height;
      this.dpr = dpr;
      this.canvas.width = Math.round(width * dpr);
      this.canvas.height = Math.round(height * dpr);
      this.scheduleDraw();
    },

    scheduleDraw() {
      if (this.raf) return;
      this.raf = requestAnimationFrame(() => {
        this.raf = null;
        this.draw();
      });
    },

    draw() {
      const ctx = this.ctx;
      if (!ctx) return;

      const { width: w, height: h, dpr } = this;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      ctx.fillStyle = COLORS.background;
      ctx.fillRect(0, 0, w, h);

      const frame = this.frame;

      if (!frame) {
        this.view = null;
        this.drawPlaceholder(ctx, w, h, "Waiting for the first simulation frame…");
        return;
      }

      const view = this.computeView(frame, w, h);
      this.view = view;

      // While dragging, overlay the local preview on the latest frame. No
      // server round-trip happens per move; paths stay stale until release.
      let nodes = frame.nodes || [];
      let walls = frame.walls || [];
      const preview = this.drag && this.drag.preview;
      if (preview) {
        if (preview.kind === "node") {
          nodes = nodes.map((node) =>
            node.id === preview.id
              ? { ...node, pos: [preview.pos[0], preview.pos[1], node.pos[2]] }
              : node
          );
        } else {
          walls = walls.map((wall) =>
            wall.id === preview.id ? { ...wall, vertices: preview.vertices } : wall
          );
        }
      }

      this.drawGrid(ctx, { w, h, ...view });
      this.drawWalls(ctx, walls, view.project);
      this.drawPaths(ctx, frame.paths || [], view.project);
      this.drawNodes(ctx, nodes, view.project);
      this.drawScaleBar(ctx, { w, h, ...view });
    },

    // Shared world<->screen transform, also used for hit-testing and drags.
    computeView(frame, w, h) {
      const bounds = frame.bounds || { min: [-5, -5], max: [5, 5] };
      const minX = Number(bounds.min[0]);
      const minY = Number(bounds.min[1]);
      const maxX = Number(bounds.max[0]);
      const maxY = Number(bounds.max[1]);
      const spanX = Math.max(maxX - minX, 1e-6);
      const spanY = Math.max(maxY - minY, 1e-6);
      const pad = Math.min(32, Math.max(16, Math.min(w, h) * 0.05));
      const scale = Math.min((w - pad * 2) / spanX, (h - pad * 2) / spanY);
      const originX = (w - spanX * scale) / 2;
      const originY = (h - spanY * scale) / 2;

      const project = ([x, y]) => [
        originX + (Number(x) - minX) * scale,
        h - originY - (Number(y) - minY) * scale
      ];
      const unproject = (px, py) => [
        minX + (px - originX) / scale,
        minY + (h - originY - py) / scale
      ];
      // Same spacing the grid is drawn with, so snapping lands on grid lines.
      const gridStep = niceStep(Math.max(spanX, spanY), scale, 56);

      return { bounds, minX, minY, maxX, maxY, scale, project, unproject, gridStep };
    },

    drawPlaceholder(ctx, w, h, message) {
      ctx.fillStyle = COLORS.muted;
      ctx.font = "500 13px ui-sans-serif, system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(message, w / 2, h / 2);
    },

    drawGrid(ctx, { w, h, minX, minY, maxX, maxY, scale, project }) {
      const step = niceStep(Math.max(maxX - minX, maxY - minY), scale, 56);
      const startX = Math.ceil(minX / step) * step;
      const startY = Math.ceil(minY / step) * step;

      ctx.save();
      ctx.lineWidth = 1;
      ctx.strokeStyle = COLORS.grid;

      for (let x = startX; x <= maxX + step * 0.001; x += step) {
        const [px] = project([x, minY]);
        ctx.beginPath();
        ctx.moveTo(px, 0);
        ctx.lineTo(px, h);
        ctx.stroke();
      }

      for (let y = startY; y <= maxY + step * 0.001; y += step) {
        const [, py] = project([minX, y]);
        ctx.beginPath();
        ctx.moveTo(0, py);
        ctx.lineTo(w, py);
        ctx.stroke();
      }

      // Axis lines at the world origin when it is visible.
      ctx.strokeStyle = COLORS.gridStrong;
      if (minX <= 0 && maxX >= 0) {
        const [px] = project([0, minY]);
        ctx.beginPath();
        ctx.moveTo(px, 0);
        ctx.lineTo(px, h);
        ctx.stroke();
      }
      if (minY <= 0 && maxY >= 0) {
        const [, py] = project([minX, 0]);
        ctx.beginPath();
        ctx.moveTo(0, py);
        ctx.lineTo(w, py);
        ctx.stroke();
      }
      ctx.restore();
    },

    drawWalls(ctx, walls, project) {
      ctx.save();
      ctx.shadowColor = "rgba(148, 163, 184, 0.35)";
      ctx.shadowBlur = 8;

      walls.forEach((wall) => {
        const vertices = (wall.vertices || []).map(project);
        if (vertices.length < 2) return;

        ctx.beginPath();
        ctx.moveTo(vertices[0][0], vertices[0][1]);
        vertices.slice(1).forEach(([x, y]) => ctx.lineTo(x, y));
        ctx.closePath();
        ctx.fillStyle = COLORS.wallFill;
        ctx.fill();
        ctx.lineWidth = 3;
        ctx.strokeStyle = COLORS.wallStroke;
        ctx.stroke();

        const loss = wall.loss_db ?? wall.attenuation_db;
        if (vertices.length >= 2 && loss) {
          const [x, y] = vertices[0];
          const material = wall.material ? `${wall.material} ` : "";
          ctx.fillStyle = COLORS.muted;
          ctx.font = "500 10px ui-monospace, SFMono-Regular, monospace";
          ctx.fillText(`${material}${loss} dB`, x + 4, y - 6);
        }
      });

      ctx.restore();
    },

    drawPaths(ctx, paths, project) {
      ctx.save();
      ctx.lineCap = "round";
      ctx.lineJoin = "round";

      paths.forEach((path) => {
        const points = (path.points || []).map(project);
        if (points.length < 2) return;

        const isReflection = path.kind === "reflection";
        const isDiffraction = path.kind === "diffraction";
        const isTransmission = path.kind === "transmission";
        ctx.beginPath();
        ctx.moveTo(points[0][0], points[0][1]);
        points.slice(1).forEach(([x, y]) => ctx.lineTo(x, y));

        if (isReflection) {
          ctx.setLineDash([5, 4]);
          ctx.strokeStyle = COLORS.reflection;
          ctx.lineWidth = 1.4;
          ctx.globalAlpha = 0.85;
        } else if (isDiffraction) {
          ctx.setLineDash([8, 3]);
          ctx.strokeStyle = COLORS.diffraction;
          ctx.lineWidth = 1.4;
          ctx.globalAlpha = 0.85;
        } else if (isTransmission) {
          ctx.setLineDash([2, 3]);
          ctx.strokeStyle = COLORS.transmission;
          ctx.lineWidth = 1.6;
          ctx.globalAlpha = 0.9;
        } else {
          ctx.setLineDash([]);
          ctx.strokeStyle = COLORS.los;
          ctx.lineWidth = 1.8;
          ctx.globalAlpha = 0.95;
        }

        ctx.stroke();
        ctx.setLineDash([]);
        ctx.globalAlpha = 1;
      });

      ctx.restore();
    },

    drawNodes(ctx, nodes, project) {
      ctx.save();

      nodes.forEach((node) => {
        if (!node.pos) return;
        const [x, y] = project(node.pos);
        const color = node.type === "tx" ? COLORS.tx : node.type === "rx" ? COLORS.rx : COLORS.text;
        const radius = 6;

        ctx.beginPath();
        ctx.arc(x, y, radius + 3, 0, Math.PI * 2);
        ctx.fillStyle = `${color}22`;
        ctx.fill();

        ctx.beginPath();
        ctx.arc(x, y, radius, 0, Math.PI * 2);
        ctx.fillStyle = color;
        ctx.fill();
        ctx.lineWidth = 1.5;
        ctx.strokeStyle = COLORS.background;
        ctx.stroke();

        ctx.fillStyle = COLORS.text;
        ctx.font = "600 11px ui-monospace, SFMono-Regular, monospace";
        ctx.textAlign = "left";
        ctx.textBaseline = "middle";
        ctx.fillText(node.id, x + radius + 7, y);
      });

      ctx.restore();
    },

    drawScaleBar(ctx, { w, h, scale, minX, minY, maxX, maxY }) {
      const step = niceStep(Math.max(maxX - minX, maxY - minY), scale, 64);
      const length = step * scale;
      const x = 18;
      const y = h - 20;

      ctx.save();
      ctx.strokeStyle = COLORS.text;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(x, y);
      ctx.lineTo(x + length, y);
      ctx.stroke();

      ctx.beginPath();
      ctx.moveTo(x, y - 4);
      ctx.lineTo(x, y + 4);
      ctx.moveTo(x + length, y - 4);
      ctx.lineTo(x + length, y + 4);
      ctx.stroke();

      ctx.fillStyle = COLORS.text;
      ctx.font = "500 10px ui-monospace, SFMono-Regular, monospace";
      ctx.textAlign = "left";
      ctx.textBaseline = "bottom";
      ctx.fillText(`${formatNumber(step)} m`, x, y - 7);
      ctx.restore();
    },

    // --- Drag editing (#34): local preview, one commit on release ---------

    pointerPos(event) {
      const rect = this.canvas.getBoundingClientRect();
      return [event.clientX - rect.left, event.clientY - rect.top];
    },

    // Nearest node, then wall endpoint, then whole wall, within the hit
    // radius (CSS px; DPR-scaled through the canvas transform).
    hitTest(px, py) {
      const view = this.view;
      const frame = this.frame;
      if (!view || !frame) return null;
      const radius2 = HIT_RADIUS_PX * HIT_RADIUS_PX;

      let best = null;
      let bestD2 = radius2;
      (frame.nodes || []).forEach((node) => {
        if (!node.pos) return;
        const [x, y] = view.project(node.pos);
        const d2 = dist2(px, py, x, y);
        if (d2 <= bestD2) {
          bestD2 = d2;
          best = { kind: "node", id: node.id };
        }
      });
      if (best) return best;

      best = null;
      bestD2 = radius2;
      (frame.walls || []).forEach((wall) => {
        (wall.vertices || []).forEach((vertex, index) => {
          const [x, y] = view.project(vertex);
          const d2 = dist2(px, py, x, y);
          if (d2 <= bestD2) {
            bestD2 = d2;
            best = { kind: "wall_vertex", id: wall.id, index };
          }
        });
      });
      if (best) return best;

      let bestDistance = HIT_RADIUS_PX;
      (frame.walls || []).forEach((wall) => {
        const points = (wall.vertices || []).map(view.project);
        if (points.length < 2) return;
        for (let i = 0; i < points.length; i += 1) {
          const a = points[i];
          const b = points[(i + 1) % points.length];
          const distance = pointSegmentDistance(px, py, a[0], a[1], b[0], b[1]);
          if (distance <= bestDistance) {
            bestDistance = distance;
            best = { kind: "wall", id: wall.id };
          }
        }
      });
      return best;
    },

    onPointerDown(event) {
      if (event.pointerType !== "mouse" || event.button !== 0) return;
      if (!this.frame || !this.view || this.drag) return;
      const [px, py] = this.pointerPos(event);
      const target = this.hitTest(px, py);
      if (!target) return;

      const [wx, wy] = this.view.unproject(px, py);
      const drag = { target, preview: null };

      if (target.kind === "node") {
        const node = (this.frame.nodes || []).find((n) => n.id === target.id);
        if (!node || !node.pos) return;
        // Grab offset keeps the node from jumping to the pointer.
        drag.offset = [node.pos[0] - wx, node.pos[1] - wy];
      } else {
        const wall = (this.frame.walls || []).find((w) => w.id === target.id);
        if (!wall || !wall.vertices || wall.vertices.length < 2) return;
        drag.wall = wall;
        if (target.kind === "wall_vertex") {
          const vertex = wall.vertices[target.index];
          drag.offset = [vertex[0] - wx, vertex[1] - wy];
        } else {
          drag.startWorld = [wx, wy];
          drag.startXY = wall.vertices.map((v) => [v[0], v[1]]);
        }
      }

      this.drag = drag;
      try {
        this.canvas.setPointerCapture(event.pointerId);
      } catch (_error) {
        // Capture can fail for synthetic or already-released pointers; the
        // canvas listeners still receive the drag events.
      }
      this.canvas.style.cursor = "grabbing";
      event.preventDefault();
    },

    onPointerMove(event) {
      const [px, py] = this.pointerPos(event);

      if (!this.drag) {
        // Hover affordance only; no state changes, no server traffic.
        if (this.canvas && event.pointerType === "mouse") {
          this.canvas.style.cursor = this.hitTest(px, py) ? "grab" : "";
        }
        return;
      }

      const view = this.view;
      if (!view) return;
      const [wx, wy] = view.unproject(px, py);
      const { target } = this.drag;
      const bounds = view.bounds;
      const snap = this.snap && view.gridStep > 0 ? view.gridStep : null;
      let preview = null;

      if (target.kind === "node") {
        let x = wx + this.drag.offset[0];
        let y = wy + this.drag.offset[1];
        if (snap) {
          x = snapValue(x, snap);
          y = snapValue(y, snap);
        }
        preview = {
          kind: "node",
          id: target.id,
          pos: [
            clamp(x, bounds.min[0] - DRAG_BOUNDS_MARGIN, bounds.max[0] + DRAG_BOUNDS_MARGIN),
            clamp(y, bounds.min[1] - DRAG_BOUNDS_MARGIN, bounds.max[1] + DRAG_BOUNDS_MARGIN)
          ]
        };
      } else if (target.kind === "wall_vertex") {
        let x = wx + this.drag.offset[0];
        let y = wy + this.drag.offset[1];
        if (snap) {
          x = snapValue(x, snap);
          y = snapValue(y, snap);
        }
        x = clamp(x, bounds.min[0] - DRAG_BOUNDS_MARGIN, bounds.max[0] + DRAG_BOUNDS_MARGIN);
        y = clamp(y, bounds.min[1] - DRAG_BOUNDS_MARGIN, bounds.max[1] + DRAG_BOUNDS_MARGIN);
        [x, y] = guardWallVertex(x, y, this.drag.wall.vertices, target.index);
        preview = {
          kind: "wall_vertex",
          id: target.id,
          index: target.index,
          vertices: this.drag.wall.vertices.map((v, i) =>
            i === target.index ? [x, y, v[2]] : v
          )
        };
      } else {
        // Whole wall: one shared translation, snapped and clamped so EVERY
        // vertex stays inside bounds + margin.
        let dx = wx - this.drag.startWorld[0];
        let dy = wy - this.drag.startWorld[1];
        if (snap) {
          dx = snapValue(dx, snap);
          dy = snapValue(dy, snap);
        }
        const startXY = this.drag.startXY;
        dx = clampAxis(
          dx,
          Math.max(...startXY.map((v) => bounds.min[0] - DRAG_BOUNDS_MARGIN - v[0])),
          Math.min(...startXY.map((v) => bounds.max[0] + DRAG_BOUNDS_MARGIN - v[0]))
        );
        dy = clampAxis(
          dy,
          Math.max(...startXY.map((v) => bounds.min[1] - DRAG_BOUNDS_MARGIN - v[1])),
          Math.min(...startXY.map((v) => bounds.max[1] + DRAG_BOUNDS_MARGIN - v[1]))
        );
        preview = {
          kind: "wall",
          id: target.id,
          vertices: this.drag.wall.vertices.map((v, i) => [
            startXY[i][0] + dx,
            startXY[i][1] + dy,
            v[2]
          ])
        };
      }

      this.drag.preview = preview;
      this.scheduleDraw();
    },

    onPointerUp(event) {
      if (!this.drag) return;
      const { preview } = this.drag;

      if (preview) {
        // ONE commit event per drag; the server re-validates and re-renders.
        const payload =
          preview.kind === "node"
            ? { kind: "node", id: preview.id, pos: preview.pos }
            : preview.kind === "wall_vertex"
              ? {
                  kind: "wall_vertex",
                  id: preview.id,
                  index: preview.index,
                  pos: [preview.vertices[preview.index][0], preview.vertices[preview.index][1]]
                }
              : {
                  kind: "wall",
                  id: preview.id,
                  vertices: preview.vertices.map((v) => [v[0], v[1]])
                };
        if (this.snap && this.view && this.view.gridStep > 0) {
          payload.grid_step = this.view.gridStep;
        }
        this.pushEvent("commit_geometry", payload);
      }

      this.endDrag(event.pointerId);
    },

    onPointerCancel(event) {
      if (this.drag) this.endDrag(event.pointerId);
    },

    endDrag(pointerId) {
      this.drag = null;
      if (this.canvas) {
        try {
          if (this.canvas.hasPointerCapture(pointerId)) {
            this.canvas.releasePointerCapture(pointerId);
          }
        } catch (_error) {
          // Pointer already released; nothing to do.
        }
        this.canvas.style.cursor = "";
      }
      this.scheduleDraw();
    },

    destroyed() {
      if (this.canvas) {
        this.canvas.removeEventListener("pointerdown", this.onPointerDown);
        this.canvas.removeEventListener("pointermove", this.onPointerMove);
        this.canvas.removeEventListener("pointerup", this.onPointerUp);
        this.canvas.removeEventListener("pointercancel", this.onPointerCancel);
      }
      if (this.observer) this.observer.disconnect();
      if (this.raf) cancelAnimationFrame(this.raf);
      this.observer = null;
      this.raf = null;
      this.drag = null;
    }
  };

  const DspCharts = {
    mounted() {
      this.charts = {};
      this.history = [];
      this.lastTick = -1;
      this.pendingFrame = null;
      this.raf = null;
      this.observer = null;

      this.resize = this.resize.bind(this);
      this.renderFrame = this.renderFrame.bind(this);

      if (!window.echarts) {
        this.el.querySelectorAll(".chart").forEach((el) => {
          el.textContent = "Chart library failed to load.";
        });
        return;
      }

      ["constellation", "waveform", "spectrum", "ber"].forEach((id) => {
        const el = document.getElementById(`chart-${id}`);
        if (!el) return;
        const chart = window.echarts.init(el, null, { renderer: "canvas" });
        this.charts[id] = chart;
        chart.setOption(this.optionsFor(id), true);
      });

      this.handleEvent("sim_frame", (frame) => this.onFrame(frame));

      if (typeof ResizeObserver !== "undefined") {
        this.observer = new ResizeObserver(this.resize);
        this.observer.observe(this.el);
      } else {
        window.addEventListener("resize", this.resize);
      }

      requestAnimationFrame(this.resize);
    },

    onFrame(frame) {
      if (!this.charts.constellation) return;

      if (typeof frame.tick === "number" && frame.tick <= this.lastTick) {
        this.history = [];
      }

      if (typeof frame.tick === "number") {
        this.lastTick = frame.tick;
      }

      const ber = frame.metrics && Number.isFinite(Number(frame.metrics.ber)) ? Number(frame.metrics.ber) : 0;
      this.history.push({ tick: frame.tick || 0, ber });
      if (this.history.length > 120) this.history.shift();

      this.pendingFrame = frame;
      if (this.raf) return;
      this.raf = requestAnimationFrame(() => {
        this.raf = null;
        this.renderFrame(this.pendingFrame);
      });
    },

    renderFrame(frame) {
      if (!frame) return;

      const dsp = frame.dsp || {};
      const constellation = dsp.constellation || [];
      const waveform = (dsp.waveform || []).map((value, index) => [index, value]);
      const spectrum = (dsp.spectrum || []).map((value, index) => [index, value]);
      const ber = this.history.map((entry) => [entry.tick, entry.ber]);

      this.charts.constellation &&
        this.charts.constellation.setOption({ series: [{ data: constellation }] });
      this.charts.waveform && this.charts.waveform.setOption({ series: [{ data: waveform }] });
      this.charts.spectrum && this.charts.spectrum.setOption({ series: [{ data: spectrum }] });
      this.charts.ber && this.charts.ber.setOption({ series: [{ data: ber }] });
    },

    optionsFor(id) {
      const base = {
        animation: false,
        backgroundColor: "transparent",
        grid: { left: 8, right: 8, top: 8, bottom: 8 },
        textStyle: { color: COLORS.text, fontFamily: "ui-monospace, SFMono-Regular, monospace" }
      };

      if (id === "constellation") {
        return {
          ...base,
          tooltip: { show: false },
          xAxis: { type: "value", min: -1.6, max: 1.6, show: false },
          yAxis: { type: "value", min: -1.6, max: 1.6, show: false },
          series: [
            {
              type: "scatter",
              data: [],
              symbolSize: 5,
              itemStyle: { color: COLORS.tx, opacity: 0.85 }
            }
          ]
        };
      }

      if (id === "ber") {
        return {
          ...base,
          tooltip: {
            trigger: "axis",
            backgroundColor: "#111827",
            borderColor: "#1f2937",
            textStyle: { color: COLORS.text, fontSize: 11 },
            formatter: (params) => {
              const point = params && params[0];
              return point ? `tick ${point.data[0]}<br/>BER ${Number(point.data[1]).toFixed(4)}` : "";
            }
          },
          xAxis: { type: "value", show: false },
          yAxis: {
            type: "value",
            min: 0,
            max: 0.5,
            splitNumber: 2,
            axisLabel: { color: COLORS.muted, fontSize: 9 },
            splitLine: { lineStyle: { color: COLORS.grid } }
          },
          series: [
            {
              type: "line",
              data: [],
              showSymbol: false,
              smooth: false,
              lineStyle: { color: COLORS.reflection, width: 2 },
              areaStyle: { color: "rgba(251, 146, 60, 0.12)" }
            }
          ]
        };
      }

      return {
        ...base,
        tooltip: { show: false },
        xAxis: { type: "value", show: false },
        yAxis: { type: "value", show: false },
        series: [
          {
            type: "line",
            data: [],
            showSymbol: false,
            smooth: true,
            lineStyle: { color: id === "waveform" ? COLORS.tx : "#818cf8", width: 2 },
            areaStyle: {
              color: id === "waveform" ? "rgba(34, 211, 238, 0.10)" : "rgba(129, 140, 248, 0.10)"
            }
          }
        ]
      };
    },

    resize() {
      Object.values(this.charts).forEach((chart) => chart.resize());
    },

    destroyed() {
      if (this.observer) this.observer.disconnect();
      else window.removeEventListener("resize", this.resize);
      if (this.raf) cancelAnimationFrame(this.raf);
      Object.values(this.charts).forEach((chart) => chart.dispose());
      this.charts = {};
    }
  };

  const Hooks = { SimCanvas, DspCharts };
  window.liveHooks = Hooks;

  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

  if (window.LiveView && window.Phoenix) {
    const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
      params: { _csrf_token: csrfToken },
      hooks: Hooks
    });

    liveSocket.connect();
    window.liveSocket = liveSocket;
  } else {
    console.error("Phoenix LiveView assets failed to load.");
  }
})();
