defmodule Chronos.SimServer do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def next_frame(pid), do: GenServer.call(pid, :next_frame)

  @impl true
  def init(opts) do
    seed = Keyword.get(opts, :seed, 1)
    world = Chronos.World.new()
    {:ok, %{tick: 0, seed: seed, world: world}}
  end

  @impl true
  def handle_call(:next_frame, _from, state) do
    frame = Chronos.SimFrame.from_world(state.world, tick: state.tick)
    {:reply, {:ok, frame}, %{state | tick: state.tick + 1}}
  end
end
