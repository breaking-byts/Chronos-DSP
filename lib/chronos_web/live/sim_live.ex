defmodule ChronosWeb.SimLive do
  @moduledoc """
  Live, browser-driven view of one propagation simulation session.

  Each connected browser owns a supervised `Chronos.SimServer`. The page pushes
  complete frames to two hooks: a canvas scene renderer and an ECharts telemetry
  panel.
  """

  use ChronosWeb, :live_view

  require Logger

  alias Chronos.DSP
  alias Chronos.Scenario
  alias Chronos.SimFrame
  alias Chronos.SimServer
  alias Chronos.SimSupervisor

  @seed 7
  @default_speed_ms 100
  @default_noise_power 0.01

  @speeds [
    %{label: "0.5×", ms: 200},
    %{label: "1×", ms: 100},
    %{label: "2×", ms: 50},
    %{label: "5×", ms: 20}
  ]

  @noise_levels [
    %{label: "Off", value: 0.0},
    %{label: "Low", value: 0.01},
    %{label: "Medium", value: 0.05},
    %{label: "High", value: 0.15}
  ]

  @speed_values Enum.map(@speeds, & &1.ms)
  @noise_values Enum.map(@noise_levels, & &1.value)

  @impl true
  def mount(_params, _session, socket) do
    scenario = Scenario.default_id()
    frame = build_frame(scenario, @default_noise_power)

    socket =
      assign(socket,
        frame: frame,
        scenario: scenario,
        scenarios: Scenario.list(),
        speed_ms: @default_speed_ms,
        speeds: @speeds,
        noise_power: @default_noise_power,
        noise_levels: @noise_levels,
        running: false,
        sim: nil,
        sim_ref: nil,
        error: nil,
        nif_loaded: DSP.nif_loaded?()
      )

    if connected?(socket) do
      case start_sim(scenario, @default_speed_ms, @default_noise_power) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          send(self(), :tick)
          {:ok, assign(socket, sim: pid, sim_ref: ref, running: true)}

        {:error, reason} ->
          {:ok,
           assign(socket,
             error: "Could not start the simulation: #{inspect(reason)}",
             running: false
           )}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    socket =
      if socket.assigns.sim && socket.assigns.running do
        case safe_next_frame(socket.assigns.sim) do
          {:ok, frame} ->
            socket
            |> assign(frame: frame, error: nil)
            |> push_event("sim_frame", frame)

          {:error, reason} ->
            assign(socket, running: false, error: "Simulation error: #{reason}")
        end
      else
        socket
      end

    Process.send_after(self(), :tick, socket.assigns.speed_ms)
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{sim_ref: ref}} = socket) do
    message =
      case reason do
        :normal -> nil
        :shutdown -> nil
        {:shutdown, _} -> nil
        other -> "Simulation stopped: #{inspect(other)}"
      end

    {:noreply, assign(socket, sim: nil, sim_ref: nil, running: false, error: message)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle", _params, socket) do
    if socket.assigns.sim do
      {:noreply, assign(socket, running: !socket.assigns.running, error: nil)}
    else
      {:noreply, restart_simulation(socket, true)}
    end
  end

  def handle_event("step", _params, socket) do
    if socket.assigns.sim do
      case safe_next_frame(socket.assigns.sim) do
        {:ok, frame} ->
          {:noreply,
           socket
           |> assign(frame: frame, error: nil)
           |> push_event("sim_frame", frame)}

        {:error, reason} ->
          {:noreply, assign(socket, error: "Simulation error: #{reason}")}
      end
    else
      {:noreply, restart_simulation(socket, socket.assigns.running)}
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply, reset_simulation(socket)}
  end

  def handle_event("speed", %{"ms" => ms}, socket) do
    case Integer.parse(ms) do
      {value, ""} when value in @speed_values ->
        if socket.assigns.sim, do: SimServer.set_tick_ms(socket.assigns.sim, value)
        {:noreply, assign(socket, speed_ms: value)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("noise", %{"value" => value}, socket) do
    case Float.parse(value) do
      {noise, ""} when noise in @noise_values ->
        if socket.assigns.sim, do: SimServer.set_noise_power(socket.assigns.sim, noise)
        {:noreply, assign(socket, noise_power: noise)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("scenario", %{"id" => id}, socket) do
    if id in Scenario.ids() do
      socket =
        case socket.assigns.sim do
          nil ->
            assign(socket,
              scenario: id,
              frame: build_frame(id, socket.assigns.noise_power)
            )

          pid ->
            :ok = SimServer.set_scenario(pid, id)

            case safe_next_frame(pid) do
              {:ok, frame} ->
                socket
                |> assign(scenario: id, frame: frame, error: nil)
                |> push_event("sim_frame", frame)

              {:error, reason} ->
                assign(socket, scenario: id, error: "Simulation error: #{reason}")
            end
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:sim], do: SimSupervisor.stop_sim(pid)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="shell">
      <header class="topbar">
        <div class="brand">
          <span class="brand-mark" aria-hidden="true"></span>
          <div>
            <h1>Chronos-DSP</h1>
            <p>Real-time wireless propagation lab</p>
          </div>
        </div>
        <div class="topbar-right">
          <span class={["status", @running && "is-live"]}>
            <span class="status-dot" aria-hidden="true"></span>
            <%= if @running, do: "Live", else: "Paused" %>
          </span>
          <span class={["engine-badge", @nif_loaded && "is-native"]}>
            <%= if @nif_loaded, do: "Native NIF", else: "Reference fallback" %>
          </span>
        </div>
      </header>

      <p :if={@error} class="banner banner-error" role="alert"><%= @error %></p>

      <section class="workspace">
        <section class="panel scene-panel">
          <div class="panel-head">
            <div>
              <h2>Scene</h2>
              <p><%= scenario_name(@scenario) %></p>
            </div>
            <span class="tick">tick <%= @frame.tick %></span>
          </div>

          <div id="sim-canvas" class="scene-canvas" phx-hook="SimCanvas" phx-update="ignore">
            <canvas aria-label="Top-down view of the simulated scene"></canvas>
          </div>

          <div class="legend">
            <span><i class="swatch tx"></i>Transmitter</span>
            <span><i class="swatch rx"></i>Receiver</span>
            <span><i class="swatch los"></i>Line of sight</span>
            <span><i class="swatch reflection"></i>Reflection</span>
            <span><i class="swatch wall"></i>Wall</span>
          </div>
        </section>

        <aside class="side">
          <section class="stats" aria-label="Link metrics">
            <div class="stat">
              <span>Paths</span>
              <strong><%= @frame.metrics.path_count %></strong>
            </div>
            <div class="stat">
              <span>BER</span>
              <strong><%= format_ber(@frame.metrics.ber) %></strong>
            </div>
            <div class="stat">
              <span>RX power</span>
              <strong><%= format_power(@frame.metrics.received_power) %></strong>
            </div>
            <div class="stat">
              <span>Scene</span>
              <strong><%= length(@frame.nodes) %>n / <%= length(@frame.walls) %>w</strong>
            </div>
          </section>

          <section class="panel controls">
            <div class="panel-head compact">
              <h2>Controls</h2>
              <span class="muted"><%= speed_label(@speed_ms) %></span>
            </div>

            <div class="button-row">
              <button class="button primary" phx-click="toggle">
                <%= if @running, do: "Pause", else: "Play" %>
              </button>
              <button class="button" phx-click="step">Step</button>
              <button class="button ghost" phx-click="reset">Reset</button>
            </div>

            <div class="control-group">
              <span class="control-label">Speed</span>
              <div class="segmented">
                <button
                  :for={speed <- @speeds}
                  class={["segment", @speed_ms == speed.ms && "is-active"]}
                  phx-click="speed"
                  phx-value-ms={speed.ms}
                >
                  <%= speed.label %>
                </button>
              </div>
            </div>

            <div class="control-group">
              <span class="control-label">Noise</span>
              <div class="segmented">
                <button
                  :for={noise <- @noise_levels}
                  class={["segment", @noise_power == noise.value && "is-active"]}
                  phx-click="noise"
                  phx-value-value={noise.value}
                >
                  <%= noise.label %>
                </button>
              </div>
            </div>

            <div class="control-group">
              <span class="control-label">Scenario</span>
              <div class="segmented wrap">
                <button
                  :for={scenario <- @scenarios}
                  class={["segment", @scenario == scenario.id && "is-active"]}
                  phx-click="scenario"
                  phx-value-id={scenario.id}
                  title={scenario.description}
                >
                  <%= scenario.name %>
                </button>
              </div>
            </div>
          </section>

          <section class="panel telemetry">
            <div class="panel-head compact">
              <h2>Telemetry</h2>
              <span class="muted">first receiver</span>
            </div>

            <div id="dsp-charts" phx-hook="DspCharts" phx-update="ignore" class="chart-grid">
              <figure class="chart-card">
                <figcaption>Constellation</figcaption>
                <div id="chart-constellation" class="chart"></div>
              </figure>
              <figure class="chart-card">
                <figcaption>Waveform</figcaption>
                <div id="chart-waveform" class="chart"></div>
              </figure>
              <figure class="chart-card">
                <figcaption>Spectrum</figcaption>
                <div id="chart-spectrum" class="chart"></div>
              </figure>
              <figure class="chart-card">
                <figcaption>BER history</figcaption>
                <div id="chart-ber" class="chart"></div>
              </figure>
            </div>
          </section>
        </aside>
      </section>

      <footer class="footer">
        <span>Top-down view · XY projection</span>
        <span><%= scenario_description(@scenario) %></span>
      </footer>
    </main>
    """
  end

  defp build_frame(scenario, noise_power) do
    scenario
    |> Scenario.world()
    |> SimFrame.from_world(
      tick: 0,
      seed: @seed,
      bounds: Scenario.bounds(scenario),
      sample_rate: 48_000.0,
      noise_power: noise_power
    )
  end

  defp start_sim(scenario, speed_ms, noise_power) do
    SimSupervisor.start_sim(
      scenario: scenario,
      seed: @seed,
      tick_ms: speed_ms,
      noise_power: noise_power,
      owner: self()
    )
  end

  defp safe_next_frame(pid) do
    SimServer.next_frame(pid)
  catch
    :exit, reason ->
      Logger.warning("Simulation call failed: #{inspect(reason)}")
      {:error, "process unavailable"}
  end

  defp reset_simulation(socket) do
    case socket.assigns.sim do
      nil ->
        assign(socket,
          frame: build_frame(socket.assigns.scenario, socket.assigns.noise_power),
          error: nil
        )

      pid ->
        :ok = SimServer.reset(pid)

        case safe_next_frame(pid) do
          {:ok, frame} ->
            socket
            |> assign(frame: frame, error: nil)
            |> push_event("sim_frame", frame)

          {:error, reason} ->
            assign(socket, error: "Simulation error: #{reason}")
        end
    end
  end

  defp restart_simulation(socket, running?) do
    if pid = socket.assigns.sim do
      SimSupervisor.stop_sim(pid)
      if ref = socket.assigns.sim_ref, do: Process.demonitor(ref, [:flush])
    end

    case start_sim(socket.assigns.scenario, socket.assigns.speed_ms, socket.assigns.noise_power) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        case safe_next_frame(pid) do
          {:ok, frame} ->
            socket
            |> assign(sim: pid, sim_ref: ref, running: running?, frame: frame, error: nil)
            |> push_event("sim_frame", frame)

          {:error, reason} ->
            assign(socket,
              sim: nil,
              sim_ref: nil,
              running: false,
              error: "Simulation error: #{reason}"
            )
        end

      {:error, reason} ->
        assign(socket,
          sim: nil,
          sim_ref: nil,
          running: false,
          error: "Could not start the simulation: #{inspect(reason)}"
        )
    end
  end

  defp format_ber(value) when is_number(value) do
    :erlang.float_to_binary(value, decimals: 4)
  end

  defp format_ber(_value), do: "—"

  defp format_power(value) when is_number(value) do
    value
    |> :erlang.float_to_binary(decimals: 4)
  end

  defp format_power(_value), do: "—"

  defp speed_label(ms) do
    Enum.find_value(@speeds, "#{ms} ms", fn speed -> if speed.ms == ms, do: speed.label end)
  end

  defp scenario_name(id) do
    Scenario.name(id)
  end

  defp scenario_description(id) do
    Enum.find_value(Scenario.list(), fn scenario ->
      if scenario.id == id, do: scenario.description
    end) || ""
  end
end
