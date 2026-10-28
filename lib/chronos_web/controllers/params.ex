defmodule ChronosWeb.SimulationParams do
  @moduledoc """
  Shared helpers for requests handled by the stateless simulation endpoint.
  """

  @simulation_path ["api", "simulate"]

  @doc false
  @spec simulation_request?(Plug.Conn.t()) :: boolean()
  def simulation_request?(%Plug.Conn{method: "POST", path_info: path_info}) do
    decode_path_info(path_info) == @simulation_path
  end

  def simulation_request?(%Plug.Conn{}), do: false

  defp decode_path_info(path_info) do
    Enum.map(path_info, &URI.decode/1)
  rescue
    ArgumentError -> path_info
  end
end

defmodule ChronosWeb.SimulationParams.JSONParser do
  @moduledoc """
  JSON parser that lets the simulation endpoint format malformed-body errors.

  Phoenix's standard JSON parser raises before a controller can respond. For
  requests to the simulation endpoint, malformed JSON is retained as an
  internal sentinel so the controller can return its uniform JSON error shape.
  Other paths retain Phoenix's standard parser behavior.

  Route matching uses decoded path segments, matching Phoenix router behavior
  for percent-encoded paths.
  """

  @behaviour Plug.Parsers

  @invalid_key "chronos_invalid_json"

  @doc "Initializes the JSON parser with Phoenix's configured decoder."
  @impl Plug.Parsers
  @spec init(keyword()) :: term()
  def init(opts), do: Plug.Parsers.JSON.init(opts)

  @doc "Parses JSON and retains malformed simulation requests as a sentinel."
  @impl Plug.Parsers
  @spec parse(Plug.Conn.t(), binary(), binary(), list(), term()) ::
          {:ok, map(), Plug.Conn.t()}
          | {:error, :too_large, Plug.Conn.t()}
          | {:next, Plug.Conn.t()}
  def parse(conn, type, subtype, headers, opts) do
    Plug.Parsers.JSON.parse(conn, type, subtype, headers, opts)
  rescue
    error in Plug.Parsers.ParseError ->
      if ChronosWeb.SimulationParams.simulation_request?(conn) do
        {:ok, %{@invalid_key => {:invalid_json, Exception.message(error)}}, conn}
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc "Returns whether decoded parameters represent malformed JSON."
  @spec invalid?(map()) :: boolean()
  def invalid?(params) when is_map(params) do
    match?(%{@invalid_key => {:invalid_json, _message}}, params)
  end
end

defmodule ChronosWeb.SimulationParams.ReservedFieldPlug do
  @moduledoc """
  Rejects reserved request-body fields before Phoenix can consume them.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if ChronosWeb.SimulationParams.simulation_request?(conn) and
         reserved_field?(conn.body_params) do
      conn
      |> Plug.Conn.put_status(:bad_request)
      |> Phoenix.Controller.json(%{error: "reserved field"})
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  defp reserved_field?(%Plug.Conn.Unfetched{}), do: false

  defp reserved_field?(body_params) when is_map(body_params) do
    Enum.any?(body_params, fn {key, _value} ->
      is_binary(key) and String.starts_with?(key, "_")
    end)
  end

  defp reserved_field?(_body_params), do: false
end
