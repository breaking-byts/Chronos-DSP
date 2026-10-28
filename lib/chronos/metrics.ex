defmodule Chronos.Metrics do
  @moduledoc "Small, dependency-free link metrics helpers."

  @doc "Mean complex sample power (`|I|^2 + |Q|^2`)."
  @spec received_power(list({float(), float()})) :: float()
  def received_power(samples) do
    count = max(length(samples), 1)

    samples
    |> Enum.reduce(0.0, fn {re, im}, acc -> acc + re * re + im * im end)
    |> Kernel./(count)
  end

  @doc """
  Appends `entry` to a bounded history, dropping the oldest entries first.
  """
  @spec push_history(list(map()), map(), pos_integer()) :: list(map())
  def push_history(history, _entry, limit) when not is_integer(limit) or limit <= 0,
    do: history

  def push_history(history, entry, limit) do
    Enum.take(history ++ [entry], -limit)
  end
end
