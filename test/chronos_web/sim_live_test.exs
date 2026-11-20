defmodule ChronosWeb.SimLiveTest do
  # The endpoint and the global SimSupervisor are shared state.
  use ChronosWeb.ConnCase, async: false

  alias Chronos.DSP
  alias Chronos.Scenario

  test "pushes an initial frame with scene geometry and metrics", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert_push_event(
      view,
      "sim_frame",
      %{tick: 0, nodes: nodes, walls: walls, paths: paths, metrics: metrics},
      500
    )

    assert length(nodes) == 2
    assert Enum.map(nodes, & &1.type) |> Enum.sort() == ["rx", "tx"]
    assert length(walls) == 2
    assert length(paths) >= 2
    assert Enum.any?(paths, &(&1.kind == "los"))
    assert metrics.path_count >= 2
  end

  test "serves the local assets and no longer references PixiJS", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)

    for asset <- [
          "/assets/app.css",
          "/assets/app.js",
          "/assets/vendor/echarts.min.js",
          "/phoenix/phoenix.js",
          "/live/phoenix_live_view.js",
          "/favicon.svg"
        ] do
      assert html =~ asset
    end

    refute html =~ "pixi"
    assert html =~ "Chronos-DSP"
    assert html =~ "Real-time wireless propagation lab"
  end

  test "app.js defines both hooks" do
    body = build_conn() |> get("/assets/app.js") |> response(200)

    assert body =~ "SimCanvas"
    assert body =~ "DspCharts"
    assert body =~ "sim_frame"
  end

  test "app.js wires canvas drag editing with one commit on release" do
    body = build_conn() |> get("/assets/app.js") |> response(200)

    assert body =~ "commit_geometry"
    assert body =~ "snap_state"
    assert body =~ "pointerdown"
    assert body =~ "pointerup"
    # Mouse-only drag: touch/pen pointers are rejected.
    assert body =~ ~s(event.pointerType !== "mouse")
  end

  test "renders the workspace shell and scene panel", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(class="shell")
    assert html =~ ~s(class="workspace")
    assert html =~ ~s(class="panel scene-panel")
    assert html =~ ~s(class="side")
    assert html =~ ~s(class="legend")
    assert html =~ "Top-down view · XY projection"

    assert view |> has_element?(".scene-panel .panel-head h2", "Scene")
    assert view |> has_element?(".scene-panel .tick", "tick 0")
  end

  test "renders the canvas and every telemetry chart container", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert view |> has_element?("#sim-canvas[phx-hook='SimCanvas'][phx-update='ignore'] canvas")

    assert view
           |> has_element?(
             "#sim-canvas canvas[aria-label='Top-down view of the simulated scene']"
           )

    assert view |> has_element?("#dsp-charts[phx-hook='DspCharts'][phx-update='ignore']")

    for id <- ~w(constellation waveform spectrum ber) do
      assert view |> has_element?("#chart-#{id}.chart")
    end

    for caption <- ["Constellation", "Waveform", "Spectrum", "BER history"] do
      assert view |> has_element?(".chart-card figcaption", caption)
    end
  end

  test "renders the engine badge for the active DSP implementation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    if DSP.nif_loaded?() do
      assert view |> has_element?(".engine-badge.is-native", "Native NIF")
    else
      assert view |> has_element?(".engine-badge", "Reference fallback")
    end
  end

  test "renders speed, noise and scenario controls for every option", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    for {label, ms} <- [{"0.5×", 200}, {"1×", 100}, {"2×", 50}, {"5×", 20}] do
      assert view
             |> has_element?("button[phx-click='speed'][phx-value-ms='#{ms}']", label)
    end

    for {label, value} <- [{"Off", "0.0"}, {"Low", "0.01"}, {"Medium", "0.05"}, {"High", "0.15"}] do
      assert view
             |> has_element?("button[phx-click='noise'][phx-value-value='#{value}']", label)
    end

    for %{id: id, name: name} <- Scenario.list() do
      assert view
             |> has_element?("button[phx-click='scenario'][phx-value-id='#{id}']", name)
    end

    for label <- ["Speed", "Noise", "Scenario"] do
      assert view |> has_element?(".control-label", label)
    end

    assert view |> has_element?("button[phx-click='step']", "Step")
    assert view |> has_element?("button[phx-click='reset']", "Reset")
  end

  test "toggle pauses and resumes the simulation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert view |> has_element?(".status.is-live", "Live")
    assert view |> has_element?("button.primary", "Pause")

    paused = render_click(view, "toggle")
    assert paused =~ "Paused"
    refute paused =~ "status is-live"
    assert view |> has_element?("button.primary", "Play")

    resumed = render_click(view, "toggle")
    assert resumed =~ "Live"
    assert view |> has_element?("button.primary", "Pause")
  end

  test "reset rewinds the tick counter and step advances it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Pause first so timer ticks cannot race with the explicit step.
    render_click(view, "toggle")
    drain_frames(view)

    assert render_click(view, "reset") =~ "tick 0"
    drain_frames(view)

    assert render_click(view, "step") =~ "tick 1"
    assert_push_event(view, "sim_frame", %{tick: 1, nodes: _, paths: _})

    assert render_click(view, "step") =~ "tick 2"
    assert_push_event(view, "sim_frame", %{tick: 2})

    assert render_click(view, "reset") =~ "tick 0"
    assert_push_event(view, "sim_frame", %{tick: 0})
  end

  test "step pushes a frame in which the receiver has moved", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    %{proxy: {ref, _topic, _pid}} = view

    render_click(view, "toggle")
    render_click(view, "reset")
    drain_frames(view)

    render_click(view, "step")

    assert_receive {^ref, {:push_event, "sim_frame", %{tick: 1, nodes: nodes, bounds: bounds}}},
                   500

    first_rx = Enum.find(nodes, &(&1.type == "rx"))
    tx = Enum.find(nodes, &(&1.type == "tx"))

    render_click(view, "step")
    assert_receive {^ref, {:push_event, "sim_frame", %{tick: 2, nodes: nodes}}}, 500

    second_rx = Enum.find(nodes, &(&1.type == "rx"))

    assert tx.pos == [0.0, 0.0, 0.0]
    assert first_rx.pos != second_rx.pos
    assert_position_in_bounds(first_rx.pos, bounds)
    assert_position_in_bounds(second_rx.pos, bounds)
  end

  test "speed selection updates the label and ignores unsupported values", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert view |> has_element?(".controls .panel-head .muted", "1×")

    render_click(view, "speed", %{"ms" => "50"})
    assert view |> has_element?(".controls .panel-head .muted", "2×")

    render_click(view, "speed", %{"ms" => "9999"})
    assert view |> has_element?(".controls .panel-head .muted", "2×")

    render_click(view, "speed", %{"ms" => "not-a-number"})
    assert view |> has_element?(".controls .panel-head .muted", "2×")
  end

  test "noise selection marks the requested level active", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert view |> has_element?("button[phx-value-value='0.01'].is-active")

    render_click(view, "noise", %{"value" => "0.15"})
    assert view |> has_element?("button[phx-value-value='0.15'].is-active")
    refute view |> has_element?("button[phx-value-value='0.01'].is-active")

    render_click(view, "noise", %{"value" => "0.123"})
    assert view |> has_element?("button[phx-value-value='0.15'].is-active")
  end

  test "switching scenario resets the tick and swaps the scene geometry", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    render_click(view, "toggle")
    render_click(view, "step")
    drain_frames(view)

    open_field = render_click(view, "scenario", %{"id" => "open_field"})
    assert open_field =~ "tick 0"
    assert open_field =~ "2n / 0w"
    assert view |> has_element?(".scene-panel .panel-head p", "Open field")
    assert_push_event(view, "sim_frame", %{tick: 0, walls: []})

    orbit = render_click(view, "scenario", %{"id" => "orbit"})
    assert orbit =~ "tick 0"
    assert orbit =~ "2n / 2w"
    assert view |> has_element?(".scene-panel .panel-head p", "Orbit + corner walls")
    assert_push_event(view, "sim_frame", %{tick: 0, walls: walls})
    assert length(walls) == 2
  end

  test "unknown scenario ids are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    render_click(view, "toggle")
    drain_frames(view)

    html = render_click(view, "scenario", %{"id" => "no_such_scenario"})

    assert html =~ "Orbit + corner walls"
    assert html =~ "2n / 2w"
    refute_receive {_, {:push_event, "sim_frame", _}}, 50
  end

  describe "canvas drag editing (#34)" do
    test "renders the snap toggle, default off", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view
             |> has_element?("button[phx-click='toggle_snap'][aria-pressed='false']", "Snap grid")

      refute view |> has_element?("button[phx-click='toggle_snap'].is-active")
    end

    test "toggle_snap flips the assign and pushes snap_state to the hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_click(view, "toggle_snap")

      assert view
             |> has_element?("button[phx-click='toggle_snap'].is-active[aria-pressed='true']")

      assert_push_event(view, "snap_state", %{enabled: true})

      render_click(view, "toggle_snap")
      assert view |> has_element?("button[phx-click='toggle_snap'][aria-pressed='false']")
      assert_push_event(view, "snap_state", %{enabled: false})
    end

    test "commit_geometry moves a node and re-renders the frame", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      render_click(view, "commit_geometry", %{
        "kind" => "node",
        "id" => "tx1",
        "pos" => [1.5, -0.5]
      })

      assert_push_event(view, "sim_frame", %{nodes: nodes})
      tx = Enum.find(nodes, &(&1.id == "tx1"))
      assert tx.pos == [1.5, -0.5, 0.0]
      assert tx.vel == [0.0, 0.0, 0.0]
    end

    test "commit_geometry clamps out-of-bounds node positions server-side", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      render_click(view, "commit_geometry", %{
        "kind" => "node",
        "id" => "tx1",
        "pos" => [1000, -1000]
      })

      assert_push_event(view, "sim_frame", %{nodes: nodes, bounds: bounds})
      tx = Enum.find(nodes, &(&1.id == "tx1"))
      # Scenario bounds are min {-3, -3}, max {4.4, 3}; margin is 0.25.
      assert_in_delta Enum.at(tx.pos, 0), 4.65, 1.0e-9
      assert_in_delta Enum.at(tx.pos, 1), -3.25, 1.0e-9
      assert_position_in_bounds(tx.pos, bounds)
    end

    test "commit_geometry translates every vertex of a whole wall", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      # wall_x XY vertices: [-1.2, -2.6], [-1.2, 2.6], [-1.2, 2.6], [-1.2, -2.6]
      moved = [[-0.7, -2.35], [-0.7, 2.85], [-0.7, 2.85], [-0.7, -2.35]]

      render_click(view, "commit_geometry", %{
        "kind" => "wall",
        "id" => "wall_x",
        "vertices" => moved
      })

      assert_push_event(view, "sim_frame", %{walls: walls})
      wall = Enum.find(walls, &(&1.id == "wall_x"))
      assert Enum.map(wall.vertices, fn [x, y, _z] -> [x, y] end) == moved
      # z coordinates are preserved.
      assert Enum.map(wall.vertices, &Enum.at(&1, 2)) == [-1.0, -1.0, 1.0, 1.0]
    end

    test "commit_geometry endpoint drag respects the minimum wall length", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      # wall_y vertex 1 sits at [1.0, -1.2]; drop it onto vertex 0 [-2.6, -1.2].
      render_click(view, "commit_geometry", %{
        "kind" => "wall_vertex",
        "id" => "wall_y",
        "index" => 1,
        "pos" => [-2.6, -1.2]
      })

      assert_push_event(view, "sim_frame", %{walls: walls})
      wall = Enum.find(walls, &(&1.id == "wall_y"))
      [v0, v1 | _] = wall.vertices

      edge =
        :math.sqrt(
          (Enum.at(v1, 0) - Enum.at(v0, 0)) ** 2 + (Enum.at(v1, 1) - Enum.at(v0, 1)) ** 2
        )

      assert edge >= 0.1 - 1.0e-9
      # Only vertex 1 moved; its z is preserved.
      assert Enum.at(v1, 2) == -1.0
      assert Enum.at(wall.vertices, 2) == [1.0, -1.2, 1.0]
    end

    test "commit_geometry snaps to the grid only when the toggle is on", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      payload = %{"kind" => "node", "id" => "tx1", "pos" => [1.23, -0.77], "grid_step" => 0.5}

      # Snap off (default): the payload's grid_step is ignored.
      render_click(view, "commit_geometry", payload)
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [1.23, -0.77, 0.0]

      render_click(view, "toggle_snap")
      assert_push_event(view, "snap_state", %{enabled: true})

      render_click(view, "commit_geometry", payload)
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [1.0, -1.0, 0.0]
    end

    test "invalid or unknown-entity commits are rejected without a frame push", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      for payload <- [
            %{"kind" => "node", "id" => "nope", "pos" => [0, 0]},
            %{"kind" => "node", "id" => "tx1", "pos" => ["x", 0]},
            %{"kind" => "wall", "id" => "wall_x", "vertices" => [[0, 0]]},
            %{"kind" => "wall_vertex", "id" => "wall_x", "index" => 99, "pos" => [0, 0]},
            %{"kind" => "bogus"}
          ] do
        render_click(view, "commit_geometry", payload)
      end

      refute_receive {_, {:push_event, "sim_frame", _}}, 50
      assert view |> has_element?(".scene-panel .tick", "tick 0")
    end

    test "reset after a drag commit restores the scenario geometry", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      render_click(view, "commit_geometry", %{
        "kind" => "node",
        "id" => "tx1",
        "pos" => [1.5, -0.5]
      })

      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [1.5, -0.5, 0.0]

      render_click(view, "reset")
      assert_push_event(view, "sim_frame", %{tick: 0, nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [0.0, 0.0, 0.0]
    end
  end

  defp pause_and_drain(view) do
    render_click(view, "toggle")
    drain_frames(view)
  end

  # Pushed events are delivered to the test process by the client proxy.
  defp drain_frames(view) do
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:push_event, "sim_frame", _payload}} -> drain_frames(view)
    after
      0 -> :ok
    end
  end

  defp assert_position_in_bounds([x, y, _z], %{min: [min_x, min_y], max: [max_x, max_y]}) do
    assert x >= min_x and x <= max_x
    assert y >= min_y and y <= max_y
  end
end
