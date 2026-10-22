(() => {
  const Hooks = {
    SimCanvas: {
      mounted() {
        this.app = new PIXI.Application({ resizeTo: this.el, background: "#0b0f14" });
        this.el.appendChild(this.app.canvas);
        this.world = new PIXI.Container();
        this.app.stage.addChild(this.world);
        this.handleEvent("sim_frame", ({ nodes, walls, paths }) =>
          this.renderScene(nodes, walls, paths)
        );
      },
      renderScene(nodes = [], walls = [], paths = []) {
        this.world.removeChildren();

        const graphics = new PIXI.Graphics();
        const width = this.app.renderer.width;
        const height = this.app.renderer.height;
        const scale = 120;
        const offsetX = width / 2;
        const offsetY = height / 2;

        graphics.lineStyle(1, 0x1f2937, 0.35);
        const gridSize = scale;
        for (let x = offsetX % gridSize; x < width; x += gridSize) {
          graphics.moveTo(x, 0);
          graphics.lineTo(x, height);
        }
        for (let y = offsetY % gridSize; y < height; y += gridSize) {
          graphics.moveTo(0, y);
          graphics.lineTo(width, y);
        }

        walls.forEach((wall) => {
          const vertices = wall.vertices || [];
          if (vertices.length < 2) return;
          graphics.lineStyle(2, 0x334155, 0.8);
          vertices.forEach((vertex, index) => {
            const px = offsetX + vertex[0] * scale;
            const py = offsetY - vertex[1] * scale;
            if (index === 0) {
              graphics.moveTo(px, py);
            } else {
              graphics.lineTo(px, py);
            }
          });
          graphics.lineTo(
            offsetX + vertices[0][0] * scale,
            offsetY - vertices[0][1] * scale
          );
        });

        paths.forEach((path) => {
          const points = path.points || path.vertices || [];
          if (points.length < 2) return;
          const color = path.kind === "reflection" ? 0xf97316 : 0x22d3ee;
          graphics.lineStyle(1, color, 0.6);
          points.forEach((point, index) => {
            const px = offsetX + point[0] * scale;
            const py = offsetY - point[1] * scale;
            if (index === 0) {
              graphics.moveTo(px, py);
            } else {
              graphics.lineTo(px, py);
            }
          });
        });

        nodes.forEach((node) => {
          if (!node.pos) return;
          const color =
            node.type === "tx"
              ? 0x22d3ee
              : node.type === "rx"
              ? 0xf97316
              : 0x94a3b8;
          const px = offsetX + node.pos[0] * scale;
          const py = offsetY - node.pos[1] * scale;
          graphics.beginFill(color);
          graphics.drawCircle(px, py, 6);
          graphics.endFill();
        });

        this.world.addChild(graphics);
      },
      destroyed() {
        if (this.app) {
          this.app.destroy(true);
          this.app = null;
        }
      },
      updated() {}
    },
    DspCharts: {
      mounted() {
        this.constellation = echarts.init(this.el.querySelector("#chart-constellation"));
        this.spectrum = echarts.init(this.el.querySelector("#chart-spectrum"));
        this.waveform = echarts.init(this.el.querySelector("#chart-waveform"));
        this.initCharts();
        this.lastUpdate = 0;
        this.handleEvent("sim_frame", ({ dsp }) => {
          const now = performance.now();
          if (now - this.lastUpdate < 100) return;
          this.lastUpdate = now;
          this.updateCharts(dsp || {});
        });
        this.resizeHandler = () => {
          this.constellation.resize();
          this.spectrum.resize();
          this.waveform.resize();
        };
        window.addEventListener("resize", this.resizeHandler);
      },
      initCharts() {
        this.constellation.setOption({
          backgroundColor: "transparent",
          grid: { left: 16, right: 16, top: 16, bottom: 16 },
          xAxis: { type: "value", min: -2, max: 2, show: false },
          yAxis: { type: "value", min: -2, max: 2, show: false },
          series: [
            {
              type: "scatter",
              data: [],
              itemStyle: { color: "#22d3ee" }
            }
          ]
        });
        this.spectrum.setOption({
          backgroundColor: "transparent",
          grid: { left: 16, right: 16, top: 20, bottom: 16 },
          xAxis: { type: "value", show: false },
          yAxis: { type: "value", show: false },
          series: [
            {
              type: "line",
              data: [],
              smooth: true,
              showSymbol: false,
              lineStyle: { color: "#f97316", width: 2 }
            }
          ]
        });
        this.waveform.setOption({
          backgroundColor: "transparent",
          grid: { left: 16, right: 16, top: 20, bottom: 16 },
          xAxis: { type: "value", show: false },
          yAxis: { type: "value", show: false },
          series: [
            {
              type: "line",
              data: [],
              smooth: true,
              showSymbol: false,
              lineStyle: { color: "#38bdf8", width: 2 }
            }
          ]
        });
      },
      updateCharts(dsp) {
        const constellation = dsp.constellation || [];
        const spectrum = (dsp.spectrum || []).map((value, index) => [index, value]);
        const waveform = (dsp.waveform || []).map((value, index) => [index, value]);

        this.constellation.setOption({
          series: [{ type: "scatter", data: constellation, symbolSize: 6 }]
        });
        this.spectrum.setOption({
          series: [{ type: "line", data: spectrum, smooth: true, showSymbol: false }]
        });
        this.waveform.setOption({
          series: [{ type: "line", data: waveform, smooth: true, showSymbol: false }]
        });
      },
      destroyed() {
        window.removeEventListener("resize", this.resizeHandler);
        this.constellation?.dispose();
        this.spectrum?.dispose();
        this.waveform?.dispose();
      },
      updated() {}
    }
  };

  window.liveHooks = Hooks;
})();
