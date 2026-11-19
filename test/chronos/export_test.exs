defmodule Chronos.ExportTest do
  use ExUnit.Case, async: true

  alias Chronos.Export

  test "metrics CSV starts with the exact header" do
    assert Export.metrics_csv([]) ==
             "tick,time_s,rx_id,path_count,received_power,ber\n"
  end

  test "metrics CSV formats a complete row with BER precision" do
    metric = %{
      tick: 7,
      time_s: 1.25,
      rx_id: "rx1",
      path_count: 3,
      received_power: -12.5,
      ber: 0.000001234567
    }

    assert Export.metrics_csv([metric]) ==
             "tick,time_s,rx_id,path_count,received_power,ber\n" <>
               "7.000000,1.250000,rx1,3.000000,-12.500000,0.000001234567\n"
  end

  test "metrics CSV defaults missing timing fields and a nil receiver id" do
    metric = %{path_count: 2, received_power: 0.5, ber: 0.25}

    assert Export.metrics_csv([metric]) ==
             "tick,time_s,rx_id,path_count,received_power,ber\n" <>
               "0.000000,0.000000,,2.000000,0.500000,0.250000000000\n"

    assert Export.metrics_csv([Map.put(metric, :rx_id, nil)]) =~ ",,"
  end

  test "metrics CSV escapes receiver ids containing CSV delimiters" do
    comma = Export.metrics_csv([%{rx_id: "rx,one"}])
    assert comma =~ ~s(,"rx,one",)

    quote = Export.metrics_csv([%{rx_id: ~s(rx"one)}])
    assert quote =~ ~s(,"rx""one",)
  end

  test "samples CSV contains the exact header and one formatted row" do
    assert Export.samples_csv([{1.5, -2.25}]) ==
             "index,re,im\n" <>
               "0,1.500000,-2.250000\n"
  end

  test "samples CSV with no samples contains only its header" do
    assert Export.samples_csv([]) == "index,re,im\n"
  end

  test "escape_field quotes only fields that need it" do
    assert Export.escape_field("plain") == "plain"
    assert Export.escape_field("one,two") == ~s("one,two")
    assert Export.escape_field(~s(say "hi")) == ~s("say ""hi""")
    assert Export.escape_field(nil) == ""
  end
end
