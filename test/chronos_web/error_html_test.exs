defmodule ChronosWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  test "render returns 404 html" do
    html = Phoenix.HTML.safe_to_string(ChronosWeb.ErrorHTML.render("404.html", %{}))
    assert html =~ "Not Found"
  end

  test "render returns 500 html" do
    html = Phoenix.HTML.safe_to_string(ChronosWeb.ErrorHTML.render("500.html", %{}))
    assert html =~ "Server Error"
  end
end
