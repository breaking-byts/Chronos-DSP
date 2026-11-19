defmodule ChronosWeb.ExportController do
  @moduledoc """
  Read-only HTTP endpoints for exporting simulation results as CSV.

  All three endpoints are CSV-only (`Accept: text/csv`); they take their
  parameters from the query string and reject reserved `_`-prefixed fields via
  `ChronosWeb.ApiParams.RequestPlug`. Integer query parameters are validated by
  `ChronosWeb.ApiParams.parse_query_integer/5` and errors use the same uniform
  `{"error": message}` JSON shape as the rest of the JSON API.
  """

  use Phoenix.Controller

  alias Chronos.Export
  alias Chronos.Packing
  alias Chronos.Scenario
  alias Chronos.Sim
  alias Chronos.SimFrame
  alias Chronos.World
  alias ChronosWeb.ApiParams

  @sample_rate 48_000.0
  @noise_power 0.01
  @default_tx_power ApiParams.default_tx_power()
  @step_seconds 0.1
  @sample_count 512
  @scenario_ids Scenario.ids()
  @max_ticks 100_000
  @max_seed ApiParams.max_seed()
  @max_history_rows 1_000

  @doc """
  Exports one frame of receiver metrics as CSV.

  The `ticks` query parameter must be between 0 and #{@max_ticks}. Each tick
  advances the scenario by 0.1 seconds, so the smaller cap keeps the
  per-tick simulation bounded; a single elapsed-time step is not equivalent
  because it changes the floating-point trajectory.

  The `seed` query parameter must be between 0 and #{@max_seed}. This keeps
  `seed + ticks` safely within the native DSP renderer's unsigned 64-bit
  seed range. The optional `scenario` is `orbit` (the default) or
  `open_field`. The optional `tx_power` is an integer between 0 and 30 dBm
  (default #{@default_tx_power}); it scales the rendered signal power.
  """
  @spec metrics(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def metrics(conn, params) do
    with {:ok, ticks, seed, scenario, tx_power} <- parse_common_params(params) do
      world = stepped_world(scenario, ticks)

      send_csv(
        conn,
        Export.metrics_csv([metric_row(world, ticks, seed, tx_power)]),
        "metrics.csv"
      )
    else
      {:error, message} -> send_error(conn, message)
    end
  end

  @doc """
  Exports a multi-tick metrics history as CSV, one row per sampled tick.

  `from` and `to` are inclusive tick bounds (0..#{@max_ticks}, defaults 0 and
  100) with `to >= from`; `step` (1..#{@max_ticks}, default 1) selects every
  nth tick. At most #{@max_history_rows} rows are emitted. The world is stepped
  incrementally from `from`, so the cost is bounded by `to` rather than
  re-simulating from zero for every row. `seed`, `scenario`, and `tx_power`
  match the single-frame endpoints.
  """
  @spec history(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def history(conn, params) do
    with {:ok, from, to, step, seed, scenario, tx_power} <- parse_history_params(params) do
      rows = history_rows(scenario, from, to, step, seed, tx_power)
      send_csv(conn, Export.metrics_csv(rows), "history.csv")
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
  optional `scenario` is `orbit` (the default) or `open_field`, `limit`
  must be between 1 and 512, and `tx_power` is an integer between 0 and 30
  dBm (default #{@default_tx_power}).
  """
  @spec samples(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def samples(conn, params) do
    with {:ok, ticks, seed, scenario, tx_power} <- parse_common_params(params),
         {:ok, limit} <- parse_limit(params) do
      world = stepped_world(scenario, ticks)
      rx = first_receiver(world)

      {_bits, tx_block} = SimFrame.default_tx_block(@sample_count * 2)

      rx_block =
        world
        |> Sim.render(tx_block,
          sample_rate: @sample_rate,
          noise_power: @noise_power,
          seed: seed,
          tx_power: tx_power
        )
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
    {min_tx, max_tx} = ApiParams.tx_power_range()

    with {:ok, ticks} <- ApiParams.parse_query_integer(params, "ticks", 0, 0, @max_ticks),
         {:ok, seed} <- ApiParams.parse_query_integer(params, "seed", 1, 0, @max_seed),
         {:ok, scenario} <- parse_scenario(params),
         {:ok, tx_power} <-
           ApiParams.parse_query_integer(params, "tx_power", @default_tx_power, min_tx, max_tx) do
      {:ok, ticks, seed, scenario, tx_power}
    end
  end

  defp parse_history_params(params) do
    {min_tx, max_tx} = ApiParams.tx_power_range()

    with {:ok, from} <- ApiParams.parse_query_integer(params, "from", 0, 0, @max_ticks),
         {:ok, to} <- ApiParams.parse_query_integer(params, "to", 100, 0, @max_ticks),
         {:ok, step} <- ApiParams.parse_query_integer(params, "step", 1, 1, @max_ticks),
         {:ok, seed} <- ApiParams.parse_query_integer(params, "seed", 1, 0, @max_seed),
         {:ok, scenario} <- parse_scenario(params),
         {:ok, tx_power} <-
           ApiParams.parse_query_integer(params, "tx_power", @default_tx_power, min_tx, max_tx),
         :ok <- validate_history_range(from, to, step) do
      {:ok, from, to, step, seed, scenario, tx_power}
    end
  end

  defp validate_history_range(from, to, _step) when to < from do
    {:error, "invalid history range: to must be greater than or equal to from"}
  end

  defp validate_history_range(from, to, step) do
    rows = div(to - from, step) + 1

    if rows > @max_history_rows do
      {:error,
       "invalid history range: at most #{@max_history_rows} rows (reduce the range or increase step)"}
    else
      :ok
    end
  end

  defp parse_limit(params) do
    ApiParams.parse_query_integer(params, "limit", 128, 1, 512)
  end

  defp parse_scenario(params) do
    case Map.get(params, "scenario", "orbit") do
      scenario when scenario in @scenario_ids -> {:ok, scenario}
      _ -> {:error, "invalid scenario: expected one of #{Enum.join(@scenario_ids, ", ")}"}
    end
  end

  defp metric_row(world, tick, seed, tx_power) do
    metrics =
      SimFrame.metrics(world,
        tick: tick,
        seed: seed,
        sample_rate: @sample_rate,
        noise_power: @noise_power,
        tx_power: tx_power
      )

    Map.merge(metrics, %{tick: tick, time_s: world.time_s})
  end

  defp history_rows(scenario, from, to, step, seed, tx_power) do
    world = stepped_world(scenario, from)
    ticks = Enum.to_list(from..to//step)
    opts = %{scenario: scenario, step: step, seed: seed, tx_power: tx_power}
    collect_history(ticks, world, opts, [])
  end

  defp collect_history([], _world, _opts, acc), do: Enum.reverse(acc)

  defp collect_history([tick | rest], world, opts, acc) do
    row = metric_row(world, tick, opts.seed, opts.tx_power)
    next_world = if rest == [], do: world, else: step_ticks(world, opts.scenario, opts.step)
    collect_history(rest, next_world, opts, [row | acc])
  end

  defp stepped_world(scenario, ticks) do
    step_ticks(Scenario.world(scenario), scenario, ticks)
  end

  defp step_ticks(world, _scenario, 0), do: world

  defp step_ticks(world, scenario, count) do
    Enum.reduce(1..count, world, fn _tick, current ->
      Scenario.step(current, scenario, @step_seconds)
    end)
  end

  defp first_receiver(world) do
    world
    |> World.nodes_by_type(:rx)
    |> Enum.sort_by(&to_string(&1.id))
    |> List.first()
  end

  defp send_csv(conn, csv, filename) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, csv)
  end

  defp send_error(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message})
  end
end
