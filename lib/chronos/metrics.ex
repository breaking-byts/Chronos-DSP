defmodule Chronos.Metrics do
  @spec received_power(list({float(), float()})) :: float()
  def received_power(samples) do
    count = max(length(samples), 1)

    samples
    |> Enum.reduce(0.0, fn {re, im}, acc -> acc + re * re + im * im end)
    |> Kernel./(count)
  end

  @spec push_history(list(map()), map(), pos_integer()) :: list(map())
  def push_history(history, entry, limit) do
    history = history ++ [entry]
    if length(history) <= limit, do: history, else: tl(history)
  end
end
