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

  const SimCanvas = {
    mounted() {
      this.canvas = this.el.querySelector("canvas");
      this.ctx = this.canvas ? this.canvas.getContext("2d") : null;
      this.frame = null;
      this.raf = null;
      this.width = 1;
      this.height = 1;
      this.dpr = 1;

      this.scheduleDraw = this.scheduleDraw.bind(this);
      this.onResize = this.onResize.bind(this);
      this.observer = new ResizeObserver(this.onResize);
      this.observer.observe(this.el);

      this.handleEvent("sim_frame", (frame) => {
        this.frame = frame;
        this.scheduleDraw();
      });

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
        this.drawPlaceholder(ctx, w, h, "Waiting for the first simulation frame…");
        return;
      }

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

      this.drawGrid(ctx, { w, h, minX, minY, maxX, maxY, scale, project });
      this.drawWalls(ctx, frame.walls || [], project);
      this.drawPaths(ctx, frame.paths || [], project);
      this.drawNodes(ctx, frame.nodes || [], project);
      this.drawScaleBar(ctx, { w, h, scale, minX, minY, maxX, maxY });
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

        if (vertices.length >= 2 && wall.attenuation_db) {
          const [x, y] = vertices[0];
          ctx.fillStyle = COLORS.muted;
          ctx.font = "500 10px ui-monospace, SFMono-Regular, monospace";
          ctx.fillText(`${wall.attenuation_db} dB`, x + 4, y - 6);
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
        ctx.beginPath();
        ctx.moveTo(points[0][0], points[0][1]);
        points.slice(1).forEach(([x, y]) => ctx.lineTo(x, y));

        if (isReflection) {
          ctx.setLineDash([5, 4]);
          ctx.strokeStyle = COLORS.reflection;
          ctx.lineWidth = 1.4;
          ctx.globalAlpha = 0.85;
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

    destroyed() {
      if (this.observer) this.observer.disconnect();
      if (this.raf) cancelAnimationFrame(this.raf);
      this.observer = null;
      this.raf = null;
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
