defmodule ChronosWeb.ExportController do
  @moduledoc """
  Read-only HTTP endpoints for exporting simulation results as CSV.
  """

  use Phoenix.Controller

  alias Chronos.Export
  alias Chronos.Modem
  alias Chronos.Packing
  alias Chronos.Scenario
  alias Chronos.Sim
  alias Chronos.SimFrame
  alias Chronos.World

  @sample_rate 48_000.0
  @noise_power 0.01
  @step_seconds 0.1
  @sample_count 512
  @bit_pattern [0, 0, 0, 1, 1, 1, 1, 0]
  @scenarios ["orbit", "open_field"]
  @max_ticks 100_000
  @max_seed 4_294_967_295

  @doc """
  Exports one frame of receiver metrics as CSV.

  The `ticks` query parameter must be between 0 and #{@max_ticks}. Each tick
  advances the scenario by 0.1 seconds, so the smaller cap keeps the
  per-tick simulation bounded; a single elapsed-time step is not equivalent
  because it changes the floating-point trajectory.

  The `seed` query parameter must be between 0 and #{@max_seed}. This keeps
  `seed + ticks` safely within the native DSP renderer's unsigned 64-bit
  seed range. The optional `scenario` is `orbit` (the default) or
  `open_field`.
  """
  @spec metrics(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def metrics(conn, params) do
    with {:ok, ticks, seed, scenario} <- parse_common_params(params) do
      world = stepped_world(scenario, ticks)

      frame =
        SimFrame.from_world(world,
          tick: ticks,
          seed: seed,
          sample_rate: @sample_rate,
          noise_power: @noise_power
        )

      metric = Map.merge(frame.metrics, %{tick: frame.tick, time_s: frame.time_s})
      send_csv(conn, Export.metrics_csv([metric]), "metrics.csv")
    else
      {:error, message} -> send_error(conn, message)
    end
  end

  @doc """
  Exports samples from the first receiver as CSV.

  The `ticks` query parameter must be between 0 and #{@max_ticks}. Each tick
  advances the scenario by 0.1 seconds, so the smaller cap keeps the
  per-tick simulation bounded; a single elapsed-time step is not equivalent
  because it changes the floating-point trajectory.

  The `seed` query parameter must be between 0 and #{@max_seed}. This keeps
  the native DSP renderer's seed within its unsigned 64-bit range. The
  optional `scenario` is `orbit` (the default) or `open_field`, and `limit`
  must be between 1 and 512.
  """
  @spec samples(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def samples(conn, params) do
    with {:ok, ticks, seed, scenario} <- parse_common_params(params),
         {:ok, limit} <- parse_limit(params) do
      world = stepped_world(scenario, ticks)
      rx = first_receiver(world)

      tx_block = tx_block()

      rx_block =
        world
        |> Sim.render(tx_block, sample_rate: @sample_rate, noise_power: @noise_power, seed: seed)
        |> Map.fetch!(rx.id)

      samples =
        rx_block
        |> Packing.unpack_complex!()
        |> Enum.take(limit)

      send_csv(conn, Export.samples_csv(samples), "samples.csv")
    else
      {:error, message} -> send_error(conn, message)
    end
  end

  defp parse_common_params(params) do
    with {:ok, ticks} <- parse_integer(params, "ticks", 0, 0, @max_ticks),
         {:ok, seed} <- parse_integer(params, "seed", 1, 0, @max_seed),
         {:ok, scenario} <- parse_scenario(params) do
      {:ok, ticks, seed, scenario}
    end
  end

  defp parse_limit(params) do
    parse_integer(params, "limit", 128, 1, 512)
  end

  defp parse_integer(params, key, default, minimum, maximum) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= minimum and integer <= maximum ->
            {:ok, integer}

          _ ->
            {:error, invalid_integer_message(key, minimum, maximum)}
        end

      _ ->
        {:error, invalid_integer_message(key, minimum, maximum)}
    end
  end

  defp parse_scenario(params) do
    case Map.get(params, "scenario", "orbit") do
      scenario when scenario in @scenarios -> {:ok, scenario}
      _ -> {:error, "invalid scenario: expected one of orbit, open_field"}
    end
  end

  defp invalid_integer_message(key, minimum, maximum) do
    "invalid #{key}: expected an integer between #{minimum} and #{maximum}"
  end

  defp stepped_world(scenario, ticks) do
    world = Scenario.world(scenario)

    if ticks == 0 do
      world
    else
      Enum.reduce(1..ticks, world, fn _tick, current ->
        Scenario.step(current, scenario, @step_seconds)
      end)
    end
  end

  defp first_receiver(world) do
    world
    |> World.nodes_by_type(:rx)
    |> Enum.sort_by(&to_string(&1.id))
    |> List.first()
  end

  defp tx_block do
    bits =
      @bit_pattern
      |> Stream.cycle()
      |> Enum.take(@sample_count * 2)

    bits
    |> Modem.qpsk_modulate()
    |> Packing.pack_complex()
  end

  defp send_csv(conn, csv, filename) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, csv)
  end

  defp send_error(conn, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, message)
  end
end
