defmodule Chronos.ExportPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chronos.Export

  @formula_prefixes ["=", "+", "-", "@", "\t", "\r"]

  property "escape_field neutralizes arbitrary binaries starting with formula prefixes" do
    check all(
            prefix <- StreamData.member_of(@formula_prefixes),
            rest <- StreamData.string(:printable, max_length: 32)
          ) do
      escaped = Export.escape_field(prefix <> rest)

      unquoted =
        if String.starts_with?(escaped, "\"") do
          escaped |> String.slice(1..-2//1) |> String.replace("\"\"", "\"")
        else
          escaped
        end

      assert String.starts_with?(unquoted, "'" <> prefix)
    end
  end
end
