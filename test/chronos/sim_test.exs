defmodule Chronos.SimTest do
  use ExUnit.Case, async: true

  alias Chronos.Packing
  alias Chronos.Sim
  alias Chronos.World

  test "render produces delayed impulse for single rx" do
    world =
      World.new()
      |> World.add_node(%World.Node{
        id: :tx1,
        type: :tx,
        pos: {0.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })
      |> World.add_node(%World.Node{
        id: :rx1,
        type: :rx,
        pos: {1.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })

    tx = [{1.0, 0.0}, {0.0, 0.0}, {0.0, 0.0}]
    tx_bin = Packing.pack_complex(tx)

    result =
      Sim.render(world, tx_bin,
        sample_rate: 1.0,
        speed_of_light: 1.0,
        noise_power: 0.0,
        seed: 1
      )

    rx_bin = Map.fetch!(result, :rx1)
    assert [{0.0, 0.0}, {1.0, 0.0}, {0.0, 0.0}] == Packing.unpack_complex(rx_bin)
  end

  test "ber worsens as noise power increases" do
    world =
      World.new()
      |> World.add_node(%World.Node{
        id: :tx1,
        type: :tx,
        pos: {0.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })
      |> World.add_node(%World.Node{
        id: :rx1,
        type: :rx,
        pos: {2.0, 0.0, 0.0},
        vel: {0.0, 0.0, 0.0}
      })

    bits = Enum.take(Stream.cycle([0, 0, 1, 1]), 4096)
    tx = Chronos.Modem.qpsk_modulate(bits)
    tx_bin = Packing.pack_complex(tx)

    ber = fn noise_power ->
      rx_bin =
        Sim.render(world, tx_bin,
          sample_rate: 48_000.0,
          speed_of_light: 299_792_458.0,
          noise_power: noise_power,
          seed: 7
        )
        |> Map.fetch!(:rx1)

      rx_bits = rx_bin |> Packing.unpack_complex() |> Chronos.Modem.qpsk_demodulate()
      Chronos.Modem.ber(bits, rx_bits)
    end

    ber_low = ber.(0.0)
    ber_mid = ber.(0.1)
    ber_high = ber.(0.4)

    assert ber_low <= ber_mid
    assert ber_mid <= ber_high
  end
end
