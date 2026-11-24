defmodule Chronos.Config.UrlPort do
  @moduledoc """
  Normalizes the optional public URL port used at boot by `config/runtime.exs`.
  """

  @doc """
  Returns a valid `PHX_URL_PORT`, or the documented derived default.

  An unset or invalid optional value must never take the node down: invalid
  input warns and falls back to 443 when HTTPS is forced, otherwise to the
  listen port. `PORT` remains mandatory and is validated separately.
  """
  @spec normalize(String.t() | nil, boolean(), pos_integer()) :: pos_integer()
  def normalize(value, force_ssl?, listen_port) do
    default = if force_ssl?, do: 443, else: listen_port

    case value do
      nil ->
        default

      raw ->
        case String.trim(raw) do
          "" ->
            default

          trimmed ->
            case Integer.parse(trimmed) do
              {port, ""} when port in 1..65_535 ->
                port

              _ ->
                IO.warn("Invalid PHX_URL_PORT=#{inspect(raw)}; using #{default}")
                default
            end
        end
    end
  end
end
