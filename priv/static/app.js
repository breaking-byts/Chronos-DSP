(() => {
  const Hooks = {
    SimCanvas: {
      mounted() {},
      updated() {}
    },
    DspCharts: {
      mounted() {},
      updated() {}
    }
  };

  if (window.liveSocket) {
    window.liveSocket.hooks = Hooks;
  }
})();
