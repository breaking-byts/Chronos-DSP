defmodule ChronosWeb.ErrorHTML do
  def render(_assigns) do
    {:safe, "<h1>Server Error</h1>"}
  end
end
