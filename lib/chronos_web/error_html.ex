defmodule ChronosWeb.ErrorHTML do
  def render("404.html", _assigns) do
    {:safe, "<h1>Not Found</h1>"}
  end

  def render("500.html", _assigns) do
    {:safe, "<h1>Server Error</h1>"}
  end

  # Client errors have their own status message. Keep the exact 404/500
  # bodies above: they are part of the existing pages' text.
  def render("405.html", _assigns), do: {:safe, "<h1>Method Not Allowed</h1>"}
  def render("406.html", _assigns), do: {:safe, "<h1>Not Acceptable</h1>"}
  def render("413.html", _assigns), do: {:safe, "<h1>Payload Too Large</h1>"}

  def render(_template, _assigns) do
    render("500.html", %{})
  end
end
