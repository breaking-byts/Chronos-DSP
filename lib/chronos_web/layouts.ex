defmodule ChronosWeb.Layouts do
  @moduledoc "Shared HTML shell for the dashboard."
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="dark" />
        <meta
          name="description"
          content="Chronos-DSP is a real-time wireless propagation simulator with an Elixir control plane and Rust DSP data plane."
        />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Chronos-DSP · Wireless propagation lab</title>
        <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
        <link rel="stylesheet" href="/assets/app.css" />
      </head>
      <body>
        <%= @inner_content %>

        <script src="/phoenix/phoenix.js"></script>
        <script src="/live/phoenix_live_view.js"></script>
        <script src="/assets/vendor/echarts.min.js"></script>
        <script src="/assets/app.js"></script>
      </body>
    </html>
    """
  end
end
