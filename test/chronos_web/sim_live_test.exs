defmodule ChronosWeb.SimLiveTest do
  use ChronosWeb.ConnCase, async: true

  test "pushes sim frames", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert_push_event(view, "sim_frame", %{tick: 0, nodes: _, walls: _})
  end

  test "renders and handles step", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Chronos-DSP Prototype"
    assert render_click(view, "step") =~ "BER"
  end
end
