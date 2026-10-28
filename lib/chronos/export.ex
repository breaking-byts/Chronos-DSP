defmodule Chronos.Export do
  @moduledoc """
  CSV and JSON export helpers for simulation results.
  """

  @metrics_header "tick,time_s,rx_id,path_count,received_power,ber"
  @samples_header "index,re,im"

  @doc """
  Formats simulation metric maps as CSV.

  Rows are emitted in input order. Missing ticks and times default to zero,
  and a missing receiver id is emitted as an empty field.
  """
  @spec metrics_csv(list(map())) :: String.t()
  def metrics_csv(metrics) when is_list(metrics) do
    rows =
      Enum.map(metrics, fn metric ->
        tick = metric_value(metric, :tick, 0)
        time_s = metric_value(metric, :time_s, 0.0)
        rx_id = metric_value(metric, :rx_id, nil)
        path_count = metric_value(metric, :path_count, 0)
        received_power = metric_value(metric, :received_power, 0.0)
        ber = metric_value(metric, :ber, 0.0)

        [
          format_number(tick, 6),
          ",",
          format_number(time_s, 6),
          ",",
          escape_field(rx_id),
          ",",
          format_number(path_count, 6),
          ",",
          format_number(received_power, 6),
          ",",
          format_number(ber, 12),
          "\n"
        ]
      end)

    IO.iodata_to_binary([@metrics_header, "\n", rows])
  end

  @doc """
  Formats complex receiver samples as CSV.

  The sample index is zero-based and both components use six decimal places.
  """
  @spec samples_csv(list({float(), float()})) :: String.t()
  def samples_csv(samples) when is_list(samples) do
    rows =
      samples
      |> Enum.with_index()
      |> Enum.map(fn {{re, im}, index} ->
        [
          Integer.to_string(index),
          ",",
          format_number(re, 6),
          ",",
          format_number(im, 6),
          "\n"
        ]
      end)

    IO.iodata_to_binary([@samples_header, "\n", rows])
  end

  @doc """
  Escapes one value for use as a CSV field.

  Strings only need quoting when they contain a comma, quote, or line break.
  Embedded quotes are doubled as required by RFC 4180.
  """
  @spec escape_field(term()) :: String.t()
  def escape_field(nil), do: ""

  def escape_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  def escape_field(value) when is_number(value) or is_atom(value), do: to_string(value)

  def escape_field(value) when is_list(value) do
    List.to_string(value)
  rescue
    ArgumentError -> inspect(value)
  end

  def escape_field(value), do: inspect(value)

  defp metric_value(metric, key, default) do
    case Map.get(metric, key, default) do
      nil -> default
      value -> value
    end
  end

  defp format_number(value, decimals) when is_integer(value) do
    :erlang.float_to_binary(value * 1.0, decimals: decimals)
  end

  defp format_number(value, decimals) when is_float(value) do
    :erlang.float_to_binary(value, decimals: decimals)
  end

  defp format_number(value, _decimals), do: escape_field(value)
end
