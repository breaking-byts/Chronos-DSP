defmodule Chronos.ModemPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chronos.Modem

  defp bit_list do
    StreamData.list_of(StreamData.member_of([0, 1]), max_length: 64)
  end

  property "ber is always in 0.0..1.0 and symmetric in its arguments" do
    check all(a <- bit_list(), b <- bit_list()) do
      rate = Modem.ber(a, b)
      assert rate >= 0.0 and rate <= 1.0
      assert rate == Modem.ber(b, a)
    end
  end

  property "identical streams always have zero ber" do
    check all(bits <- bit_list()) do
      assert Modem.ber(bits, bits) == 0.0
    end
  end

  property "a non-empty stream compared to an empty stream reports total loss" do
    check all(
            bits <-
              StreamData.list_of(StreamData.member_of([0, 1]), min_length: 1, max_length: 32)
          ) do
      assert Modem.ber(bits, []) == 1.0
      assert Modem.ber([], bits) == 1.0
    end
  end
end
