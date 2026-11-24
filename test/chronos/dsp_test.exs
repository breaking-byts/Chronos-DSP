defmodule Chronos.DSPTest do
  use ExUnit.Case, async: false

  alias Chronos.DSP
  alias Chronos.Packing

  setup do
    prev_require_nif = Application.get_env(:chronos, :require_nif, false)
    prev_nif_override = Application.get_env(:chronos, :nif_loaded_override)

    on_exit(fn ->
      Application.put_env(:chronos, :require_nif, prev_require_nif)

      if is_nil(prev_nif_override) do
        Application.delete_env(:chronos, :nif_loaded_override)
      else
        Application.put_env(:chronos, :nif_loaded_override, prev_nif_override)
      end
    end)

    :ok
  end

  test "render_rx_block falls back to reference when nif missing" do
    Application.put_env(:chronos, :require_nif, false)

    tx = [{1.0, 0.0}]
    tx_bin = Packing.pack_complex(tx)
    paths_bin = Packing.pack_paths([%{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0}])

    rx_bin = DSP.render_rx_block(tx_bin, paths_bin, 1.0, 0.0, 1)
    assert tx == Packing.unpack_complex!(rx_bin)
  end

  test "render_rx_block falls back when artifact exists but nif load fails" do
    Application.put_env(:chronos, :require_nif, false)
    Application.delete_env(:chronos, :nif_loaded_override)

    tx = [{1.0, 0.0}]
    tx_bin = Packing.pack_complex(tx)
    paths_bin = Packing.pack_paths([%{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0}])

    with_dummy_nif_artifact(fn ->
      rx_bin = DSP.render_rx_block(tx_bin, paths_bin, 1.0, 0.0, 1)
      assert tx == Packing.unpack_complex!(rx_bin)
    end)
  end

  test "nif_loaded? uses override for deterministic checks" do
    Application.put_env(:chronos, :nif_loaded_override, true)
    assert DSP.nif_loaded?()

    Application.put_env(:chronos, :nif_loaded_override, false)
    refute DSP.nif_loaded?()
  end

  test "nif_loaded? returns false when artifact exists but native module is unavailable" do
    Application.delete_env(:chronos, :nif_loaded_override)

    with_dummy_nif_artifact(fn ->
      refute DSP.nif_loaded?()
    end)
  end

  test "render_rx_block raises when nif is required but unavailable" do
    Application.put_env(:chronos, :require_nif, true)
    Application.put_env(:chronos, :nif_loaded_override, false)

    tx_bin = Packing.pack_complex([{1.0, 0.0}])
    paths_bin = Packing.pack_paths([%{delay_s: 0.0, gain: 1.0, doppler_hz: 0.0}])

    assert_raise RuntimeError, fn ->
      DSP.render_rx_block(tx_bin, paths_bin, 1.0, 0.0, 1)
    end
  end

  test "artifact magic detection covers all documented native binary headers" do
    accepted = [
      <<0x7F, "ELF">>,
      <<0xCE, 0xFA, 0xED, 0xFE>>,
      <<0xCF, 0xFA, 0xED, 0xFE>>,
      <<0xFE, 0xED, 0xFA, 0xCE>>,
      <<0xFE, 0xED, 0xFA, 0xCF>>,
      <<0xCA, 0xFE, 0xBA, 0xBE>>,
      <<0xBE, 0xBA, 0xFE, 0xCA>>,
      <<"MZ", 0x90, 0x00>>
    ]

    rejected = ["not-a-real-nif", "", <<0x7F, "EL">>]
    all = accepted ++ rejected

    paths =
      Enum.map(all, fn bytes ->
        path =
          Path.join(
            System.tmp_dir!(),
            "chronos_dsp_magic_#{System.unique_integer([:positive])}.so"
          )

        File.write!(path, bytes)
        path
      end)

    try do
      accepted
      |> Enum.zip(paths)
      |> Enum.each(fn {magic, path} ->
        assert DSP.artifact_magic?(path), "expected #{Base.encode16(magic)} to be accepted"
      end)

      rejected
      |> Enum.zip(Enum.drop(paths, length(accepted)))
      |> Enum.each(fn {bytes, path} ->
        refute DSP.artifact_magic?(path), "expected #{inspect(bytes)} to be rejected"
      end)
    after
      Enum.each(paths, &File.rm/1)
    end
  end

  defp with_dummy_nif_artifact(fun) do
    previous = Application.get_env(:chronos, :nif_artifact_path)

    artifact_path =
      Path.join(
        System.tmp_dir!(),
        "chronos_dsp_dummy_#{System.unique_integer([:positive])}.so"
      )

    # Never overwrite the real NIF: the shared object is already mapped into the
    # VM, and truncating it can fault the next native call on Linux. Point the
    # availability check at an invalid temporary file instead.
    File.write!(artifact_path, "not-a-real-nif")
    Application.put_env(:chronos, :nif_artifact_path, artifact_path)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:chronos, :nif_artifact_path)
      else
        Application.put_env(:chronos, :nif_artifact_path, previous)
      end

      File.rm(artifact_path)
    end
  end
end
