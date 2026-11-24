defmodule Chronos.ConfigTest do
  use ExUnit.Case, async: true

  alias Chronos.Config

  test "production defaults to HTTPS redirects and HSTS" do
    assert Config.force_ssl?(nil, nil)
  end

  test "documented truthy and falsy FORCE_SSL values still win" do
    for value <- ["1", "true", "t", "yes", "y", "on", "TRUE", " on "],
        do: assert(Config.force_ssl?(value, nil))

    for value <- ["0", "false", "f", "no", "n", "off", "FALSE", " off "],
        do: refute(Config.force_ssl?(value, nil))
  end

  test "unset FORCE_SSL follows PHX_SCHEME" do
    refute Config.force_ssl?(nil, "http")
    assert Config.force_ssl?(nil, "https")
    assert Config.force_ssl?(nil, "ssl")
    assert Config.force_ssl?(nil, "garbage")
  end

  test "an unrecognized FORCE_SSL warns and fails closed" do
    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Config.force_ssl?("typo", nil)
      end)

    assert warning =~ "Unrecognized FORCE_SSL"

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             refute Config.force_ssl?("typo", "http")
           end) =~ "Unrecognized FORCE_SSL"

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert Config.force_ssl?("typo", "https")
           end) =~ "Unrecognized FORCE_SSL"

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert Config.force_ssl?("typo", "garbage")
           end) =~ "Unrecognized FORCE_SSL"
  end
end
