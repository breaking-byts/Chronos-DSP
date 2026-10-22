defmodule ChronosWeb.ErrorHTML do
  def render("404.html", _assigns) do
    {:safe, "<h1>Not Found</h1>"}
  end

  def render("500.html", _assigns) do
    {:safe, "<h1>Server Error</h1>"}
  end

  def render(_template, _assigns) do
    render("500.html", %{})
  end
end
