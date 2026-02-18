alias Chronos.Modem
alias Chronos.Packing
alias Chronos.Sim
alias Chronos.World

world =
  World.new()
  |> World.add_node(%World.Node{id: :tx1, type: :tx, pos: {0.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}})
  |> World.add_node(%World.Node{id: :rx1, type: :rx, pos: {10.0, 0.0, 0.0}, vel: {0.0, 0.0, 0.0}})

bits = Enum.take(Stream.cycle([0, 1, 1, 0]), 2048)
symbols = Modem.qpsk_modulate(bits)
tx_bin = Packing.pack_complex(symbols)

opts = [
  sample_rate: 48_000.0,
  speed_of_light: 299_792_458.0,
  noise_power: 0.0,
  seed: 1
]

iterations = 200

{elapsed_us, _} =
  :timer.tc(fn ->
    Enum.each(1..iterations, fn _ -> Sim.render(world, tx_bin, opts) end)
  end)

samples = length(symbols) * iterations
throughput = samples / (elapsed_us / 1_000_000)

IO.puts(
  "Rendered #{samples} samples in #{elapsed_us} us (#{Float.round(throughput, 2)} samples/sec)"
)
