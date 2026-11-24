defmodule ChronosWeb.SimLiveStaleFrameTest do
  use ChronosWeb.ConnCase, async: false

  alias Chronos.SimSupervisor

  test "scenario and reset push fresh frames after the session dies", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert_push_event(view, "sim_frame", %{tick: 0}, 500)

    pid = :sys.get_state(view.pid).socket.assigns.sim
    assert is_pid(pid)
    :ok = SimSupervisor.stop_sim(pid)
    wait_for_sim_nil(view)
    drain_frames(view)

    render_click(view, "scenario", %{"id" => "open_field"})

    assert_push_event(view, "sim_frame", %{tick: 0, walls: walls}, 500)
    assert walls == []

    drain_frames(view)
    render_click(view, "reset")
    assert_push_event(view, "sim_frame", %{tick: 0}, 500)
  end

  defp wait_for_sim_nil(view, tries \\ 50)
  defp wait_for_sim_nil(_view, 0), do: flunk("sim did not stop")

  defp wait_for_sim_nil(view, tries) do
    if :sys.get_state(view.pid).socket.assigns.sim == nil do
      :ok
    else
      Process.sleep(10)
      wait_for_sim_nil(view, tries - 1)
    end
  end

  # Pushed events arrive through the LiveView client proxy, keyed by its ref.
  defp drain_frames(view) do
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:push_event, "sim_frame", _payload}} -> drain_frames(view)
    after
      20 -> :ok
    end
  end
end
