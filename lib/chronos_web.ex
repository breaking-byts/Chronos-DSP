defmodule ChronosWeb do
  def live_view do
    quote do
      use Phoenix.LiveView, layout: {ChronosWeb.Layouts, :root}
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Phoenix.LiveView.Router
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
