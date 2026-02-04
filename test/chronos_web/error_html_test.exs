defmodule ChronosWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  test "render returns html" do
    html = Phoenix.HTML.safe_to_string(ChronosWeb.ErrorHTML.render(%{}))
    assert html =~ "Server Error"
  end
end
