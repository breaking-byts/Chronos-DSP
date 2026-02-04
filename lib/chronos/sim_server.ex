defmodule Chronos.SimServer do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def next_frame(pid), do: GenServer.call(pid, :next_frame)

  @impl true
  def init(opts) do
    seed = Keyword.get(opts, :seed, 1)
    {:ok, %{tick: 0, seed: seed}}
  end

  @impl true
  def handle_call(:next_frame, _from, state) do
    frame = %{tick: state.tick}
    {:reply, {:ok, frame}, %{state | tick: state.tick + 1}}
  end
end
