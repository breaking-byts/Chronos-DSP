defmodule ChronosWeb.SimLiveSceneTest do
  # The endpoint, the global SimSupervisor and the scene-dir Application env
  # are shared state.
  use ChronosWeb.ConnCase, async: false

  alias Chronos.SceneStore

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "chronos-sim-live-scenes-#{System.unique_integer([:positive])}"
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

  describe "scene save/load UI (#36)" do
    test "renders the scenes panel: counter, save form, picker and eviction note", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert view |> has_element?(".scenes-panel h2", "Scenes")
      assert view |> has_element?(".scene-count", "0/100 scenes")
      assert view |> has_element?("form#scene-save[phx-submit='save_scene']")
      assert view |> has_element?("#scene-name[phx-change='set_scene_name'][maxlength='64']")
      assert view |> has_element?("form#scene-save button[type='submit']", "Save scene")
      assert html =~ "No saved scenes yet"
      assert html =~ "evicted first"
      assert html =~ "ephemeral"
      assert view |> has_element?(".scene-state", "Clean")
      refute view |> has_element?(".dirty-dot")
    end

    test "save persists the edited world, clears dirty; load replaces the world", %{
      conn: conn,
      dir: dir
    } do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      refute view |> has_element?(".dirty-dot")

      render_click(view, "commit_geometry", %{
        "kind" => "node",
        "id" => "tx1",
        "pos" => [1.5, -0.5]
      })

      assert_push_event(view, "sim_frame", %{nodes: _})
      assert view |> has_element?(".dirty-dot")
      assert view |> has_element?(".scene-state.is-dirty")

      html = view |> form("form#scene-save", %{"name" => "my_lab"}) |> render_submit()

      assert html =~ "Saved scene &quot;my_lab&quot;."
      assert File.exists?(Path.join(dir, "my_lab.json"))
      assert view |> has_element?(".scene-count", "1/100 scenes")

      assert view
             |> has_element?("button[phx-click='load_scene'][phx-value-name='my_lab']", "my_lab")

      refute view |> has_element?(".dirty-dot")
      # The name input clears after a successful save.
      assert view |> has_element?("#scene-name[value='']")

      assert {:ok, scene} = SceneStore.get("my_lab")
      tx = Enum.find(scene["nodes"], &(&1["id"] == "tx1"))
      assert tx["pos"] == [1.5, -0.5, 0.0]

      # Edit again, then load the saved scene: the world is replaced.
      render_click(view, "commit_geometry", %{
        "kind" => "node",
        "id" => "tx1",
        "pos" => [2.0, 2.0]
      })

      assert_push_event(view, "sim_frame", %{nodes: _})
      assert view |> has_element?(".dirty-dot")

      html = render_click(view, "load_scene", %{"name" => "my_lab"})
      assert html =~ "Loaded scene"

      assert_push_event(view, "sim_frame", %{nodes: nodes})
      assert Enum.find(nodes, &(&1.id == "tx1")).pos == [1.5, -0.5, 0.0]
      refute view |> has_element?(".dirty-dot")

      # The undo hook (#37) is cleared on save and load; the baseline matches.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.undo_stack == []
      assert assigns.scene_dirty == false
    end

    test "round-trip preserves wall material, attenuation override and z", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      render_change(view, "set_wall_material", %{"id" => "wall_x", "value" => "glass"})
      assert_push_event(view, "sim_frame", %{walls: _})
      render_change(view, "set_wall_attenuation", %{"id" => "wall_x", "value" => "25"})
      assert_push_event(view, "sim_frame", %{walls: _})
      render_change(view, "set_wall_z", %{"id" => "wall_x", "value" => "2.0"})
      assert_push_event(view, "sim_frame", %{walls: _})
      assert view |> has_element?(".dirty-dot")

      view |> form("form#scene-save", %{"name" => "walls_lab"}) |> render_submit()
      assert {:ok, scene} = SceneStore.get("walls_lab")
      wall = Enum.find(scene["walls"], &(&1["id"] == "wall_x"))
      assert wall["material"] == "glass"
      assert wall["attenuation_db"] == 25.0

      # Reset rewinds to the scenario wall, then loading restores the edits.
      render_click(view, "reset")
      assert_push_event(view, "sim_frame", %{walls: walls})
      assert Enum.find(walls, &(&1.id == "wall_x")).material == "brick"
      refute view |> has_element?(".dirty-dot")

      render_click(view, "load_scene", %{"name" => "walls_lab"})
      assert_push_event(view, "sim_frame", %{walls: walls})
      wall = Enum.find(walls, &(&1.id == "wall_x"))
      assert wall.material == "glass"
      assert wall.attenuation_db == 25.0
      zs = Enum.map(wall.vertices, &Enum.at(&1, 2))
      assert_in_delta Enum.sum(zs) / length(zs), 2.0, 1.0e-9
      refute view |> has_element?(".dirty-dot")
    end

    test "dirty dot follows panel edits and clears on reset and scenario switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      render_change(view, "set_wall_material", %{"id" => "wall_x", "value" => "glass"})
      assert_push_event(view, "sim_frame", %{walls: _})
      assert view |> has_element?(".dirty-dot")

      render_click(view, "reset")
      assert_push_event(view, "sim_frame", %{walls: _})
      refute view |> has_element?(".dirty-dot")
      assert :sys.get_state(view.pid).socket.assigns.undo_stack == []

      render_click(view, "commit_geometry", %{
        "kind" => "node",
        "id" => "tx1",
        "pos" => [1.5, -0.5]
      })

      assert_push_event(view, "sim_frame", %{nodes: _})
      assert view |> has_element?(".dirty-dot")

      render_click(view, "scenario", %{"id" => "open_field"})
      assert_push_event(view, "sim_frame", %{nodes: _})
      refute view |> has_element?(".dirty-dot")
    end

    test "simulation ticks alone never light the dirty dot", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # The orbit scenario moves nodes every tick; that is motion, not edits.
      Process.sleep(350)
      drain_frames(view)

      refute view |> has_element?(".dirty-dot")
      assert :sys.get_state(view.pid).socket.assigns.scene_dirty == false
    end

    test "invalid names surface a friendly error and save nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      for name <- ["Bad Name!", "../evil", "", String.duplicate("a", 65)] do
        html = view |> form("form#scene-save", %{"name" => name}) |> render_submit()
        assert html =~ "Invalid scene name"
        assert view |> has_element?(".banner-error[role='alert']")
      end

      assert view |> has_element?(".scene-count", "0/100 scenes")
      assert SceneStore.list() == []
      refute view |> has_element?(".dirty-dot")

      # A valid save afterwards replaces the error with a success message.
      html = view |> form("form#scene-save", %{"name" => "good_name"}) |> render_submit()
      assert html =~ "Saved scene"
      refute view |> has_element?(".banner-error")
      assert view |> has_element?(".scene-count", "1/100 scenes")
    end

    test "loading a missing or invalid scene errors without touching the world", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      render_click(view, "commit_geometry", %{
        "kind" => "node",
        "id" => "tx1",
        "pos" => [1.5, -0.5]
      })

      assert_push_event(view, "sim_frame", %{nodes: _})
      assert view |> has_element?(".dirty-dot")

      html = render_click(view, "load_scene", %{"name" => "ghost"})
      assert html =~ "was not found"
      assert view |> has_element?(".dirty-dot")

      html = render_click(view, "load_scene", %{"name" => "UPPER"})
      assert html =~ "Invalid scene name"
      assert view |> has_element?(".dirty-dot")

      # The edited world is intact.
      {:ok, world, _bounds} =
        Chronos.SimServer.get_world(:sys.get_state(view.pid).socket.assigns.sim)

      assert Chronos.World.node(world, :tx1).pos == {1.5, -0.5, 0.0}
    end

    test "delete removes a scene and refreshes the counter", %{conn: conn, dir: dir} do
      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      view |> form("form#scene-save", %{"name" => "del_me"}) |> render_submit()
      assert view |> has_element?(".scene-count", "1/100 scenes")

      html = render_click(view, "delete_scene", %{"name" => "del_me"})
      assert html =~ "Deleted scene"
      assert view |> has_element?(".scene-count", "0/100 scenes")
      refute File.exists?(Path.join(dir, "del_me.json"))
      assert html =~ "No saved scenes yet"

      html = render_click(view, "delete_scene", %{"name" => "del_me"})
      assert html =~ "was not found"
    end

    test "saving at the 100-scene cap evicts the oldest and says so", %{conn: conn, dir: dir} do
      for i <- 0..99 do
        name = "scene_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        :ok = SceneStore.save(minimal_scene(name))
        # Stagger mtimes so scene_000 is unambiguously the oldest.
        File.touch!(Path.join(dir, name <> ".json"), {{2020, 1, 1}, {0, div(i, 60), rem(i, 60)}})
      end

      {:ok, view, _html} = live(conn, "/")
      assert view |> has_element?(".scene-count", "100/100 scenes")
      pause_and_drain(view)

      html = view |> form("form#scene-save", %{"name" => "fresh_scene"}) |> render_submit()

      assert html =~ "Saved scene"
      assert html =~ "oldest scene was evicted"
      assert view |> has_element?(".scene-count", "100/100 scenes")
      assert length(SceneStore.list()) == 100
      assert {:error, :not_found} = SceneStore.get("scene_000")
      refute File.exists?(Path.join(dir, "scene_000.json"))
      assert File.exists?(Path.join(dir, "fresh_scene.json"))
      refute view |> has_element?(".dirty-dot")
    end

    test "overwriting an existing name at the cap does not report eviction", %{
      conn: conn,
      dir: dir
    } do
      for i <- 0..99 do
        name = "scene_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        :ok = SceneStore.save(minimal_scene(name))
        File.touch!(Path.join(dir, name <> ".json"), {{2020, 1, 1}, {0, div(i, 60), rem(i, 60)}})
      end

      {:ok, view, _html} = live(conn, "/")
      pause_and_drain(view)

      # Re-save scene_050 (already present) at the 100-cap: make_room excludes
      # the scene's own name, so nothing is evicted and the message must not
      # claim otherwise.
      html = view |> form("form#scene-save", %{"name" => "scene_050"}) |> render_submit()

      assert html =~ "Saved scene"
      refute html =~ "evicted to make room"
      assert length(SceneStore.list()) == 100
      assert {:ok, _} = SceneStore.get("scene_050")
      assert {:ok, _} = SceneStore.get("scene_000")
      assert File.exists?(Path.join(dir, "scene_000.json"))
    end
  end

  defp minimal_scene(name) do
    %{
      "name" => name,
      "nodes" => [
        %{"id" => "tx1", "type" => "tx", "pos" => [0.0, 0.0, 0.0], "vel" => [0.0, 0.0, 0.0]},
        %{"id" => "rx1", "type" => "rx", "pos" => [3.0, 0.0, 0.0], "vel" => [0.0, 0.0, 0.0]}
      ],
      "walls" => []
    }
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
end
