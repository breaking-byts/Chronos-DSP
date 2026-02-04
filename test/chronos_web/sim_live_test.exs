defmodule ChronosWeb.SimLiveTest do
  use ChronosWeb.ConnCase, async: true

  test "pushes sim frames", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert_push_event(view, "sim_frame", %{tick: 0, nodes: _, walls: _})
  end

  test "layout includes UI assets", %{conn: conn} do
    conn = get(conn, "/")
    html = html_response(conn, 200)
    assert html =~ "/assets/app.js"
    assert html =~ "/assets/app.css"
    assert html =~ "pixi"
    assert html =~ "echarts"
  end

  test "layout includes spatial scene columns", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "class=\"sim-layout\""
    assert html =~ "class=\"sim-left\""
    assert html =~ "class=\"sim-right\""
  end

  test "renders canvas and chart containers", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "id=\"sim-canvas\""
    assert html =~ "id=\"dsp-charts\""
    assert html =~ "phx-hook=\"SimCanvas\""
    assert html =~ "phx-hook=\"DspCharts\""
  end

  test "renders individual chart panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "id=\"chart-constellation\""
    assert html =~ "id=\"chart-spectrum\""
    assert html =~ "id=\"chart-waveform\""
  end

  test "controls toggle simulation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert render_click(view, "toggle") =~ "Running"
    assert render_click(view, "toggle") =~ "Pause"
  end

  test "renders and handles step", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Chronos-DSP Prototype"
    assert render_click(view, "step") =~ "BER"
  end
end
