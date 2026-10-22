defmodule Chronos.RuntimeTest do
  use ExUnit.Case, async: true

  alias Chronos.Runtime

  test "status returns required metadata fields" do
    status = Runtime.status()

    assert status.app == "chronos"
    assert is_binary(status.version)
    assert is_binary(status.build_env)
    assert is_binary(status.runtime_env)
    assert is_binary(status.timestamp)
    assert is_boolean(status.nif_loaded)
    assert is_integer(status.uptime_s)
  end

  test "uptime is monotonic" do
    first = Runtime.uptime_seconds()
    second = Runtime.uptime_seconds()
    assert second >= first
  end
end
