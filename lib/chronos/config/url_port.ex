defmodule Chronos.Config.UrlPort do
  @moduledoc """
  Normalizes the optional public URL port used at boot by `config/runtime.exs`.
  """

  alias Chronos.Config

  @doc """
  Returns a valid `PHX_URL_PORT`, or the documented derived default.

  An unset or blank optional value returns the derived default silently. An
  invalid non-blank value must never take the node down: it warns and falls
  back to 443 when HTTPS is forced, otherwise to the listen port. `PORT`
  remains mandatory and is validated separately.
  """
  @spec normalize(String.t() | nil, boolean(), pos_integer()) :: pos_integer()
  def normalize(value, force_ssl?, listen_port) do
    default = if force_ssl?, do: 443, else: listen_port

    case Config.parse_port(value) do
      {:ok, port} ->
        port

      :empty ->
        default

      :error ->
        IO.warn("Invalid PHX_URL_PORT=#{inspect(value)}; using #{default}")
        default
    end
  end
end
