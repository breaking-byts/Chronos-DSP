defmodule ChronosWeb.SimLiveTest do
  use ChronosWeb.ConnCase, async: true

  test "sim live assigns include metrics and history", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "BER"
    assert html =~ "Paths"

    history_count =
      view
      |> Phoenix.LiveViewTest.render()
      |> Floki.parse_document!()
      |> Floki.find("[data-history-count]")
      |> Floki.attribute("data-history-count")
      |> List.first()

    assert is_binary(history_count)
    {count, ""} = Integer.parse(history_count)
    assert count <= 60
    assert render_click(view, "step") =~ "BER"
  end

  test "scene_bounds returns defaults for empty world" do
    world = Chronos.World.new()

    assert ChronosWeb.SimLive.scene_bounds(world) == %{
             min: {-5.0, -5.0},
             max: {5.0, 5.0}
           }
  end

  test "root layout includes liveview client", %{conn: conn} do
    conn = get(conn, "/")
    html = html_response(conn, 200)
    assert html =~ "csrf-token"
    assert html =~ "liveSocket.connect"
  end

  test "phoenix static assets are served", %{conn: conn} do
    conn = get(conn, "/phoenix/phoenix.js")
    assert conn.status == 200
    assert conn.resp_body =~ "Socket"

    conn = get(conn, "/live/phoenix_live_view.js")
    assert conn.status == 200
    assert conn.resp_body =~ "LiveSocket"
  end
end
