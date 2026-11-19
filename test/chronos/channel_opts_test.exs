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
      {"Channel.doppler",
       fn opts ->
         Channel.doppler({0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, opts)
       end},
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
      [carrier_freq_hz: 1.0e-308],
      [speed_of_light: 0.0],
      [speed_of_light: -1.0],
      [speed_of_light: 1.0e-308],
      # wavelength division overflows even though both inputs are finite
      [speed_of_light: 1.0e308, carrier_freq_hz: 1.0e-308],
      [global_gain: 1.0e308],
      [global_gain: -1.0e308],
      [tx_power: -1],
      [tx_power: 31],
      [tx_power: 10.5],
      [tx_power: 0.0],
      [tx_power: "10"],
      [tx_power: :foo],
      [tx_power: nil],
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

  test "tx_power boundary values 0 and 30 produce paths with scaled gains" do
    base = Channel.los_path(@tx, @rx, [], [])
    low = Channel.los_path(@tx, @rx, [], tx_power: 0)
    high = Channel.los_path(@tx, @rx, [], tx_power: 30)

    # 2 m LOS path: unit gain at 1 m, so base gain is 0.5. The default (10 dBm)
    # calibrates that normalization; 0 dBm attenuates by 10 dB, 30 dBm boosts
    # by 20 dB, relative to the default.
    assert_in_delta base.gain, 0.5, 1.0e-12
    assert_in_delta low.gain, 0.5 * :math.pow(10.0, -10.0 / 20.0), 1.0e-12
    assert_in_delta high.gain, 0.5 * :math.pow(10.0, 20.0 / 20.0), 1.0e-12

    assert Channel.paths_for_rx!(world(), :rx, tx_power: 0) != []
    assert Channel.paths_for_rx!(world(), :rx, tx_power: 30) != []
  end

  test "explicit tx_power 10 matches the default gains exactly" do
    for opts <- [[], [tx_power: 10]] do
      assert Channel.los_path(@tx, @rx, [], opts).gain ==
               Channel.los_path(@tx, @rx, [], []).gain
    end

    assert Channel.paths_for_rx!(world(), :rx, tx_power: 10) ==
             Channel.paths_for_rx!(world(), :rx, [])
  end
end
