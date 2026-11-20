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
  alias Chronos.Material
  alias Chronos.PanelEdit
  alias Chronos.Scenario
  alias Chronos.SceneEdit
  alias Chronos.SimFrame
  alias Chronos.SimServer
  alias Chronos.SimSupervisor
  alias ChronosWeb.ApiParams

  @seed 7
  @default_speed_ms 100
  @default_noise_power 0.01
  @default_tx_power ApiParams.default_tx_power()

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
    frame = build_frame(scenario, @default_noise_power, @default_tx_power)

    socket =
      assign(socket,
        frame: frame,
        scenario: scenario,
        scenarios: Scenario.list(),
        speed_ms: @default_speed_ms,
        speeds: @speeds,
        noise_power: @default_noise_power,
        noise_levels: @noise_levels,
        tx_power: @default_tx_power,
        materials: Material.list(),
        panel: panel_view(frame, @default_tx_power),
        running: false,
        snap_to_grid: false,
        sim: nil,
        sim_ref: nil,
        error: nil,
        nif_loaded: DSP.nif_loaded?()
      )

    if connected?(socket) do
      case start_sim(scenario, @default_speed_ms, @default_noise_power, @default_tx_power) do
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
            |> put_frame(frame)
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
           |> put_frame(frame)
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

  def handle_event("toggle_snap", _params, socket) do
    enabled = !socket.assigns.snap_to_grid

    {:noreply,
     socket
     |> assign(snap_to_grid: enabled)
     |> push_event("snap_state", %{enabled: enabled})}
  end

  def handle_event("commit_geometry", params, socket) do
    case socket.assigns.sim do
      nil -> {:noreply, socket}
      pid -> commit_geometry(pid, params, socket)
    end
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
            frame = build_frame(id, socket.assigns.noise_power, socket.assigns.tx_power)

            socket
            |> assign(scenario: id)
            |> put_frame(frame)

          pid ->
            :ok = SimServer.set_scenario(pid, id)

            case safe_next_frame(pid) do
              {:ok, frame} ->
                socket
                |> assign(scenario: id)
                |> put_frame(frame)
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

  # -- Editing panel (#35): every value is re-validated server-side ---------

  def handle_event("set_tx_power", %{"value" => value}, socket) do
    with {tx_power, ""} <- Integer.parse(value),
         {:ok, tx_power} <- ApiParams.validate_tx_power(tx_power) do
      if socket.assigns.sim, do: SimServer.set_tx_power(socket.assigns.sim, tx_power)

      {:noreply,
       assign(socket,
         tx_power: tx_power,
         panel: %{socket.assigns.panel | tx_power: tx_power}
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_wall_attenuation", %{"id" => id, "value" => value}, socket) do
    with {db, ""} <- Float.parse(value),
         {:ok, db} <- ApiParams.validate_attenuation(db) do
      apply_panel_edit(socket, fn world, _bounds ->
        PanelEdit.set_wall_attenuation(world, id, db)
      end)
    else
      _ -> {:noreply, socket}
    end
  end

  # Auto checkbox: checked clears the override to nil (use the material);
  # unchecked seeds the override with the material's reflection loss so the
  # slider starts at the material's value. Unchecked checkboxes submit no
  # "auto" field, so a missing value means false.
  def handle_event("set_wall_auto", %{"id" => id} = params, socket) do
    auto? = Map.get(params, "auto", "false") in ["true", "on"]

    apply_panel_edit(socket, fn world, _bounds ->
      db = if auto?, do: nil, else: material_reflection_db(world, id)
      PanelEdit.set_wall_attenuation(world, id, db)
    end)
  end

  def handle_event("set_node_z", %{"id" => id, "value" => value}, socket) do
    with {z, ""} <- Float.parse(value),
         {:ok, z} <- ApiParams.validate_z(z) do
      apply_panel_edit(socket, fn world, _bounds -> PanelEdit.set_node_z(world, id, z) end)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_wall_z", %{"id" => id, "value" => value}, socket) do
    with {z, ""} <- Float.parse(value),
         {:ok, z} <- ApiParams.validate_z(z) do
      apply_panel_edit(socket, fn world, _bounds -> PanelEdit.set_wall_z(world, id, z) end)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_wall_material", %{"id" => id, "value" => value}, socket) do
    case ApiParams.validate_material(value) do
      {:ok, material} ->
        apply_panel_edit(socket, fn world, _bounds ->
          PanelEdit.set_wall_material(world, id, material)
        end)

      {:error, _message} ->
        {:noreply, socket}
    end
  end

  def handle_event("add_wall", _params, socket) do
    apply_panel_edit(socket, fn world, bounds -> PanelEdit.add_wall(world, bounds) end)
  end

  def handle_event("remove_wall", %{"id" => id}, socket) do
    apply_panel_edit(socket, fn world, _bounds -> PanelEdit.remove_wall(world, id) end)
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

          <div
            id="sim-canvas"
            class="scene-canvas"
            phx-hook="SimCanvas"
            phx-update="ignore"
            data-snap={@snap_to_grid}
          >
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
              <button
                class={["button ghost", @snap_to_grid && "is-active"]}
                phx-click="toggle_snap"
                aria-pressed={to_string(@snap_to_grid)}
                title="Snap canvas drags to the drawn grid"
              >
                Snap grid
              </button>
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

          <section class="panel edit-panel" aria-label="Scene editing">
            <div class="panel-head compact">
              <h2>Editing</h2>
              <span class="muted"><%= @panel.wall_count %>/<%= @panel.max_walls %> walls</span>
            </div>

            <div class="control-group">
              <label class="control-label" for="tx-power">TX power</label>
              <div class="slider-row">
                <input
                  type="range"
                  id="tx-power"
                  name="value"
                  min="0"
                  max="30"
                  step="1"
                  value={@panel.tx_power}
                  phx-change="set_tx_power"
                  phx-debounce="150"
                />
                <span class="slider-value"><%= @panel.tx_power %> dBm</span>
              </div>
            </div>

            <div class="control-group">
              <span class="control-label">Node height (z)</span>
              <div :for={node <- @panel.nodes} class="field-row">
                <label for={"node-z-#{node.id}"}><%= node.id %></label>
                <input
                  type="number"
                  id={"node-z-#{node.id}"}
                  name="value"
                  min="-5"
                  max="5"
                  step="0.1"
                  value={format_z(node.z)}
                  phx-change="set_node_z"
                  phx-value-id={node.id}
                  phx-debounce="300"
                />
                <span class="muted">m</span>
              </div>
            </div>

            <div class="control-group">
              <div class="wall-head">
                <span class="control-label">Walls</span>
                <button
                  class="button ghost"
                  phx-click="add_wall"
                  disabled={@panel.wall_count >= @panel.max_walls}
                  title="Add a short default wall near the scene center"
                >
                  Add wall
                </button>
              </div>

              <p :if={@panel.walls == []} class="muted empty-note">
                No walls in this scene. Add one to edit its material and height.
              </p>

              <div :for={wall <- @panel.walls} class="wall-card" id={"wall-card-#{wall.id}"}>
                <div class="wall-card-head">
                  <strong><%= wall.id %></strong>
                  <button
                    class="button ghost small"
                    phx-click="remove_wall"
                    phx-value-id={wall.id}
                    title={"Remove #{wall.id}"}
                  >
                    Remove
                  </button>
                </div>

                <div class="field-row">
                  <label for={"wall-material-#{wall.id}"}>Material</label>
                  <select
                    id={"wall-material-#{wall.id}"}
                    name="value"
                    phx-change="set_wall_material"
                    phx-value-id={wall.id}
                  >
                    <option
                      :for={material <- @materials}
                      value={material.id}
                      selected={to_string(material.id) == wall.material}
                    >
                      <%= material.name %>
                    </option>
                  </select>
                </div>

                <label class="checkbox-row" for={"wall-auto-#{wall.id}"}>
                  <input
                    type="checkbox"
                    id={"wall-auto-#{wall.id}"}
                    name="auto"
                    value="true"
                    checked={wall.auto}
                    phx-change="set_wall_auto"
                    phx-value-id={wall.id}
                  />
                  Auto (use material)
                </label>

                <div class="slider-row">
                  <input
                    type="range"
                    id={"wall-att-#{wall.id}"}
                    name="value"
                    min="0"
                    max="40"
                    step="0.5"
                    value={wall.display_attenuation}
                    disabled={wall.auto}
                    phx-change="set_wall_attenuation"
                    phx-value-id={wall.id}
                    phx-debounce="150"
                    aria-label={"#{wall.id} attenuation override"}
                  />
                  <span class="slider-value">
                            <%= if wall.auto, do: "auto · #{wall.material_reflection_db} dB", else: "#{wall.attenuation_db} dB" %>
                  </span>
                </div>

                <div class="field-row">
                  <label for={"wall-z-#{wall.id}"}>Height (z)</label>
                  <input
                    type="number"
                    id={"wall-z-#{wall.id}"}
                    name="value"
                    min="-5"
                    max="5"
                    step="0.1"
                    value={format_z(wall.z)}
                    phx-change="set_wall_z"
                    phx-value-id={wall.id}
                    phx-debounce="300"
                  />
                  <span class="muted">m</span>
                </div>
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

  defp build_frame(scenario, noise_power, tx_power) do
    scenario
    |> Scenario.world()
    |> SimFrame.from_world(
      tick: 0,
      seed: @seed,
      bounds: Scenario.bounds(scenario),
      sample_rate: 48_000.0,
      noise_power: noise_power,
      tx_power: tx_power
    )
  end

  defp start_sim(scenario, speed_ms, noise_power, tx_power) do
    SimSupervisor.start_sim(
      scenario: scenario,
      seed: @seed,
      tick_ms: speed_ms,
      noise_power: noise_power,
      tx_power: tx_power,
      owner: self()
    )
  end

  # Assigns a fresh frame and rebuilds the editing-panel view model from it
  # (the frame already carries every node/wall property the panel displays).
  defp put_frame(socket, frame) do
    assign(socket,
      frame: frame,
      panel: panel_view(frame, socket.assigns.tx_power),
      error: nil
    )
  end

  defp panel_view(frame, tx_power) do
    %{
      tx_power: tx_power,
      nodes:
        Enum.map(frame.nodes, fn node ->
          %{id: node.id, type: node.type, z: Enum.at(node.pos, 2)}
        end),
      walls: Enum.map(frame.walls, &panel_wall/1),
      wall_count: length(frame.walls),
      max_walls: PanelEdit.max_walls()
    }
  end

  defp panel_wall(wall) do
    material = Material.get(wall.material)
    zs = Enum.map(wall.vertices, &Enum.at(&1, 2))
    z = if zs == [], do: 0.0, else: Enum.sum(zs) / length(zs)

    %{
      id: wall.id,
      material: wall.material,
      auto: is_nil(wall.attenuation_db),
      attenuation_db: wall.attenuation_db,
      display_attenuation: wall.attenuation_db || material.reflection_loss_db,
      material_reflection_db: material.reflection_loss_db,
      z: z
    }
  end

  # One validated panel commit: fetch the live world, apply the pure edit,
  # replace the world through SimServer, re-render through the normal flow.
  defp apply_panel_edit(socket, edit) do
    case socket.assigns.sim do
      nil ->
        {:noreply, socket}

      pid ->
        with {:ok, world, bounds} <- safe_get_world(pid),
             {:ok, updated} <- edit.(world, bounds),
             :ok <- SimServer.update_world(pid, updated) do
          case safe_next_frame(pid) do
            {:ok, frame} ->
              {:noreply, socket |> put_frame(frame) |> push_event("sim_frame", frame)}

            {:error, reason} ->
              {:noreply, assign(socket, error: "Simulation error: #{reason}")}
          end
        else
          {:error, reason} ->
            Logger.warning("Rejected panel edit: #{inspect(reason)}")
            {:noreply, socket}
        end
    end
  end

  # The material's own reflection loss for a wall id (used when the Auto
  # checkbox is unchecked to seed the override slider). Unknown ids fall back
  # to the default material; PanelEdit rejects the unknown id regardless.
  defp material_reflection_db(world, id) do
    case Enum.find(world.walls, fn {wall_id, _wall} -> to_string(wall_id) == id end) do
      {_id, wall} -> Material.for_wall(wall).reflection_loss_db
      nil -> Material.default().reflection_loss_db
    end
  end

  defp safe_next_frame(pid) do
    SimServer.next_frame(pid)
  catch
    :exit, reason ->
      Logger.warning("Simulation call failed: #{inspect(reason)}")
      {:error, "process unavailable"}
  end

  # One commit per drag release: validate server-side (bounds clamp, min wall
  # length, snap), replace the world, then re-render through the normal flow.
  defp commit_geometry(pid, params, socket) do
    with {:ok, world, bounds} <- safe_get_world(pid),
         {:ok, updated} <-
           SceneEdit.apply(world, bounds, params,
             snap: socket.assigns.snap_to_grid,
             grid_step: params["grid_step"]
           ),
         :ok <- SimServer.update_world(pid, updated) do
      case safe_next_frame(pid) do
        {:ok, frame} ->
          {:noreply,
           socket
           |> put_frame(frame)
           |> push_event("sim_frame", frame)}

        {:error, reason} ->
          {:noreply, assign(socket, error: "Simulation error: #{reason}")}
      end
    else
      {:error, reason} ->
        Logger.warning("Rejected geometry commit: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  defp safe_get_world(pid) do
    SimServer.get_world(pid)
  catch
    :exit, reason ->
      Logger.warning("Simulation call failed: #{inspect(reason)}")
      {:error, "process unavailable"}
  end

  defp reset_simulation(socket) do
    case socket.assigns.sim do
      nil ->
        socket
        |> put_frame(
          build_frame(
            socket.assigns.scenario,
            socket.assigns.noise_power,
            socket.assigns.tx_power
          )
        )

      pid ->
        :ok = SimServer.reset(pid)

        case safe_next_frame(pid) do
          {:ok, frame} ->
            socket
            |> put_frame(frame)
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

    case start_sim(
           socket.assigns.scenario,
           socket.assigns.speed_ms,
           socket.assigns.noise_power,
           socket.assigns.tx_power
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        case safe_next_frame(pid) do
          {:ok, frame} ->
            socket
            |> assign(sim: pid, sim_ref: ref, running: running?)
            |> put_frame(frame)
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

  defp format_z(value) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: 1)
  end

  defp format_z(_value), do: "0.0"

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
