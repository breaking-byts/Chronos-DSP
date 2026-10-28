defmodule ChronosWeb.SimulationController do
  @moduledoc """
  Provides a stateless JSON endpoint for running simulator scenarios.
  """

  use Phoenix.Controller

  alias Chronos.Scenario
  alias Chronos.SimFrame
  alias ChronosWeb.SimulationParams.JSONParser

  @default_scenario "orbit"
  @default_seed 1
  @max_tick 1_000_000
  @max_seed 4_294_967_295
  @default_sample_rate 48_000.0
  @default_noise_power 0.01
  @min_sample_rate 1_000.0
  @max_sample_rate 1_000_000.0
  @min_noise_power 0.0
  @max_noise_power 1.0

  @doc """
  Runs a built-in scenario and returns its metrics and DSP snapshot.

  `tick` must be an integer from `0` through `1_000_000`, and `seed` must be
  an integer from `0` through `4_294_967_295` (default `1`). Values outside
  those ranges return a `400` response with a JSON error.

  Top-level request-body fields whose names start with `_` are reserved and
  return `400` with `{"error":"reserved field"}`. This deliberately rejects
  Phoenix's `_method` and `_format` parameters instead of allowing them to
  alter routing or content negotiation.
  """
  @spec simulate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def simulate(conn, params) do
    with :ok <- validate_content_type(conn),
         :ok <- validate_json(params),
         {:ok, options} <- validate_params(params) do
      render_simulation(conn, options)
    else
      {:error, message} -> bad_request(conn, message)
    end
  end

  defp render_simulation(conn, options) do
    world = Scenario.world(options.scenario)

    world =
      if options.tick > 0 do
        Scenario.step(world, options.scenario, 0.1 * options.tick)
      else
        world
      end

    frame =
      SimFrame.from_world(world,
        tick: options.tick,
        seed: options.seed,
        sample_rate: options.sample_rate,
        noise_power: options.noise_power
      )

    json(conn, %{
      tick: frame.tick,
      time_s: frame.time_s,
      metrics: frame.metrics,
      dsp: frame.dsp
    })
  end

  defp validate_content_type(conn) do
    if json_content_type?(conn) do
      :ok
    else
      {:error, "content type must be application/json"}
    end
  end

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _] ->
        case Plug.Conn.Utils.media_type(content_type) do
          {:ok, "application", "json", _params} -> true
          _other -> false
        end

      [] ->
        false
    end
  end

  defp validate_json(params) do
    if JSONParser.invalid?(params) do
      {:error, "malformed JSON body"}
    else
      :ok
    end
  end

  defp validate_params(params) when is_map(params) do
    with {:ok, tick} <- validate_tick(params),
         {:ok, scenario} <- validate_scenario(params),
         {:ok, seed} <- validate_seed(params),
         {:ok, sample_rate} <- validate_sample_rate(params),
         {:ok, noise_power} <- validate_noise_power(params) do
      {:ok,
       %{
         tick: tick,
         scenario: scenario,
         seed: seed,
         sample_rate: sample_rate,
         noise_power: noise_power
       }}
    end
  end

  defp validate_tick(params) do
    case Map.fetch(params, "tick") do
      {:ok, tick} when is_integer(tick) and tick >= 0 and tick <= @max_tick ->
        {:ok, tick}

      {:ok, tick} when is_integer(tick) and tick > @max_tick ->
        {:error, "tick must be between 0 and #{@max_tick}"}

      :error ->
        {:error, "tick is required"}

      _other ->
        {:error, "tick must be a non-negative integer"}
    end
  end

  defp validate_scenario(params) do
    case Map.get(params, "scenario", @default_scenario) do
      scenario when scenario in ["orbit", "open_field"] -> {:ok, scenario}
      _other -> {:error, "scenario must be one of: orbit, open_field"}
    end
  end

  defp validate_seed(params) do
    case Map.get(params, "seed", @default_seed) do
      seed when is_integer(seed) and seed >= 0 and seed <= @max_seed ->
        {:ok, seed}

      seed when is_integer(seed) and seed > @max_seed ->
        {:error, "seed must be between 0 and #{@max_seed}"}

      _other ->
        {:error, "seed must be a non-negative integer"}
    end
  end

  defp validate_sample_rate(params) do
    value = Map.get(params, "sample_rate", @default_sample_rate)

    if is_number(value) and value >= @min_sample_rate and value <= @max_sample_rate do
      {:ok, value}
    else
      {:error, "sample_rate must be a number between 1000.0 and 1000000.0"}
    end
  end

  defp validate_noise_power(params) do
    value = Map.get(params, "noise_power", @default_noise_power)

    if is_number(value) and value >= @min_noise_power and value <= @max_noise_power do
      {:ok, value}
    else
      {:error, "noise_power must be a number between 0.0 and 1.0"}
    end
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message})
  end
end
