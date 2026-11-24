defmodule ChronosWeb.SimLiveMalformedEventTest do
  use ExUnit.Case, async: true

  alias ChronosWeb.SimLive

  test "non-string control payloads are ignored instead of crashing the LiveView" do
    socket = %Phoenix.LiveView.Socket{}

    events = [
      {"speed", %{"ms" => 100}},
      {"noise", %{"value" => nil}},
      {"set_tx_power", %{"value" => 10}},
      {"set_wall_attenuation", %{"id" => "w1", "value" => 1.5}},
      {"set_node_z", %{"id" => "n1", "value" => :bad}},
      {"set_wall_z", %{"id" => "w1", "value" => %{}}},
      {"set_scene_name", %{"name" => 123}}
    ]

    for {event, params} <- events do
      assert {:noreply, ^socket} = SimLive.handle_event(event, params, socket)
    end
  end

  test "unknown events are ignored with a warning" do
    socket = %Phoenix.LiveView.Socket{}

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert {:noreply, ^socket} = SimLive.handle_event("no_such_event", %{}, socket)
      end)

    assert log =~ "no_such_event"
  end
end
