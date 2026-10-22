defmodule ChronosWeb.SimLive do
  use ChronosWeb, :live_view

  alias Chronos.SimFrame
  alias Chronos.SimServer
  alias Chronos.World

  @impl true
  def mount(_params, _session, socket) do
    tick_ms = 100
    world = demo_world()
    {:ok, sim} = SimServer.start_link(seed: 7, tick_ms: tick_ms, world: world)
    frame = SimFrame.from_world(world, tick: 0, seed: 7)
    send(self(), :tick)

    {:ok,
     assign(socket,
        sim: sim,
        frame: frame,
        running: true,
        tick_ms: tick_ms
      )}
  end

  @impl true
  def handle_info(:tick, socket) do
    socket =
      if socket.assigns.running do
        {:ok, frame} = SimServer.next_frame(socket.assigns.sim)
        socket
        |> assign(frame: frame)
        |> push_event("sim_frame", frame)
      else
        socket
      end

    Process.send_after(self(), :tick, socket.assigns.tick_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_event("step", _params, socket) do
    {:ok, frame} = SimServer.next_frame(socket.assigns.sim)

    {:noreply,
     socket
     |> assign(frame: frame)
     |> push_event("sim_frame", frame)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    running = !socket.assigns.running
    {:noreply, assign(socket, running: running)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="sim-layout">
      <section class="sim-left">
        <div id="sim-canvas" phx-hook="SimCanvas"></div>
      </section>
      <section class="sim-right">
        <header class="sim-header">
          <p class="sim-kicker">Hybrid UI Rendering</p>
          <h1>Chronos-DSP Prototype</h1>
        </header>
        <div class="sim-stats">
          <div class="sim-stat">
            <span>Nodes</span>
            <strong><%= length(@frame.nodes) %></strong>
          </div>
          <div class="sim-stat">
            <span>Walls</span>
            <strong><%= length(@frame.walls) %></strong>
          </div>
          <div class="sim-stat">
            <span>Paths to RX</span>
            <strong><%= @frame.metrics.path_count %></strong>
          </div>
          <div class="sim-stat">
            <span>BER</span>
            <strong><%= Float.round(@frame.metrics.ber, 6) %></strong>
          </div>
        </div>
        <div class="sim-controls">
          <button class="sim-button" phx-click="step">Step</button>
          <button class="sim-button ghost" phx-click="toggle">
            <%= if @running, do: "Pause", else: "Running" %>
          </button>
        </div>
        <div id="dsp-charts" phx-hook="DspCharts">
          <div id="chart-constellation"></div>
          <div id="chart-spectrum"></div>
          <div id="chart-waveform"></div>
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
end
