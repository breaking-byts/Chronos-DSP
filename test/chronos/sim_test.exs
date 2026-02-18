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
    assert [{0.0, 0.0}, {1.0, 0.0}, {0.0, 0.0}] == Packing.unpack_complex!(rx_bin)
  end
end
