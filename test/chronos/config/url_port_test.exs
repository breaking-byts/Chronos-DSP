defmodule Chronos.Config.UrlPortTest do
  use ExUnit.Case, async: true

  alias Chronos.Config.UrlPort

  test "unset PHX_URL_PORT uses the derived default" do
    assert UrlPort.normalize(nil, true, 4000) == 443
    assert UrlPort.normalize(nil, false, 4000) == 4000
    assert UrlPort.normalize("   ", true, 4000) == 443
  end

  test "valid PHX_URL_PORT values are used as-is" do
    assert UrlPort.normalize("8443", true, 4000) == 8443
    assert UrlPort.normalize("8080", false, 4000) == 8080
    assert UrlPort.normalize("65535", false, 4000) == 65_535
  end

  test "invalid PHX_URL_PORT warns and uses the derived default" do
    for value <- ["notaport", "0", "70000", "12abc"] do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert UrlPort.normalize(value, true, 4000) == 443
        end)

      assert warning =~ "Invalid PHX_URL_PORT"
    end

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert UrlPort.normalize("notaport", false, 4000) == 4000
      end)

    assert warning =~ "Invalid PHX_URL_PORT"
  end
end
