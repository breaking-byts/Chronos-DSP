defmodule Chronos.ModemTest do
  use ExUnit.Case, async: true

  alias Chronos.Modem

  test "qpsk mod/demod roundtrip" do
    bits = [0, 0, 0, 1, 1, 1, 1, 0]
    symbols = Modem.qpsk_modulate(bits)
    assert bits == Modem.qpsk_demodulate(symbols)
  end

  test "qpsk modulate rejects odd length" do
    assert_raise ArgumentError, fn -> Modem.qpsk_modulate([1]) end
  end

  test "ber returns zero for identical streams" do
    bits = [0, 1, 1, 0]
    assert Modem.ber(bits, bits) == 0.0
  end

  test "ber counts differing bits" do
    assert Modem.ber([0, 0, 1, 1], [0, 1, 1, 0]) == 0.5
  end
end
