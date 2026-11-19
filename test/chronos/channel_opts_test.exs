defmodule Chronos.ChannelOptsTest do
  use ExUnit.Case, async: true

  alias Chronos.Channel
  alias Chronos.Channel.Diffraction
  alias Chronos.Channel.MultiBounce
  alias Chronos.Channel.Transmission
  alias Chronos.World

  @tx %World.Node{id: :tx, type: :tx, pos: {-1.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}}
  @rx %World.Node{id: :rx, type: :rx, pos: {1.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}}
  @wall %World.Wall{
    id: :w1,
    vertices: [{0.0, -2.0, -2.0}, {0.0, 2.0, -2.0}, {0.0, 2.0, 2.0}, {0.0, -2.0, 2.0}],
    normal: {1.0, 0.0, 0.0}
  }

  defp world do
    World.new() |> World.add_node(@tx) |> World.add_node(@rx)
  end

  defp entries do
    [
      {"Channel.paths_for_rx!", fn opts -> Channel.paths_for_rx!(world(), :rx, opts) end},
      {"Channel.los_path", fn opts -> Channel.los_path(@tx, @rx, [@wall], opts) end},
      {"MultiBounce.paths", fn opts -> MultiBounce.paths(@tx, @rx, [@wall], opts) end},
      {"Diffraction.paths", fn opts -> Diffraction.paths(@tx, @rx, [@wall], opts) end},
      {"Transmission.paths", fn opts -> Transmission.paths(@tx, @rx, [@wall], opts) end}
    ]
  end

  defp invalid_opts do
    # Note: this OTP raises on float overflow and rejects non-finite values in
    # parsers and binary patterns, so inf/nan cannot be constructed as Elixir
    # terms here. The validation's non-finite guards are defense in depth;
    # these cases cover zero, negatives, wrong types, overflow-inducing finite
    # pairs, and the magnitude bounds.
    [
      [carrier_freq_hz: 0.0],
      [carrier_freq_hz: -1.0],
      [speed_of_light: 0.0],
      [speed_of_light: -1.0],
      # wavelength division overflows even though both inputs are finite
      [speed_of_light: 1.0e308, carrier_freq_hz: 1.0e-308],
      [global_gain: 1.0e308],
      [global_gain: -1.0e308],
      [max_paths: 0],
      [max_paths: -1],
      [max_paths: 1.5],
      [max_paths: :foo],
      [max_bounces: 0],
      [max_bounces: :foo],
      [max_candidates: 0],
      [extra_transmission_loss_db: -1.0],
      [extra_transmission_loss_db: 1.0e308]
    ]
  end

  test "every public path model rejects invalid options uniformly" do
    for {name, fun} <- entries(), opts <- invalid_opts() do
      try do
        fun.(opts)
        flunk("#{name} accepted invalid opts #{inspect(opts)}")
      rescue
        ArgumentError -> :ok
      end
    end
  end

  test "valid options still produce paths" do
    opts = [speed_of_light: 1.0, carrier_freq_hz: 1.0, max_paths: 8, max_bounces: 2]

    assert is_list(Channel.paths_for_rx!(world(), :rx, opts))
    assert %Chronos.Channel.Path{} = Channel.los_path(@tx, @rx, [], opts)
    assert is_list(MultiBounce.paths(@tx, @rx, [@wall], opts))
    assert is_list(Diffraction.paths(@tx, @rx, [@wall], opts))
    assert is_list(Transmission.paths(@tx, @rx, [@wall], opts))
  end
end
