defmodule Chronos.DSP do
  @moduledoc """
  Native DSP entry point with a controlled Elixir fallback.

  The Rust NIF is required in production (`:require_nif`) and optional in
  development/test. When the artifact is missing or cannot be loaded outside
  production, rendering falls back to `Chronos.DSP.Reference` and logs a single
  warning.
  """

  require Logger

  alias Chronos.DSP.Native
  alias Chronos.DSP.Reference

  @missing_nif_warning_key {__MODULE__, :missing_nif_warning_emitted}

  @doc """
  Returns true when the native NIF is loadable.

  Tests can force a deterministic answer with the `:nif_loaded_override`
  application environment value.
  """
  @spec nif_loaded?() :: boolean()
  def nif_loaded? do
    case Application.get_env(:chronos, :nif_loaded_override) do
      value when is_boolean(value) ->
        value

      _ ->
        if nif_artifact_present?() do
          try do
            Native.nif_loaded()
          rescue
            e ->
              if nif_unavailable_error?(e) do
                false
              else
                reraise e, __STACKTRACE__
              end
          end
        else
          false
        end
    end
  end

  @doc """
  Renders a complex baseband block for one receiver.

  Falls back to the reference implementation when allowed; raises when the NIF
  is required but unavailable.
  """
  @spec render_rx_block(binary(), binary(), float(), float(), non_neg_integer()) :: binary()
  def render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed) do
    if nif_loaded?() do
      try do
        Native.render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed)
      rescue
        e ->
          if nif_unavailable_error?(e) do
            handle_missing_nif(tx_block, paths_block, sample_rate, noise_power, seed, e)
          else
            reraise e, __STACKTRACE__
          end
      end
    else
      handle_missing_nif(tx_block, paths_block, sample_rate, noise_power, seed, nil)
    end
  end

  defp handle_missing_nif(tx_block, paths_block, sample_rate, noise_power, seed, error) do
    if Application.get_env(:chronos, :require_nif, false) do
      raise RuntimeError,
            "Chronos DSP NIF is required in this environment. Build native/chronos_dsp before starting."
    else
      warn_missing_nif_once(error)
      Reference.render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed)
    end
  end

  defp nif_artifact_present? do
    case :code.priv_dir(:chronos) do
      priv_dir when is_list(priv_dir) ->
        priv_dir
        |> to_string()
        |> nif_artifact_candidates()
        |> Enum.any?(&artifact_magic?/1)

      _ ->
        false
    end
  end

  # Rustler's mix compiler copies the platform artifact to `chronos_dsp.so` in
  # most setups, but some toolchains keep the `lib` prefix. Accept every common
  # name as well as the extension-less path.
  defp nif_artifact_candidates(priv_dir) do
    native_dir = Path.join(priv_dir, "native")

    for base <- ["chronos_dsp", "libchronos_dsp"],
        suffix <- ["", ".so", ".dylib", ".dll"] do
      Path.join(native_dir, base <> suffix)
    end
  end

  defp artifact_magic?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 4)) do
      {:ok, <<0x7F, "ELF">>} -> true
      {:ok, <<0xCF, 0xFA, 0xED, 0xFE>>} -> true
      {:ok, <<0xFE, 0xED, 0xFA, 0xCE>>} -> true
      {:ok, <<0xFE, 0xED, 0xFA, 0xCF>>} -> true
      {:ok, <<"MZ", _::binary>>} -> true
      _ -> false
    end
  end

  defp nif_unavailable_error?(%ErlangError{original: :nif_not_loaded}), do: true
  defp nif_unavailable_error?(%UndefinedFunctionError{module: Native}), do: true
  defp nif_unavailable_error?(_error), do: false

  defp warn_missing_nif_once(error) do
    case :persistent_term.get(@missing_nif_warning_key, false) do
      true ->
        :ok

      false ->
        detail = if error, do: " (#{Exception.message(error)})", else: ""
        Logger.warning("Chronos DSP NIF unavailable#{detail}; using Elixir reference")
        :persistent_term.put(@missing_nif_warning_key, true)
    end
  end
end
