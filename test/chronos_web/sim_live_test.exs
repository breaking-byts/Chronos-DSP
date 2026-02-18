defmodule ChronosWeb.SimLiveTest do
  use ChronosWeb.ConnCase, async: true

  test "renders and handles step", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Chronos-DSP Prototype"
    assert render_click(view, "step") =~ "BER"
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
