defmodule Chronos.DSP do
  require Logger

  alias Chronos.DSP.Native
  alias Chronos.DSP.Reference

  @missing_nif_warning_key {__MODULE__, :missing_nif_warning_emitted}

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

  @spec render_rx_block(binary(), binary(), float(), float(), non_neg_integer()) :: binary()
  def render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed) do
    if nif_artifact_present?() do
      try do
        Native.render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed)
      rescue
        e ->
          if nif_unavailable_error?(e) do
            handle_missing_nif(tx_block, paths_block, sample_rate, noise_power, seed)
          else
            reraise e, __STACKTRACE__
          end
      end
    else
      handle_missing_nif(tx_block, paths_block, sample_rate, noise_power, seed)
    end
  end

  defp handle_missing_nif(tx_block, paths_block, sample_rate, noise_power, seed) do
    if Application.get_env(:chronos, :require_nif, false) do
      raise RuntimeError,
            "Chronos DSP NIF is required in this environment. Build native/chronos_dsp before starting."
    else
      warn_missing_nif_once()
      Reference.render_rx_block(tx_block, paths_block, sample_rate, noise_power, seed)
    end
  end

  defp nif_artifact_present? do
    case :code.priv_dir(:chronos) do
      priv_dir when is_list(priv_dir) ->
        priv_dir
        |> to_string()
        |> nif_artifact_candidates()
        |> Enum.any?(&File.exists?/1)

      _ ->
        false
    end
  end

  defp nif_artifact_candidates(priv_dir) do
    base_path = Path.join(priv_dir, "native/chronos_dsp")
    [base_path, "#{base_path}.so", "#{base_path}.dll", "#{base_path}.dylib"]
  end

  defp nif_unavailable_error?(%ErlangError{original: :nif_not_loaded}), do: true
  defp nif_unavailable_error?(%UndefinedFunctionError{module: Native}), do: true
  defp nif_unavailable_error?(_error), do: false

  defp warn_missing_nif_once do
    case :persistent_term.get(@missing_nif_warning_key, false) do
      true ->
        :ok

      false ->
        Logger.warning(
          "Chronos DSP NIF unavailable, falling back to Elixir reference implementation"
        )

        :persistent_term.put(@missing_nif_warning_key, true)
    end
  end
end
