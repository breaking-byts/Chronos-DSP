defmodule ChronosWeb.SceneControllerTest do
  use ChronosWeb.ConnCase, async: false

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "chronos-scene-controller-#{System.unique_integer([:positive])}"
      )

    previous_dir = Application.fetch_env(:chronos, :scene_dir)
    Application.put_env(:chronos, :scene_dir, dir)

    on_exit(fn ->
      restore_application_env(:chronos, :scene_dir, previous_dir)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  test "POST stores a valid scene and returns it", %{dir: dir} do
    scene = valid_scene()

    conn = post_scene(build_conn(), scene)

    assert conn.status == 201
    assert %{"scene" => saved} = json_response(conn, 201)
    assert saved["name"] == "controller_scene"
    assert File.exists?(Path.join(dir, "controller_scene.json"))
  end

  test "GET returns a stored scene" do
    assert :ok = Chronos.SceneStore.save(valid_scene())

    conn = get(build_conn(), "/api/scenes/controller_scene")

    assert conn.status == 200
    assert %{"name" => "controller_scene", "nodes" => nodes} = json_response(conn, 200)
    assert length(nodes) == 2
  end

  test "GET lists stored scenes" do
    assert :ok = Chronos.SceneStore.save(valid_scene())

    conn = get(build_conn(), "/api/scenes")

    assert conn.status == 200
    assert %{"scenes" => [%{"name" => "controller_scene"}]} = json_response(conn, 200)
  end

  test "GET rejects a trailing-slash scene name instead of listing scenes" do
    conn = get(build_conn(), "/api/scenes/")

    assert conn.status == 400
    assert %{"error" => "invalid_name"} = json_response(conn, 400)
  end

  test "POST rejects a name that is already taken" do
    assert :ok = Chronos.SceneStore.save(valid_scene())

    conn = post_scene(build_conn(), valid_scene())

    assert conn.status == 409
    assert %{"error" => "name_taken"} = json_response(conn, 409)
  end

  test "POST rejects an invalid scene" do
    invalid_scene = %{valid_scene() | "nodes" => []}

    conn = post_scene(build_conn(), invalid_scene)

    assert conn.status == 400
    assert %{"error" => "invalid_scene"} = json_response(conn, 400)
  end

  test "POST rejects an invalid scene name before validating the rest of the scene" do
    invalid_scene = %{valid_scene() | "name" => "UPPER", "nodes" => []}

    conn = post_scene(build_conn(), invalid_scene)

    assert conn.status == 400
    assert %{"error" => "invalid_name"} = json_response(conn, 400)
  end

  test "concurrent POSTs persist one complete scene without server errors", %{dir: dir} do
    for iteration <- 1..10 do
      name = "concurrent_scene_#{iteration}"
      first_scene = %{valid_scene() | "name" => name, "description" => "first"}
      second_scene = %{valid_scene() | "name" => name, "description" => "second"}

      first_task = Task.async(fn -> post_scene(build_conn(), first_scene) end)
      second_task = Task.async(fn -> post_scene(build_conn(), second_scene) end)

      responses = [Task.await(first_task), Task.await(second_task)]

      assert Enum.sort(Enum.map(responses, & &1.status)) == [201, 409]

      persisted_scene =
        Path.join(dir, "#{name}.json")
        |> File.read!()
        |> Jason.decode!()

      assert persisted_scene["description"] in ["first", "second"]

      for response <- responses, response.status == 201 do
        response_body = Jason.decode!(response.resp_body)
        assert response_body["scene"]["description"] == persisted_scene["description"]
      end
    end
  end

  test "GET returns not_found for an unknown scene" do
    conn = get(build_conn(), "/api/scenes/unknown_scene")

    assert conn.status == 404
    assert %{"error" => "not_found"} = json_response(conn, 404)
  end

  test "GET rejects an invalid scene name" do
    conn = get(build_conn(), "/api/scenes/UPPER")

    assert conn.status == 400
    assert %{"error" => "invalid_name"} = json_response(conn, 400)
  end

  test "DELETE removes a scene and GET then returns not_found" do
    assert :ok = Chronos.SceneStore.save(valid_scene())

    conn = delete(build_conn(), "/api/scenes/controller_scene")
    assert conn.status == 204
    assert conn.resp_body == ""

    missing_conn = get(build_conn(), "/api/scenes/controller_scene")
    assert missing_conn.status == 404
    assert %{"error" => "not_found"} = json_response(missing_conn, 404)
  end

  test "DELETE rejects an invalid scene name" do
    conn = delete(build_conn(), "/api/scenes/UPPER")

    assert conn.status == 400
    assert %{"error" => "invalid_name"} = json_response(conn, 400)
  end

  test "POST rejects a query string via the endpoint-wide API rules" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/scenes?foo=bar", Jason.encode!(valid_scene()))

    assert conn.status == 400
    assert %{"error" => error} = json_response(conn, 400)
    assert error =~ "query parameters"
  end

  test "POST rejects reserved underscore fields via the endpoint-wide API rules" do
    scene = Map.put(valid_scene(), "_method", "delete")
    conn = post_scene(build_conn(), scene)

    assert conn.status == 400
    assert %{"error" => "reserved field"} = json_response(conn, 400)
  end

  test "40 concurrent POSTs of one name yield exactly one 201", %{dir: dir} do
    name = "race_scene"

    tasks =
      for i <- 1..40 do
        Task.async(fn ->
          post_scene(build_conn(), %{valid_scene() | "name" => name, "description" => "c#{i}"})
        end)
      end

    statuses = tasks |> Enum.map(&Task.await/1) |> Enum.map(& &1.status)

    assert Enum.count(statuses, &(&1 == 201)) == 1
    assert Enum.count(statuses, &(&1 == 409)) == 39
    assert length(Chronos.SceneStore.list()) == 1
  end

  defp post_scene(conn, scene) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/scenes", Jason.encode!(scene))
  end

  defp valid_scene do
    %{
      "name" => "controller_scene",
      "description" => "A scene created through the JSON API.",
      "nodes" => [
        %{
          "id" => "tx1",
          "type" => "tx",
          "pos" => [0.0, 0.0, 0.0],
          "vel" => [0.0, 0.0, 0.0]
        },
        %{
          "id" => "rx1",
          "type" => "rx",
          "pos" => [1.0, 0.0, 0.0],
          "vel" => [0.0, 0.0, 0.0]
        }
      ],
      "walls" => []
    }
  end

  defp restore_application_env(app, key, {:ok, value}) do
    Application.put_env(app, key, value)
  end

  defp restore_application_env(app, key, :error) do
    Application.delete_env(app, key)
  end
end
