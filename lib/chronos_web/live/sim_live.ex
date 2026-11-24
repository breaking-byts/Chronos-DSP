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
  alias Chronos.SceneSnapshot
  alias Chronos.SceneStore
  alias Chronos.SimFrame
  alias Chronos.SimServer
  alias Chronos.SimSupervisor
  alias Chronos.World
  alias ChronosWeb.ApiParams

  @seed 7
  @default_speed_ms 100
  @default_noise_power 0.01
  @default_tx_power ApiParams.default_tx_power()
  # Undo history depth (#37): pre-edit worlds, newest first; the oldest entry
  # drops once the stack exceeds the cap.
  @undo_depth 50

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
        nif_loaded: DSP.nif_loaded?(),
        # Scene save/load + dirty state (#36). The baseline starts at the
        # starting scenario world and is replaced on save/load/reset.
        scenes: scene_names(),
        max_scenes: SceneStore.max_scenes(),
        scene_name_input: "",
        scene_message: nil,
        scene_baseline: SceneSnapshot.from_world(Scenario.world(scenario)),
        scene_dirty: false,
        # Undo/reset + export (#37). `undo_stack` holds pre-edit worlds
        # (newest first, capped at @undo_depth); `saved_world` is the
        # restorable world behind the normalized dirty baseline (last
        # save/load/reset); `custom_world` mirrors SimServer's edited-world
        # flag for the export note; `export_menu_open` toggles the CSV menu.
        undo_stack: [],
        saved_world: Scenario.world(scenario),
        custom_world: false,
        export_menu_open: false
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

  # -- Undo/reset + export (#37) ---------------------------------------------
  # Undo-only for v1 (redo deferred). The stack holds pre-edit worlds pushed
  # by commit_world/4; popping one restores it through SimServer.update_world/2
  # and re-renders through the normal sim_frame flow. The Undo button and the
  # UndoKeys hook (Ctrl/Cmd+Z) push this same event.

  def handle_event("undo", _params, socket) do
    case {socket.assigns.sim, socket.assigns.undo_stack} do
      {pid, [world | rest]} when is_pid(pid) ->
        case SimServer.update_world(pid, world) do
          :ok ->
            socket = assign(socket, undo_stack: rest)

            case safe_next_frame(pid) do
              {:ok, frame} ->
                {:noreply,
                 socket
                 |> put_frame(frame)
                 |> push_event("sim_frame", frame)
                 |> refresh_scene_dirty(world)}

              {:error, reason} ->
                {:noreply, assign(socket, error: "Simulation error: #{reason}")}
            end

          {:error, reason} ->
            Logger.warning("Undo failed: #{inspect(reason)}")
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # "Revert to saved" restores the last saved/loaded snapshot — the restorable
  # `saved_world`, NOT the normalized dirty baseline (which has no velocities).
  # A no-op while clean: there is nothing to revert.
  def handle_event("revert_to_saved", _params, socket) do
    cond do
      is_nil(socket.assigns.sim) ->
        {:noreply, socket}

      not socket.assigns.scene_dirty ->
        {:noreply, socket}

      true ->
        revert_to_saved(socket, socket.assigns.sim, socket.assigns.saved_world)
    end
  end

  def handle_event("toggle_export_menu", _params, socket) do
    {:noreply, assign(socket, export_menu_open: !socket.assigns.export_menu_open)}
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
            |> assign(scenario: id, custom_world: false)
            |> put_frame(frame)
            |> push_event("sim_frame", frame)
            |> set_scene_baseline(Scenario.world(id))

          pid ->
            :ok = SimServer.set_scenario(pid, id)

            case safe_next_frame(pid) do
              {:ok, frame} ->
                socket
                |> assign(scenario: id, custom_world: false)
                |> put_frame(frame)
                |> push_event("sim_frame", frame)
                |> set_scene_baseline(Scenario.world(id))

              {:error, reason} ->
                assign(socket,
                  scenario: id,
                  custom_world: false,
                  error: "Simulation error: #{reason}"
                )
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

  # -- Scene save/load (#36) ------------------------------------------------
  # The LiveView is server-side, so it calls Chronos.SceneStore directly
  # rather than HTTP-looping through /api/scenes: same validation, caps and
  # oldest-first eviction, without a network round-trip to itself. The JSON
  # controllers remain the public API surface. Scene names are validated
  # server-side by SceneStore (traversal-safe, <= 64 chars); client input is
  # never trusted.

  def handle_event("set_scene_name", %{"name" => name}, socket) when is_binary(name) do
    {:noreply, assign(socket, scene_name_input: name)}
  end

  def handle_event("save_scene", params, socket) do
    name =
      case Map.get(params, "name", socket.assigns.scene_name_input) do
        value when is_binary(value) -> String.trim(value)
        _other -> ""
      end

    case socket.assigns.sim do
      nil ->
        {:noreply,
         put_scene_message(socket, :error, "Start the simulation before saving a scene.")}

      pid ->
        case safe_get_world(pid) do
          {:ok, world, _bounds} ->
            save_world_scene(socket, world, name)

          {:error, reason} ->
            {:noreply, put_scene_message(socket, :error, "Could not read the world: #{reason}")}
        end
    end
  end

  def handle_event("load_scene", %{"name" => name}, socket) do
    cond do
      not is_binary(name) ->
        {:noreply, put_scene_message(socket, :error, scene_error_message(:invalid_name))}

      is_nil(socket.assigns.sim) ->
        {:noreply,
         put_scene_message(socket, :error, "Start the simulation before loading a scene.")}

      true ->
        load_world_scene(socket, socket.assigns.sim, name)
    end
  end

  def handle_event("delete_scene", %{"name" => name}, socket) do
    result = if is_binary(name), do: SceneStore.delete(name), else: {:error, :invalid_name}

    socket = assign(socket, scenes: scene_names())

    case result do
      :ok ->
        {:noreply, put_scene_message(socket, :info, "Deleted scene \"#{name}\".")}

      {:error, reason} ->
        {:noreply, put_scene_message(socket, :error, scene_error_message(reason, name))}
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
    <main id="app-shell" class="shell" phx-hook="UndoKeys">
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
              <div class="export-control">
                <button
                  class={["button ghost", @export_menu_open && "is-active"]}
                  phx-click="toggle_export_menu"
                  aria-expanded={to_string(@export_menu_open)}
                  aria-haspopup="menu"
                  title="Export CSV from the built-in scenario"
                >
                  Export CSV
                </button>
                <div :if={@export_menu_open} class="export-menu" role="menu">
                  <a
                    :for={link <- export_links(assigns)}
                    href={link.href}
                    download={link.file}
                    role="menuitem"
                  >
                    <%= link.label %>
                  </a>
                  <p :if={@custom_world} class="export-note is-warning">
                    This world has been edited — export reflects the built-in
                    <%= scenario_name(@scenario) %> scenario, not your edits.
                  </p>
                  <p class="export-note">
                    CSV re-simulates the scenario at 0.1 s/tick with the live seed
                    and TX power; noise and sample rate are fixed by the export API.
                  </p>
                </div>
              </div>
              <button
                class="button ghost"
                phx-click="undo"
                disabled={@undo_stack == []}
                title="Undo the last edit (Ctrl/Cmd+Z)"
              >
                Undo
              </button>
              <button
                class="button ghost"
                phx-click="revert_to_saved"
                disabled={not @scene_dirty}
                title="Restore the last saved/loaded snapshot"
              >
                Revert to saved
              </button>
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

          <section class="panel scenes-panel" aria-label="Saved scenes">
            <div class="panel-head compact">
              <h2>Scenes</h2>
              <span class="muted scene-count"><%= length(@scenes) %>/<%= @max_scenes %> scenes</span>
            </div>

            <span class={["scene-state", @scene_dirty && "is-dirty"]}>
              <span :if={@scene_dirty} class="dirty-dot" aria-hidden="true"></span>
              <%= if @scene_dirty, do: "Dirty — live world differs from the last snapshot", else: "Clean — matches the last saved/loaded snapshot" %>
            </span>

            <form id="scene-save" phx-submit="save_scene" class="scene-save-form">
              <input
                type="text"
                id="scene-name"
                name="name"
                value={@scene_name_input}
                phx-change="set_scene_name"
                phx-debounce="200"
                maxlength="64"
                placeholder="scene-name"
                aria-label="Scene name"
                autocomplete="off"
              />
              <button class="button primary" type="submit">Save scene</button>
            </form>

            <p
              :if={@scene_message}
              class={["banner", @scene_message.kind == :error && "banner-error", @scene_message.kind == :info && "banner-info"]}
              role={if @scene_message.kind == :error, do: "alert", else: "status"}
            >
              <%= @scene_message.text %>
            </p>

            <div class="control-group">
              <span class="control-label">Load a scene (replaces the current world)</span>
              <p :if={@scenes == []} class="muted empty-note">
                No saved scenes yet. Save the current world to create one.
              </p>
              <ul :if={@scenes != []} class="scene-list">
                <li :for={name <- @scenes} class="scene-row">
                  <button
                    class="button ghost scene-load"
                    phx-click="load_scene"
                    phx-value-name={name}
                    title={"Load #{name} — replaces the current world"}
                  >
                    <%= name %>
                  </button>
                  <button
                    class="button ghost small"
                    phx-click="delete_scene"
                    phx-value-name={name}
                    aria-label={"Delete #{name}"}
                    title={"Delete #{name}"}
                  >
                    Delete
                  </button>
                </li>
              </ul>
            </div>

            <p class="muted eviction-note">
              Capped at <%= @max_scenes %> scenes; when full, the oldest scene (by
              modification time) is evicted first. Scenes are ephemeral — they
              vanish on redeploy.
            </p>
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

  # Export CSV menu links (#37). The existing /api/export endpoints are
  # SCENARIO-based: they re-simulate the built-in scenario from tick 0 at
  # 0.1 s/tick, so an edited custom world cannot be expressed through them.
  # The links carry the live scenario/seed/tx_power and the current tick; the
  # menu warns when the world is custom and notes the API's fixed noise power
  # (0.01) and sample rate (48 kHz) — neither is an export query parameter.
  defp export_links(assigns) do
    base = %{"scenario" => assigns.scenario, "seed" => @seed, "tx_power" => assigns.tx_power}
    tick = assigns.frame.tick

    [
      %{
        label: "Metrics (current tick)",
        file: "metrics.csv",
        href: "/api/export/metrics?" <> URI.encode_query(Map.merge(base, %{"ticks" => tick}))
      },
      %{
        label: "History (ticks 0–100)",
        file: "history.csv",
        href:
          "/api/export/history?" <>
            URI.encode_query(Map.merge(base, %{"from" => 0, "to" => 100, "step" => 1}))
      },
      %{
        label: "Samples (current tick)",
        file: "samples.csv",
        href:
          "/api/export/samples?" <>
            URI.encode_query(Map.merge(base, %{"ticks" => tick, "limit" => 128}))
      }
    ]
  end

  # One validated panel commit: fetch the live world, apply the pure edit,
  # then share the drag-commit path (undo push, world replace, re-render).
  defp apply_panel_edit(socket, edit) do
    case socket.assigns.sim do
      nil ->
        {:noreply, socket}

      pid ->
        with {:ok, world, bounds} <- safe_get_world(pid),
             {:ok, updated} <- edit.(world, bounds) do
          commit_world(socket, pid, world, updated)
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
  # length, snap), then share the panel-commit path (undo push, world replace,
  # re-render).
  defp commit_geometry(pid, params, socket) do
    with {:ok, world, bounds} <- safe_get_world(pid),
         {:ok, updated} <-
           SceneEdit.apply(world, bounds, params,
             snap: socket.assigns.snap_to_grid,
             grid_step: params["grid_step"]
           ) do
      commit_world(socket, pid, world, updated)
    else
      {:error, reason} ->
        Logger.warning("Rejected geometry commit: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # Shared world commit (#37): replace the world through SimServer, push the
  # PRE-EDIT world onto the undo stack (newest first, capped at @undo_depth —
  # the oldest entry drops beyond the cap), mark the session custom, then
  # re-render through the normal sim_frame flow and refresh the dirty dot.
  # Covers drag commits and every panel edit (sliders, z, material,
  # attenuation, add/remove wall). Undo pops the top back through
  # SimServer.update_world/2; redo is deferred.
  defp commit_world(socket, pid, pre_edit, updated) do
    case SimServer.update_world(pid, updated) do
      :ok ->
        socket =
          socket
          |> push_undo(pre_edit)
          |> assign(custom_world: true)

        case safe_next_frame(pid) do
          {:ok, frame} ->
            {:noreply,
             socket
             |> put_frame(frame)
             |> push_event("sim_frame", frame)
             |> refresh_scene_dirty(updated)}

          {:error, reason} ->
            {:noreply, assign(socket, error: "Simulation error: #{reason}")}
        end

      {:error, reason} ->
        Logger.warning("Rejected world update: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  defp push_undo(socket, world) do
    assign(socket, undo_stack: Enum.take([world | socket.assigns.undo_stack], @undo_depth))
  end

  defp safe_get_world(pid) do
    SimServer.get_world(pid)
  catch
    :exit, reason ->
      Logger.warning("Simulation call failed: #{inspect(reason)}")
      {:error, "process unavailable"}
  end

  # -- Scene save/load helpers (#36) ----------------------------------------

  defp scene_names, do: Enum.map(SceneStore.list(), & &1["name"])

  # Persists the current world under `name`. SceneStore.save overwrites a
  # same-named scene (refreshing its mtime) and enforces every cap. Eviction is
  # detected by diffing the scene-name set before/after (a different name
  # disappeared): overwriting at the cap is not misreported as an eviction, and
  # a total-byte-cap eviction below the count cap is still caught. On success
  # the dirty baseline becomes the saved world.
  defp save_world_scene(socket, world, name) do
    names_before = scene_names()

    case SceneStore.save(World.to_scene(world, name)) do
      :ok ->
        names_after = scene_names()
        evicted? = Enum.any?(names_before, fn n -> n != name and n not in names_after end)

        message =
          "Saved scene \"#{name}\"." <>
            if evicted? do
              " The oldest scene was evicted to make room (capped store)."
            else
              ""
            end

        {:noreply,
         socket
         |> set_scene_baseline(world)
         |> assign(scenes: scene_names(), scene_name_input: "")
         |> put_scene_message(:info, message)}

      {:error, reason} ->
        {:noreply, put_scene_message(socket, :error, scene_error_message(reason))}
    end
  end

  # Loads a stored scene and replaces the session world through
  # SimServer.update_world/2 (bounds recompute, custom stepping). The loaded
  # world becomes the dirty baseline + revert target and the undo history
  # clears (#37).
  defp load_world_scene(socket, pid, name) do
    with {:ok, scene} <- SceneStore.get(name),
         {:ok, world} <- SceneStore.scene_to_world(scene),
         :ok <- SimServer.update_world(pid, world) do
      case safe_next_frame(pid) do
        {:ok, frame} ->
          {:noreply,
           socket
           |> put_frame(frame)
           |> push_event("sim_frame", frame)
           |> set_scene_baseline(world)
           |> assign(custom_world: true)
           |> put_scene_message(
             :info,
             "Loaded scene \"#{name}\" — it replaced the current world."
           )}

        {:error, reason} ->
          {:noreply, assign(socket, error: "Simulation error: #{reason}")}
      end
    else
      {:error, reason} ->
        # The list may have changed under us (delete/eviction by another
        # session); refresh it alongside the error.
        {:noreply,
         socket
         |> assign(scenes: scene_names())
         |> put_scene_message(:error, scene_error_message(reason, name))}
    end
  end

  # Sets the dirty-state baseline to `world` (last save/load/reset), keeps the
  # restorable world for "Revert to saved" (#37) — the normalized snapshot has
  # no velocities and cannot be restored directly — clears the dirty dot, and
  # clears the undo history.
  defp set_scene_baseline(socket, world) do
    assign(socket,
      scene_baseline: SceneSnapshot.from_world(world),
      saved_world: world,
      scene_dirty: false,
      undo_stack: []
    )
  end

  # "Revert to saved" (#37): restore the last saved/loaded world through
  # SimServer.update_world/2, re-render, then re-baseline (which clears the
  # undo stack and the dirty dot). The session stays custom-stepped.
  defp revert_to_saved(socket, pid, world) do
    case SimServer.update_world(pid, world) do
      :ok ->
        case safe_next_frame(pid) do
          {:ok, frame} ->
            {:noreply,
             socket
             |> put_frame(frame)
             |> push_event("sim_frame", frame)
             |> set_scene_baseline(world)
             |> assign(custom_world: true)}

          {:error, reason} ->
            {:noreply, assign(socket, error: "Simulation error: #{reason}")}
        end

      {:error, reason} ->
        Logger.warning("Revert to saved failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # Recomputes the dirty dot after an edit: normalized geometry (positions,
  # walls, material, attenuation, z — never tick/velocity noise) against the
  # baseline. Ticks do NOT recompute it; simulation motion is not an edit.
  defp refresh_scene_dirty(socket, world) do
    dirty? = SceneSnapshot.from_world(world) != socket.assigns.scene_baseline
    assign(socket, scene_dirty: dirty?)
  end

  defp put_scene_message(socket, kind, text) do
    assign(socket, scene_message: %{kind: kind, text: text})
  end

  # Uniform friendly messages for every SceneStore failure mode.
  defp scene_error_message(reason, name \\ nil)

  defp scene_error_message(:invalid_name, _name) do
    "Invalid scene name: use 1–64 lowercase letters, digits, \"-\" or \"_\"."
  end

  defp scene_error_message(:invalid_scene, name) when is_binary(name) do
    "Scene \"#{name}\" is invalid or too large to load."
  end

  defp scene_error_message(:invalid_scene, _name) do
    "This world is too large or invalid to save (64 KiB per scene, 1024 nodes/walls)."
  end

  defp scene_error_message(:not_found, name) when is_binary(name) do
    "Scene \"#{name}\" was not found — it may have been deleted or evicted."
  end

  defp scene_error_message(:not_found, _name), do: "Scene not found."

  defp scene_error_message(reason, _name) do
    "Scene storage error: #{inspect(reason)}."
  end

  defp reset_simulation(socket) do
    case socket.assigns.sim do
      nil ->
        frame =
          build_frame(
            socket.assigns.scenario,
            socket.assigns.noise_power,
            socket.assigns.tx_power
          )

        socket
        |> put_frame(frame)
        |> push_event("sim_frame", frame)
        |> set_scene_baseline(Scenario.world(socket.assigns.scenario))
        |> assign(custom_world: false)

      pid ->
        :ok = SimServer.reset(pid)

        case safe_next_frame(pid) do
          {:ok, frame} ->
            socket =
              socket
              |> put_frame(frame)
              |> push_event("sim_frame", frame)

            # Reset rewinds to the session's pre-edit world; the dirty
            # baseline follows it, the undo history clears, and the session
            # is scenario-stepped again (#37).
            case safe_get_world(pid) do
              {:ok, world, _bounds} ->
                socket
                |> set_scene_baseline(world)
                |> assign(custom_world: false)

              {:error, _reason} ->
                assign(socket, custom_world: false)
            end

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
            # A restarted session begins fresh from the scenario: re-baseline
            # (clears undo + dirty, resets the revert target) and mark it
            # scenario-stepped (#37).
            socket
            |> assign(sim: pid, sim_ref: ref, running: running?, custom_world: false)
            |> put_frame(frame)
            |> push_event("sim_frame", frame)
            |> set_scene_baseline(Scenario.world(socket.assigns.scenario))

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
