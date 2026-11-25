defmodule Chronos.Config do
  @moduledoc """
  Pure helpers for normalizing production environment configuration.

  `config/runtime.exs` runs at boot inside a release. Keeping the decision
  logic here makes the security-sensitive defaults testable without booting
  a production node.
  """

  @doc """
  Decides whether production HTTPS redirects and HSTS are enabled.

  Recognized truthy/falsy `FORCE_SSL` values win. Blank or unset values follow
  `PHX_SCHEME`, defaulting to HTTPS. An unrecognized non-blank value warns and
  falls back to `PHX_SCHEME` (which may disable redirects), or to HTTPS when
  the scheme is unset or invalid — a typo must never silently disable TLS by
  itself.
  """
  @spec force_ssl?(String.t() | nil, String.t() | nil) :: boolean()
  def force_ssl?(force_ssl_env, scheme_env) do
    normalized = trim_to_nil(force_ssl_env)

    cond do
      truthy?(normalized) ->
        true

      falsy?(normalized) ->
        false

      is_nil(normalized) ->
        normalize_scheme(scheme_env, "https") == "https"

      true ->
        fallback = normalize_scheme(scheme_env, "https") == "https"

        IO.warn(
          "Unrecognized FORCE_SSL=#{inspect(force_ssl_env)}; " <>
            "falling back to PHX_SCHEME or the secure default " <>
            "(HTTPS redirects #{if fallback, do: "enabled", else: "disabled"})"
        )

        fallback
    end
  end

  @doc false
  @spec normalize_scheme(String.t() | nil, String.t()) :: String.t()
  def normalize_scheme(value, fallback) do
    case trim_to_nil(value) && String.downcase(trim_to_nil(value)) do
      "https" -> "https"
      "ssl" -> "https"
      "http" -> "http"
      _ -> fallback
    end
  end

  @doc false
  @spec parse_port(String.t() | nil) :: {:ok, pos_integer()} | :empty | :error
  def parse_port(value) do
    case trim_to_nil(value) do
      nil ->
        :empty

      trimmed ->
        case Integer.parse(trimmed) do
          {port, ""} when port in 1..65_535 -> {:ok, port}
          _ -> :error
        end
    end
  end

  @doc false
  @spec truthy?(term()) :: boolean()
  def truthy?(value),
    do: is_binary(value) and String.downcase(String.trim(value)) in ~w(1 true t yes y on)

  @doc false
  @spec falsy?(term()) :: boolean()
  def falsy?(value),
    do: is_binary(value) and String.downcase(String.trim(value)) in ~w(0 false f no n off)

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_to_nil(_value), do: nil
end
