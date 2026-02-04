defmodule ChronosWeb.SimLiveTest do
  use ChronosWeb.ConnCase, async: true

  test "sim live assigns include metrics and history", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "BER"
    assert html =~ "Paths"
    assert is_map(:sys.get_state(view.pid).socket.assigns.metrics)
    assert is_list(:sys.get_state(view.pid).socket.assigns.history)
    assert length(:sys.get_state(view.pid).socket.assigns.history) <= 60
    assert render_click(view, "step") =~ "BER"
  end
end
