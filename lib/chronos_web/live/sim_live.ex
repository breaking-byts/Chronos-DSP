defmodule ChronosWeb.SimLive do
  use ChronosWeb, :live_view

  alias Chronos.Channel
  alias Chronos.Metrics
  alias Chronos.Modem
  alias Chronos.Packing
  alias Chronos.Scene
  alias Chronos.Sim
  alias Chronos.World

  @history_limit 60
  @scene_viewport %{width: 360, height: 220}
  @constellation_viewport %{width: 260, height: 200}
  @history_viewport %{width: 360, height: 90}

  @impl true
  def mount(_params, _session, socket) do
    world = demo_world()
    {metrics, history} = build_metrics(world, [])

    {:ok,
     assign(socket,
       world: world,
       metrics: metrics,
       history: history,
       scene_viewport: @scene_viewport,
       constellation_viewport: @constellation_viewport,
       history_viewport: @history_viewport
     )}
  end

  @impl true
  def handle_event("step", _params, socket) do
    world = World.step(socket.assigns.world, 0.1)
    {metrics, history} = build_metrics(world, socket.assigns.history)

    {:noreply, assign(socket, world: world, metrics: metrics, history: history)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="sim-root">
      <style>
        :root {
          --ink: #10111c;
          --muted: #5e647a;
          --bg: #f4f1ec;
          --panel: rgba(255, 255, 255, 0.92);
          --panel-border: rgba(17, 17, 32, 0.12);
          --accent: #d97d54;
          --accent-2: #2f6f7f;
        }

        .sim-root {
          font-family: "Space Grotesk", "Avenir Next", sans-serif;
          color: var(--ink);
          min-height: 100vh;
          padding: 32px 24px 48px;
          background: radial-gradient(circle at top, #f9f7f3 0%, #efe6db 55%, #e6d9cc 100%);
        }

        .sim-hero {
          display: flex;
          flex-wrap: wrap;
          justify-content: space-between;
          gap: 24px;
          margin-bottom: 28px;
        }

        .eyebrow {
          text-transform: uppercase;
          letter-spacing: 0.24em;
          font-size: 12px;
          color: var(--muted);
          margin: 0 0 6px;
        }

        h1 {
          font-size: 32px;
          margin: 0 0 8px;
        }

        .subtitle {
          margin: 0;
          color: var(--muted);
        }

        .metrics {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
          gap: 12px;
          align-items: center;
          background: var(--panel);
          border: 1px solid var(--panel-border);
          padding: 16px;
          border-radius: 16px;
          min-width: 260px;
        }

        .metrics .label {
          font-size: 12px;
          letter-spacing: 0.08em;
          text-transform: uppercase;
          color: var(--muted);
          margin: 0 0 4px;
        }

        .metrics .value {
          font-size: 20px;
          margin: 0;
        }

        .metrics button {
          border: none;
          background: var(--accent);
          color: white;
          font-weight: 600;
          padding: 10px 16px;
          border-radius: 10px;
          cursor: pointer;
        }

        .sim-grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
          gap: 20px;
        }

        .panel {
          background: var(--panel);
          border: 1px solid var(--panel-border);
          border-radius: 18px;
          padding: 16px;
          box-shadow: 0 18px 30px rgba(16, 17, 28, 0.08);
        }

        .panel.wide {
          grid-column: 1 / -1;
        }

        .panel-header {
          display: flex;
          justify-content: space-between;
          align-items: baseline;
          margin-bottom: 12px;
        }

        .panel-header h2 {
          margin: 0;
          font-size: 18px;
        }

        .panel-header span {
          color: var(--muted);
          font-size: 12px;
          letter-spacing: 0.08em;
          text-transform: uppercase;
        }

        svg {
          width: 100%;
          height: auto;
          display: block;
          background: linear-gradient(140deg, rgba(240, 232, 220, 0.8), rgba(250, 249, 245, 0.4));
          border-radius: 12px;
          padding: 10px;
        }

        .wall {
          fill: rgba(217, 125, 84, 0.25);
          stroke: var(--accent);
          stroke-width: 2;
        }

        .node.tx {
          fill: var(--accent);
        }

        .node.rx {
          fill: var(--accent-2);
        }

        .axis {
          stroke: rgba(16, 17, 28, 0.2);
          stroke-width: 1;
        }

        .point {
          fill: var(--accent-2);
          opacity: 0.7;
        }

        .spark {
          fill: none;
          stroke: var(--accent);
          stroke-width: 2;
        }

        .spark.alt {
          stroke: var(--accent-2);
        }
      </style>
      <section class="sim-hero">
        <div>
          <p class="eyebrow">Chronos DSP</p>
          <h1>Signal Lab Dashboard</h1>
          <p class="subtitle">Top-down scene, constellation, and BER trend snapshots.</p>
        </div>
        <div class="metrics" data-history-count={length(@history)}>
          <div>
            <p class="label">BER</p>
            <p class="value"><%= Float.round(@metrics.ber, 6) %></p>
          </div>
          <div>
            <p class="label">Paths</p>
            <p class="value"><%= @metrics.path_count %></p>
          </div>
          <div>
            <p class="label">RX Power</p>
            <p class="value"><%= Float.round(@metrics.rx_power, 3) %></p>
          </div>
          <button phx-click="step">Step</button>
        </div>
      </section>

      <section class="sim-grid">
        <div class="panel">
          <div class="panel-header">
            <h2>Scene</h2>
            <span>Walls + Nodes</span>
          </div>
          <svg viewBox={"0 0 #{@scene_viewport.width} #{@scene_viewport.height}"}>
            <%= for wall <- @metrics.scene_walls do %>
              <polygon points={wall.points} class="wall" />
            <% end %>
            <%= for node <- @metrics.scene_nodes do %>
              <circle cx={node.x} cy={node.y} r="6" class={node.class} />
            <% end %>
          </svg>
        </div>

        <div class="panel">
          <div class="panel-header">
            <h2>Constellation</h2>
            <span>RX Samples</span>
          </div>
          <svg viewBox={"0 0 #{@constellation_viewport.width} #{@constellation_viewport.height}"}>
            <line x1="0" y1="100" x2={@constellation_viewport.width} y2="100" class="axis" />
            <line x1="130" y1="0" x2="130" y2={@constellation_viewport.height} class="axis" />
            <%= for point <- @metrics.constellation do %>
              <circle cx={point.x} cy={point.y} r="3" class="point" />
            <% end %>
          </svg>
        </div>

        <div class="panel wide">
          <div class="panel-header">
            <h2>History</h2>
            <span>BER / Power</span>
          </div>
          <svg viewBox={"0 0 #{@history_viewport.width} #{@history_viewport.height}"}>
            <polyline points={@metrics.history_ber} class="spark" />
            <polyline points={@metrics.history_power} class="spark alt" />
          </svg>
        </div>
      </section>
    </main>
    """
  end

  defp demo_world do
    World.new()
    |> World.add_node(%World.Node{
      id: :tx1,
      type: :tx,
      pos: {0.0, 0.0, 0.0},
      vel: {0.0, 0.0, 0.0}
    })
    |> World.add_node(%World.Node{
      id: :rx1,
      type: :rx,
      pos: {2.0, 0.0, 0.0},
      vel: {0.0, 0.0, 0.0}
    })
    |> World.add_wall(%World.Wall{
      id: :w1,
      vertices: [{1.0, -1.0, -1.0}, {1.0, 1.0, -1.0}, {1.0, 1.0, 1.0}, {1.0, -1.0, 1.0}],
      normal: {-1.0, 0.0, 0.0},
      attenuation_db: 3.0
    })
  end

  defp metrics(world) do
    bits = Enum.take(Stream.cycle([0, 0, 1, 1]), 128)
    symbols = Modem.qpsk_modulate(bits)
    tx_bin = Packing.pack_complex(symbols)

    opts = [
      sample_rate: 48_000.0,
      speed_of_light: 299_792_458.0,
      noise_power: 0.0,
      seed: 7
    ]

    rx_map = Sim.render(world, tx_bin, opts)
    rx_bin = Map.fetch!(rx_map, :rx1)
    rx_symbols = Packing.unpack_complex!(rx_bin)
    rx_bits = Modem.qpsk_demodulate(rx_symbols)
    ber = Modem.ber(bits, rx_bits)

    rx_power = Metrics.received_power(rx_symbols)
    path_count = Channel.paths_for_rx!(world, :rx1, opts) |> length()

    %{
      ber: ber,
      rx_power: rx_power,
      path_count: path_count,
      rx_symbols: rx_symbols
    }
  end

  defp build_metrics(world, history) do
    metrics = metrics(world)
    history_entry = %{time_s: world.time_s, ber: metrics.ber, rx_power: metrics.rx_power}
    history = Metrics.push_history(history, history_entry, @history_limit)

    {scene_bounds, scene_walls, scene_nodes} = scene_projection(world)
    constellation = constellation_points(metrics.rx_symbols)
    {history_ber, history_power} = history_sparklines(history)

    metrics =
      Map.merge(metrics, %{
        scene_bounds: scene_bounds,
        scene_walls: scene_walls,
        scene_nodes: scene_nodes,
        constellation: constellation,
        history_ber: history_ber,
        history_power: history_power
      })

    {metrics, history}
  end

  defp scene_projection(world) do
    bounds = scene_bounds(world)

    walls =
      world.walls
      |> Map.values()
      |> Enum.map(fn wall ->
        points =
          wall.vertices
          |> Enum.map(fn vertex ->
            {x, y} = Scene.project(vertex, bounds, @scene_viewport)
            "#{Float.round(x, 2)},#{Float.round(y, 2)}"
          end)
          |> Enum.join(" ")

        %{points: points}
      end)

    nodes =
      world.nodes
      |> Map.values()
      |> Enum.map(fn node ->
        {x, y} = Scene.project(node.pos, bounds, @scene_viewport)

        %{
          x: Float.round(x, 2),
          y: Float.round(y, 2),
          class: if(node.type == :tx, do: "node tx", else: "node rx")
        }
      end)

    {bounds, walls, nodes}
  end

  @doc """
  Computes the scene bounds used to project scene geometry.

  Empty worlds default to a centered 10x10 box spanning -5.0 to 5.0 on both axes.
  """
  @spec scene_bounds(Chronos.World.t()) :: %{min: {float(), float()}, max: {float(), float()}}
  def scene_bounds(world) do
    nodes = world.nodes |> Map.values() |> Enum.map(& &1.pos)
    wall_vertices = world.walls |> Map.values() |> Enum.flat_map(& &1.vertices)
    points = nodes ++ wall_vertices

    if points == [] do
      %{min: {-5.0, -5.0}, max: {5.0, 5.0}}
    else
      {min_x, max_x} = min_max(points, 0)
      {min_y, max_y} = min_max(points, 1)
      padding = 0.5

      %{
        min: {min_x - padding, min_y - padding},
        max: {max_x + padding, max_y + padding}
      }
    end
  end

  defp min_max(points, index) do
    values = Enum.map(points, &elem(&1, index))
    min = Enum.min(values)
    max = Enum.max(values)
    if min == max, do: {min - 1.0, max + 1.0}, else: {min, max}
  end

  defp constellation_points(samples) do
    viewport = @constellation_viewport

    samples
    |> Enum.take(80)
    |> Enum.map(fn {re, im} ->
      x = (re + 1.5) / 3.0 * viewport.width
      y = (1.0 - (im + 1.5) / 3.0) * viewport.height
      %{x: Float.round(x, 2), y: Float.round(y, 2)}
    end)
  end

  defp history_sparklines(history) do
    viewport = @history_viewport
    len = max(length(history), 1)
    x_step = viewport.width / max(len - 1, 1)

    ber_max = history |> Enum.map(& &1.ber) |> Enum.max(fn -> 1.0 end)
    power_max = history |> Enum.map(& &1.rx_power) |> Enum.max(fn -> 1.0 end)

    ber =
      history
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        x = idx * x_step
        y = (1.0 - entry.ber / max(ber_max, 1.0e-9)) * viewport.height
        "#{Float.round(x, 2)},#{Float.round(y, 2)}"
      end)
      |> Enum.join(" ")

    power =
      history
      |> Enum.with_index()
      |> Enum.map(fn {entry, idx} ->
        x = idx * x_step
        y = (1.0 - entry.rx_power / max(power_max, 1.0e-9)) * viewport.height
        "#{Float.round(x, 2)},#{Float.round(y, 2)}"
      end)
      |> Enum.join(" ")

    {ber, power}

  end
end
