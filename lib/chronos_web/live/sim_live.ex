defmodule ChronosWeb.SimLive do
  use ChronosWeb, :live_view

  alias Chronos.Channel
  alias Chronos.Modem
  alias Chronos.Packing
  alias Chronos.Sim
  alias Chronos.SimServer
  alias Chronos.World

  @impl true
  def mount(_params, _session, socket) do
    {:ok, sim} = SimServer.start_link(seed: 7, tick_ms: 100)
    send(self(), :tick)
    world = demo_world()
    {ber, path_count} = metrics(world)

    {:ok,
     assign(socket,
       sim: sim,
       world: world,
       ber: ber,
       path_count: path_count,
       running: true
     )}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:ok, frame} = SimServer.next_frame(socket.assigns.sim)
    socket = push_event(socket, "sim_frame", frame)
    Process.send_after(self(), :tick, 100)
    {:noreply, socket}
  end

  @impl true
  def handle_event("step", _params, socket) do
    world = World.step(socket.assigns.world, 0.1)
    {ber, path_count} = metrics(world)

    {:noreply, assign(socket, world: world, ber: ber, path_count: path_count)}
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
        <h1>Chronos-DSP Prototype</h1>
        <p>Nodes: <%= map_size(@world.nodes) %> | Walls: <%= map_size(@world.walls) %></p>
        <p>Paths to RX: <%= @path_count %></p>
        <p>BER: <%= Float.round(@ber, 6) %></p>
        <button phx-click="step">Step</button>
        <button phx-click="toggle"><%= if @running, do: "Pause", else: "Running" %></button>
        <div id="dsp-charts" phx-hook="DspCharts"></div>
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
    rx_symbols = Packing.unpack_complex(rx_bin)
    rx_bits = Modem.qpsk_demodulate(rx_symbols)
    ber = Modem.ber(bits, rx_bits)
    path_count = Channel.paths_for_rx(world, :rx1, opts) |> length()
    {ber, path_count}
  end
end
