defmodule Chronos.ConfigPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chronos.Config
  alias Chronos.Config.UrlPort

  @recognized_ssl ~w(1 true t yes y on 0 false f no n off)

  property "unrecognized non-blank FORCE_SSL fails closed unless PHX_SCHEME is http" do
    check all(
            raw <- StreamData.string(:printable, min_length: 1, max_length: 16),
            String.trim(raw) != "",
            String.downcase(String.trim(raw)) not in @recognized_ssl,
            scheme <- StreamData.member_of([nil, "https", "ssl", "invalid", "http"])
          ) do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        result = Config.force_ssl?(raw, scheme)
        assert result == (scheme != "http")
      end)
    end
  end

  property "UrlPort.normalize always returns a valid TCP port in 1..65535" do
    check all(
            raw <-
              StreamData.one_of([
                StreamData.constant(nil),
                StreamData.string(:printable, max_length: 16)
              ]),
            force_ssl? <- StreamData.boolean(),
            listen_port <- StreamData.integer(1..65_535)
          ) do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        port = UrlPort.normalize(raw, force_ssl?, listen_port)
        assert is_integer(port) and port in 1..65_535
      end)
    end
  end
end
