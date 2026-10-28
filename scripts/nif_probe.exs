alias Chronos.DSP.Native
alias Chronos.Packing

say = fn label -> IO.puts(:stderr, "PROBE #{label}") end

say.("start")
say.("nif_loaded=#{inspect(Native.nif_loaded())}")

empty = Packing.pack_complex([])
no_paths = Packing.pack_paths([])

say.("empty tx, empty paths")
IO.inspect(Native.render_rx_block(empty, no_paths, 48_000.0, 0.0, 7) |> byte_size())

one = Packing.pack_complex([{1.0, 0.0}])

one_path =
  Packing.pack_paths([%{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0}])

say.("one sample, one path")
IO.inspect(Native.render_rx_block(one, one_path, 1.0, 0.0, 1) |> byte_size())

tx =
  for n <- 0..31 do
    phase = 2.0 * :math.pi() * n / 8.0
    {:math.cos(phase), :math.sin(phase)}
  end

tx_bin = Packing.pack_complex(tx)

say.("32 samples, no paths")
IO.inspect(Native.render_rx_block(tx_bin, no_paths, 48_000.0, 0.0, 7) |> byte_size())

paths =
  Packing.pack_paths([
    %{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0},
    %{delay_s: 1.0 / 48_000.0, gain: 0.5, doppler_hz: 120.0},
    %{delay_s: 3.0 / 48_000.0, gain: -0.25, doppler_hz: -40.0}
  ])

say.("32 samples, 3 paths, noise 0")
IO.inspect(Native.render_rx_block(tx_bin, paths, 48_000.0, 0.0, 7) |> byte_size())

say.("32 samples, 3 paths, noise 0.01")
IO.inspect(Native.render_rx_block(tx_bin, paths, 48_000.0, 0.01, 7) |> byte_size())

say.("done")
