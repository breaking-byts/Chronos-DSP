defmodule Chronos.Config do
  @moduledoc """
  Pure helpers for normalizing production environment configuration.

  `config/runtime.exs` runs at boot inside a release. Keeping the decision
  logic here makes the security-sensitive defaults testable without booting
  a production node.
  """

  @doc """
  Decides whether production HTTPS redirects and HSTS are enabled.

  Recognized truthy/falsy `FORCE_SSL` values win. An unrecognized value warns
  and falls back to `PHX_SCHEME` (which may disable redirects), or to HTTPS
  when the scheme is unset or invalid — a typo must never silently disable
  TLS by itself. When `FORCE_SSL` is unset, `PHX_SCHEME` decides, defaulting
  to HTTPS.
  """
  @spec force_ssl?(String.t() | nil, String.t() | nil) :: boolean()
  def force_ssl?(force_ssl_env, scheme_env) do
    cond do
      truthy?(force_ssl_env) ->
        true

      falsy?(force_ssl_env) ->
        false

      is_nil(force_ssl_env) ->
        scheme_https?(scheme_env, true)

      true ->
        fallback = scheme_https?(scheme_env, true)

        IO.warn(
          "Unrecognized FORCE_SSL=#{inspect(force_ssl_env)}; " <>
            "falling back to PHX_SCHEME or the secure default " <>
            "(HTTPS redirects #{if fallback, do: "enabled", else: "disabled"})"
        )

        fallback
    end
  end

  defp scheme_https?(nil, default), do: default

  defp scheme_https?(scheme, _default) do
    case String.downcase(String.trim(scheme)) do
      "https" -> true
      "ssl" -> true
      "http" -> false
      # An invalid PHX_SCHEME also falls back to the secure default.
      _ -> true
    end
  end

  defp truthy?(value),
    do: is_binary(value) and String.downcase(String.trim(value)) in ~w(1 true t yes y on)

  defp falsy?(value),
    do: is_binary(value) and String.downcase(String.trim(value)) in ~w(0 false f no n off)
end
