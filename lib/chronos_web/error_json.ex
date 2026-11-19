defmodule ChronosWeb.ErrorJSON do
  @moduledoc """
  Uniform JSON error shape for the API: every rendered error is
  `%{"error" => message}`, matching the controllers' bad-request responses.
  Covers routing and negotiation failures (404/405/406), oversized bodies
  (413), and server errors (500) that never reach a controller.
  """

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
