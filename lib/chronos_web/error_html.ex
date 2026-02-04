defmodule ChronosWeb.ErrorHTML do
  use Phoenix.Component

  def render(_assigns) do
    ~H"""
    <h1>Server Error</h1>
    """
  end
end
