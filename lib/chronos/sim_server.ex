defmodule Chronos.SimServer do
  use GenServer

  alias Chronos.World

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def next_frame(pid), do: GenServer.call(pid, :next_frame)

  @impl true
  def init(opts) do
    seed = Keyword.get(opts, :seed, 1)
    world = Keyword.get(opts, :world, World.new())
    tick_ms = Keyword.get(opts, :tick_ms, 100)
    {:ok, %{tick: 0, seed: seed, world: world, tick_ms: tick_ms}}
  end

  @impl true
  def handle_call(:next_frame, _from, state) do
    dt = state.tick_ms / 1000
    world = World.step(state.world, dt)
    frame = Chronos.SimFrame.from_world(world, tick: state.tick, seed: state.seed)
    {:reply, {:ok, frame}, %{state | tick: state.tick + 1, world: world}}
  end
end
