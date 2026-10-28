defmodule Chronos.SimServer do
  @moduledoc """
  Owns one simulation session: world state, tick counter, and render options.

  Sessions are started under `Chronos.SimSupervisor` and stop automatically when
  the owning LiveView process exits.
  """

  use GenServer
  require Logger

  alias Chronos.Scenario
  alias Chronos.Scene
  alias Chronos.SimFrame

  @default_tick_ms 100
  @default_seed 7
  @default_noise_power 0.01
  @default_sample_rate 48_000.0
  @call_timeout 10_000

  @doc "Starts a simulation process."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Renders the next frame and advances the simulation by one tick."
  @spec next_frame(pid()) :: {:ok, SimFrame.frame()} | {:error, term()}
  def next_frame(pid), do: GenServer.call(pid, :next_frame, @call_timeout)

  @doc "Resets the world and tick counter."
  @spec reset(pid()) :: :ok
  def reset(pid), do: GenServer.call(pid, :reset, @call_timeout)

  @doc "Changes the tick interval in milliseconds (clamped to 20..2000)."
  @spec set_tick_ms(pid(), integer()) :: :ok | {:error, :invalid_value}
  def set_tick_ms(pid, tick_ms), do: GenServer.call(pid, {:set_tick_ms, tick_ms}, @call_timeout)

  @doc "Changes the noise power (clamped to 0.0..1.0)."
  @spec set_noise_power(pid(), number()) :: :ok | {:error, :invalid_value}
  def set_noise_power(pid, noise_power) do
    GenServer.call(pid, {:set_noise_power, noise_power}, @call_timeout)
  end

  @doc "Switches to a built-in scenario and resets the tick counter."
  @spec set_scenario(pid(), Scenario.id()) :: :ok
  def set_scenario(pid, scenario),
    do: GenServer.call(pid, {:set_scenario, scenario}, @call_timeout)

  @impl true
  def init(opts) do
    scenario = opts |> Keyword.get(:scenario, Scenario.default_id()) |> normalize_scenario()
    world_opt = Keyword.get(opts, :world)
    custom_world? = match?(%Chronos.World{}, world_opt)
    world = if custom_world?, do: world_opt, else: Scenario.world(scenario)

    bounds =
      Keyword.get_lazy(opts, :bounds, fn ->
        if custom_world?, do: Scene.bounds(world), else: Scenario.bounds(scenario)
      end)

    state = %{
      tick: 0,
      seed: Keyword.get(opts, :seed, @default_seed),
      scenario: scenario,
      custom_world: custom_world?,
      world: world,
      initial_world: world,
      bounds: bounds,
      tick_ms: clamp(Keyword.get(opts, :tick_ms, @default_tick_ms), 20, 2_000),
      noise_power: clamp(Keyword.get(opts, :noise_power, @default_noise_power), 0.0, 1.0),
      sample_rate: Keyword.get(opts, :sample_rate, @default_sample_rate),
      owner: Keyword.get(opts, :owner)
    }

    if is_pid(state.owner), do: Process.monitor(state.owner)

    {:ok, state}
  end

  @impl true
  def handle_call(:next_frame, _from, state) do
    case render_frame(state) do
      {:ok, frame} ->
        {:reply, {:ok, frame}, advance(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    world =
      if state.custom_world,
        do: state.initial_world,
        else: Scenario.world(state.scenario)

    {:reply, :ok, %{state | tick: 0, world: world}}
  end

  def handle_call({:set_tick_ms, tick_ms}, _from, state) when is_number(tick_ms) do
    {:reply, :ok, %{state | tick_ms: clamp(tick_ms, 20, 2_000)}}
  end

  def handle_call({:set_tick_ms, _value}, _from, state) do
    {:reply, {:error, :invalid_value}, state}
  end

  def handle_call({:set_noise_power, noise_power}, _from, state) when is_number(noise_power) do
    {:reply, :ok, %{state | noise_power: clamp(noise_power, 0.0, 1.0)}}
  end

  def handle_call({:set_noise_power, _value}, _from, state) do
    {:reply, {:error, :invalid_value}, state}
  end

  def handle_call({:set_scenario, scenario}, _from, state) do
    scenario = normalize_scenario(scenario)
    world = Scenario.world(scenario)

    {:reply, :ok,
     %{
       state
       | scenario: scenario,
         custom_world: false,
         tick: 0,
         world: world,
         initial_world: world,
         bounds: Scenario.bounds(scenario)
     }}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp render_frame(state) do
    frame =
      SimFrame.from_world(state.world,
        tick: state.tick,
        seed: state.seed,
        bounds: state.bounds,
        sample_rate: state.sample_rate,
        noise_power: state.noise_power
      )

    {:ok, frame}
  rescue
    exception ->
      Logger.error(
        "Simulation frame failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, Exception.message(exception)}
  end

  defp advance(state) do
    dt = state.tick_ms / 1_000.0
    world = Scenario.step(state.world, state.scenario, dt)
    %{state | tick: state.tick + 1, world: world}
  end

  defp clamp(value, lower, upper), do: value |> max(lower) |> min(upper)

  defp normalize_scenario(scenario) do
    id = to_string(scenario)
    if id in Scenario.ids(), do: id, else: Scenario.default_id()
  end
end
