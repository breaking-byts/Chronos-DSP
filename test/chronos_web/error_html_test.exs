defmodule ChronosWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  test "render returns 404 html" do
    html = Phoenix.HTML.safe_to_string(ChronosWeb.ErrorHTML.render("404.html", %{}))
    assert html =~ "Not Found"
  end

  test "render returns 500 html" do
    html = Phoenix.HTML.safe_to_string(ChronosWeb.ErrorHTML.render("500.html", %{}))
    assert html == "<h1>Server Error</h1>"
  end

  test "client-error templates render their own status message" do
    for {template, message} <- [
          {"404.html", "Not Found"},
          {"405.html", "Method Not Allowed"},
          {"406.html", "Not Acceptable"},
          {"413.html", "Payload Too Large"}
        ] do
      html = Phoenix.HTML.safe_to_string(ChronosWeb.ErrorHTML.render(template, %{}))
      assert html == "<h1>#{message}</h1>"
    end
  end

  test "unknown templates still render the generic server error" do
    html = Phoenix.HTML.safe_to_string(ChronosWeb.ErrorHTML.render("418.html", %{}))
    assert html == "<h1>Server Error</h1>"
  end
end
