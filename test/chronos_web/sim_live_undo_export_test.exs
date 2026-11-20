defmodule ChronosWeb.SimLiveUndoExportTest do
  # The endpoint, the global SimSupervisor and the scene-dir Application env
  # are shared state.
  use ChronosWeb.ConnCase, async: false

  alias Chronos.SceneStore

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "chronos-undo-export-#{System.unique_integer([:positive])}"
      )

    previous_dir = Application.fetch_env(:chronos, :scene_dir)
    Application.put_env(:chronos, :scene_dir, dir)

    on_exit(fn ->
      case previous_dir do
        {:ok, value} -> Application.put_env(:chronos, :scene_dir, value)
        :error -> Application.delete_env(:chronos, :scene_dir)
      end

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  describe "undo (#37)" do
    test "renders a disabled Undo button that enables after an edit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert view |> has_element?("button[phx-click='undo'][disabled]", "Undo")

      pause_reset_drain(view)
      drag_tx1(view, [1.5, -0.5])

      refute view |> has_element?("button[phx-click='undo'][disabled]")
      assert view |> has_element?("button[phx-click='undo']", "Undo")
      assert length(assigns(view).undo_stack) == 1
    end

    test "undo restores the pre-drag world and the dirty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      drag_tx1(view, [1.5, -0.5])
      assert view |> has_element?(".dirty-dot")

      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [0.0, 0.0, 0.0]
      # Back to the baseline geometry: the dirty dot clears and the stack empties.
      refute view |> has_element?(".dirty-dot")
      assert assigns(view).undo_stack == []
      assert assigns(view).scene_dirty == false
      assert view |> has_element?("button[phx-click='undo'][disabled]")
    end

    test "undo pops one entry at a time across mixed drag/panel edits", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      drag_tx1(view, [1.5, -0.5])
      render_change(view, "set_wall_material", %{"id" => "wall_x", "value" => "metal"})
      assert_push_event(view, "sim_frame", %{walls: _})
      render_click(view, "add_wall")
      assert_push_event(view, "sim_frame", %{walls: _})
      assert length(assigns(view).undo_stack) == 3

      # Pop the add_wall: the metal wall and the dragged node remain.
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{walls: walls, nodes: nodes})
      assert length(walls) == 2
      assert Enum.find(walls, &(&1.id == "wall_x")).material == "metal"
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [1.5, -0.5, 0.0]
      assert view |> has_element?(".dirty-dot")

      # Pop the material change: brick returns, the drag remains.
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{walls: walls, nodes: nodes})
      assert Enum.find(walls, &(&1.id == "wall_x")).material == "brick"
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [1.5, -0.5, 0.0]
      assert view |> has_element?(".dirty-dot")

      # Pop the drag: fully clean again.
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [0.0, 0.0, 0.0]
      refute view |> has_element?(".dirty-dot")
      assert assigns(view).undo_stack == []
    end

    test "undo covers attenuation, z, wall z and remove_wall edits", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      # Park the receiver (a drag commit zeroes velocity, #34) and re-baseline
      # via save, so the edit/undo cycles below cannot drift away from the
      # baseline through custom stepping between renders.
      render_click(view, "commit_geometry", %{
        "kind" => "node",
        "id" => "rx1",
        "pos" => [3.0, 0.0]
      })

      assert_push_event(view, "sim_frame", %{nodes: _})
      view |> form("form#scene-save", %{"name" => "undo_park"}) |> render_submit()
      refute view |> has_element?(".dirty-dot")

      render_change(view, "set_wall_attenuation", %{"id" => "wall_x", "value" => "25"})
      assert_push_event(view, "sim_frame", %{walls: _})
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{walls: walls})
      wall = Enum.find(walls, &(&1.id == "wall_x"))
      assert wall.attenuation_db == nil
      assert wall.loss_db == 4.0

      render_change(view, "set_node_z", %{"id" => "tx1", "value" => "2.5"})
      assert_push_event(view, "sim_frame", %{nodes: _})
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [0.0, 0.0, 0.0]

      render_change(view, "set_wall_z", %{"id" => "wall_x", "value" => "3"})
      assert_push_event(view, "sim_frame", %{walls: _})
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{walls: walls})

      assert Enum.map(Enum.find(walls, &(&1.id == "wall_x")).vertices, &Enum.at(&1, 2)) ==
               [-1.0, -1.0, 1.0, 1.0]

      render_click(view, "remove_wall", %{"id" => "wall_y"})
      assert_push_event(view, "sim_frame", %{walls: walls})
      assert length(walls) == 1
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{walls: walls})
      assert length(walls) == 2
      assert Enum.any?(walls, &(&1.id == "wall_y"))

      refute view |> has_element?(".dirty-dot")
      assert assigns(view).undo_stack == []
    end

    test "the stack caps at 50 entries and drops the oldest beyond the cap", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      # 55 distinct drag commits: only the last 50 pre-edit worlds survive.
      for i <- 1..55 do
        render_click(view, "commit_geometry", %{
          "kind" => "node",
          "id" => "tx1",
          "pos" => [i / 100, 0.0]
        })
      end

      drain_frames(view)
      assert length(assigns(view).undo_stack) == 50

      # The newest entry is the pre-edit world of commit 55 (tx1 at 0.54).
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert_in_delta Enum.at(Enum.find(nodes, &(&1.id == "tx1")).pos, 0), 0.54, 1.0e-9

      # 49 more undos reach the oldest retained entry: pre-edit of commit 6
      # (tx1 at 0.05). Commits 1–5 fell off the cap and are unreachable.
      for _ <- 1..49, do: render_click(view, "undo")
      drain_frames(view)
      assert assigns(view).undo_stack == []

      render_click(view, "step")
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert_in_delta Enum.at(Enum.find(nodes, &(&1.id == "tx1")).pos, 0), 0.05, 1.0e-9

      # Empty stack: further undos are no-ops.
      render_click(view, "undo")
      refute_receive {_, {:push_event, "sim_frame", _}}, 50
    end

    test "undo with an empty stack is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      render_click(view, "undo")
      refute_receive {_, {:push_event, "sim_frame", _}}, 50
      assert view |> has_element?(".scene-panel .tick", "tick 0")
    end

    test "reset clears the undo stack", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      drag_tx1(view, [1.5, -0.5])
      render_change(view, "set_wall_material", %{"id" => "wall_x", "value" => "metal"})
      assert_push_event(view, "sim_frame", %{walls: _})
      assert length(assigns(view).undo_stack) == 2

      render_click(view, "reset")
      assert_push_event(view, "sim_frame", %{tick: 0})
      assert assigns(view).undo_stack == []
      assert view |> has_element?("button[phx-click='undo'][disabled]")

      render_click(view, "undo")
      refute_receive {_, {:push_event, "sim_frame", _}}, 50
    end

    test "switching scenario clears the undo stack", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      drag_tx1(view, [1.5, -0.5])
      assert length(assigns(view).undo_stack) == 1

      render_click(view, "scenario", %{"id" => "open_field"})
      assert_push_event(view, "sim_frame", %{tick: 0})
      assert assigns(view).undo_stack == []
      assert view |> has_element?("button[phx-click='undo'][disabled]")
    end

    test "save and load clear the undo stack", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      drag_tx1(view, [1.5, -0.5])
      assert length(assigns(view).undo_stack) == 1

      view |> form("form#scene-save", %{"name" => "undo_lab"}) |> render_submit()
      assert assigns(view).undo_stack == []

      drag_tx1(view, [2.0, 2.0])
      assert length(assigns(view).undo_stack) == 1

      render_click(view, "load_scene", %{"name" => "undo_lab"})
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [1.5, -0.5, 0.0]
      assert assigns(view).undo_stack == []

      render_click(view, "undo")
      refute_receive {_, {:push_event, "sim_frame", _}}, 50
    end

    test "Ctrl/Cmd+Z wiring: UndoKeys hook on the shell with input guards" do
      {:ok, view, html} = live(build_conn(), "/")
      assert view |> has_element?("#app-shell[phx-hook='UndoKeys']")
      assert html =~ "Ctrl/Cmd+Z"

      body = build_conn() |> get("/assets/app.js") |> response(200)
      assert body =~ "UndoKeys"
      assert body =~ "SimCanvas, DspCharts, UndoKeys"
      assert body =~ "keydown"
      assert body =~ "ctrlKey"
      assert body =~ "metaKey"
      # Redo (Shift+Z) stays deferred; text inputs keep their native undo.
      assert body =~ "shiftKey"
      assert body =~ "TEXTAREA"
      assert body =~ "isContentEditable"
      assert body =~ ~s|this.pushEvent("undo", {})|
    end
  end

  describe "revert to saved (#37)" do
    test "renders a disabled Revert button that enables while dirty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view
             |> has_element?("button[phx-click='revert_to_saved'][disabled]", "Revert to saved")

      pause_reset_drain(view)
      drag_tx1(view, [1.5, -0.5])
      refute view |> has_element?("button[phx-click='revert_to_saved'][disabled]")
    end

    test "revert restores the starting scenario world when nothing was saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      drag_tx1(view, [1.5, -0.5])
      render_change(view, "set_wall_material", %{"id" => "wall_x", "value" => "metal"})
      assert_push_event(view, "sim_frame", %{walls: _})
      assert view |> has_element?(".dirty-dot")

      render_click(view, "revert_to_saved")
      assert_push_event(view, "sim_frame", %{nodes: nodes, walls: walls})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [0.0, 0.0, 0.0]
      assert Enum.find(walls, &(&1.id == "wall_x")).material == "brick"
      refute view |> has_element?(".dirty-dot")
      assert assigns(view).undo_stack == []
      assert view |> has_element?("button[phx-click='revert_to_saved'][disabled]")
    end

    test "revert restores the last saved snapshot, not the scenario", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      drag_tx1(view, [1.5, -0.5])
      view |> form("form#scene-save", %{"name" => "rev_lab"}) |> render_submit()
      refute view |> has_element?(".dirty-dot")

      drag_tx1(view, [2.5, 1.0])
      render_click(view, "add_wall")
      assert_push_event(view, "sim_frame", %{walls: _})
      assert view |> has_element?(".dirty-dot")
      assert length(assigns(view).undo_stack) == 2

      render_click(view, "revert_to_saved")
      assert_push_event(view, "sim_frame", %{nodes: nodes, walls: walls})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [1.5, -0.5, 0.0]
      assert length(walls) == 2
      refute view |> has_element?(".dirty-dot")
      assert assigns(view).undo_stack == []
    end

    test "revert after load restores the loaded snapshot", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      :ok = SceneStore.save(stored_scene("rev_load", [2.0, 1.0, 0.0]))
      render_click(view, "load_scene", %{"name" => "rev_load"})
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [2.0, 1.0, 0.0]

      drag_tx1(view, [0.5, 0.5])
      assert view |> has_element?(".dirty-dot")

      render_click(view, "revert_to_saved")
      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [2.0, 1.0, 0.0]
      refute view |> has_element?(".dirty-dot")
      assert assigns(view).undo_stack == []
    end

    test "revert is a no-op while clean", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)

      render_click(view, "revert_to_saved")
      refute_receive {_, {:push_event, "sim_frame", _}}, 50
      assert assigns(view).undo_stack == []

      # Edit, undo back to clean: revert stays disabled and inert.
      drag_tx1(view, [1.5, -0.5])
      render_click(view, "undo")
      assert_push_event(view, "sim_frame", %{nodes: _})
      refute view |> has_element?(".dirty-dot")
      assert view |> has_element?("button[phx-click='revert_to_saved'][disabled]")

      render_click(view, "revert_to_saved")
      refute_receive {_, {:push_event, "sim_frame", _}}, 50
    end
  end

  describe "export CSV menu (#37)" do
    test "renders the Export CSV control in the control bar; menu toggles", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view
             |> has_element?(
               ".controls .button-row button[phx-click='toggle_export_menu'][aria-expanded='false']",
               "Export CSV"
             )

      refute view |> has_element?(".export-menu")

      html = render_click(view, "toggle_export_menu")
      assert html =~ "export-menu"
      assert view |> has_element?(".export-menu[role='menu']")
      assert view |> has_element?("button[phx-click='toggle_export_menu'][aria-expanded='true']")

      for label <- ["Metrics (current tick)", "History (ticks 0–100)", "Samples (current tick)"] do
        assert view |> has_element?(".export-menu a[role='menuitem']", label)
      end

      render_click(view, "toggle_export_menu")
      refute view |> has_element?(".export-menu")
    end

    test "menu links carry the live scenario/seed/tx_power/tick params", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)
      render_click(view, "toggle_export_menu")

      links = menu_links(view)

      assert %{"scenario" => "orbit", "seed" => "7", "tx_power" => "10", "ticks" => "0"} =
               query(links["metrics"])

      assert %{"from" => "0", "to" => "100", "step" => "1", "scenario" => "orbit", "seed" => "7"} =
               query(links["history"])

      assert %{"ticks" => "0", "limit" => "128", "tx_power" => "10"} = query(links["samples"])

      # Live opts flow into the links: TX power, tick and scenario.
      render_change(view, "set_tx_power", %{"value" => "20"})
      assert query(menu_links(view)["metrics"])["tx_power"] == "20"

      render_click(view, "step")
      assert_push_event(view, "sim_frame", %{tick: 1})
      assert query(menu_links(view)["metrics"])["ticks"] == "1"
      assert query(menu_links(view)["samples"])["ticks"] == "1"

      render_click(view, "scenario", %{"id" => "open_field"})
      assert_push_event(view, "sim_frame", %{tick: 0})
      links = menu_links(view)
      assert query(links["metrics"])["scenario"] == "open_field"
      assert query(links["history"])["scenario"] == "open_field"
      assert query(links["samples"])["scenario"] == "open_field"
    end

    test "an edited world shows the custom-world note; reset clears it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)
      render_click(view, "toggle_export_menu")

      refute view |> has_element?(".export-note.is-warning")
      assert view |> has_element?(".export-note")

      drag_tx1(view, [1.5, -0.5])
      assert view |> has_element?(".export-note.is-warning")
      html = render(view)
      assert html =~ "not your edits"
      assert html =~ "Orbit + corner walls"
      # The links stay available — labelled as the built-in scenario export.
      assert map_size(menu_links(view)) == 3

      render_click(view, "reset")
      assert_push_event(view, "sim_frame", %{tick: 0})
      refute view |> has_element?(".export-note.is-warning")
      assert map_size(menu_links(view)) == 3
    end

    test "menu links hit the live export endpoints and return CSV", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_reset_drain(view)
      render_change(view, "set_tx_power", %{"value" => "20"})
      render_click(view, "toggle_export_menu")

      links = menu_links(view)
      csv_conn = put_req_header(conn, "accept", "text/csv")

      metrics = csv_conn |> get(links["metrics"]) |> response(200)
      assert String.starts_with?(metrics, "tick,time_s,rx_id,path_count,received_power,ber")

      history = csv_conn |> get(links["history"]) |> response(200)
      assert String.starts_with?(history, "tick,time_s,rx_id,path_count,received_power,ber")
      # from=0..to=100 step=1 → 101 rows + header.
      assert length(String.split(history, "\n", trim: true)) == 102

      samples = csv_conn |> get(links["samples"]) |> response(200)
      assert String.starts_with?(samples, "index,re,im")
      assert length(String.split(samples, "\n", trim: true)) == 129
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp drag_tx1(view, pos) do
    render_click(view, "commit_geometry", %{"kind" => "node", "id" => "tx1", "pos" => pos})
    assert_push_event(view, "sim_frame", %{nodes: _})
  end

  # Pause, then reset so the dirty baseline exactly matches the live world
  # (the first mount tick advances the orbit before the pause lands).
  defp pause_reset_drain(view) do
    render_click(view, "toggle")
    render_click(view, "reset")
    drain_frames(view)
  end

  defp drain_frames(view) do
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:push_event, "sim_frame", _payload}} -> drain_frames(view)
    after
      0 -> :ok
    end
  end

  # The three menu hrefs keyed by endpoint, parsed out of the rendered HTML.
  defp menu_links(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(".export-menu a")
    |> Floki.attribute("href")
    |> Map.new(fn href ->
      [path, _query] = String.split(href, "?", parts: 2)
      {Path.basename(path), href}
    end)
  end

  defp query(href) do
    [_path, query] = String.split(href, "?", parts: 2)
    URI.decode_query(query)
  end

  defp stored_scene(name, tx_pos) do
    %{
      "name" => name,
      "nodes" => [
        %{"id" => "tx1", "type" => "tx", "pos" => tx_pos, "vel" => [0.0, 0.0, 0.0]},
        %{"id" => "rx1", "type" => "rx", "pos" => [3.0, 0.0, 0.0], "vel" => [0.0, 0.0, 0.0]}
      ],
      "walls" => []
    }
  end
end
