defmodule ChronosWeb.ApiParams do
  @moduledoc """
  Shared request rules for the anonymous JSON API (`/api/*`).

  Write requests (POST/PUT/PATCH/DELETE) take their parameters from the JSON
  body only: query strings are rejected so Phoenix internals such as `_format`
  and `_method` can never ride in on the query string, and a query value can
  never satisfy a required body field. Reserved `_`-prefixed fields are
  rejected in both body and query on every API request. These rules run at the
  endpoint, before `Plug.MethodOverride` and the router's format negotiation,
  so every current and future `/api/*` route inherits them.
  """

  @doc false
  @spec api_request?(Plug.Conn.t()) :: boolean()
  def api_request?(%Plug.Conn{path_info: path_info}) do
    case decode_path_info(path_info) do
      ["api" | _] -> true
      _ -> false
    end
  end

  defp decode_path_info(path_info) do
    Enum.map(path_info, &URI.decode/1)
  rescue
    ArgumentError -> path_info
  end

  @max_seed 4_294_967_295

  @doc """
  The unsigned 32-bit ceiling for API noise seeds. `Chronos.SimFrame` mixes the
  tick into the seed before passing it to the native renderer's unsigned 64-bit
  seed, so capping the seed at `u32` keeps `seed + tick` in range. Shared by the
  simulation and export controllers.
  """
  @spec max_seed() :: pos_integer()
  def max_seed, do: @max_seed

  @doc """
  Parses an optional integer query parameter within `[minimum, maximum]`.

  Query parameters arrive as strings (GET endpoints), so this full-consumption
  `Integer.parse/1` guard is the query-string counterpart to the JSON-body
  integer guards in `ChronosWeb.SimulationController`. Returns `{:ok, value}`
  (the default when absent) or `{:error, message}`.
  """
  @spec parse_query_integer(map(), String.t(), integer(), integer(), integer()) ::
          {:ok, integer()} | {:error, String.t()}
  def parse_query_integer(params, key, default, minimum, maximum) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= minimum and integer <= maximum ->
            {:ok, integer}

          _ ->
            {:error, invalid_integer_message(key, minimum, maximum)}
        end

      _ ->
        {:error, invalid_integer_message(key, minimum, maximum)}
    end
  end

  defp invalid_integer_message(key, minimum, maximum) do
    "invalid #{key}: expected an integer between #{minimum} and #{maximum}"
  end
end

defmodule ChronosWeb.ApiParams.JSONParser do
  @moduledoc """
  JSON parser that lets API endpoints format malformed-body errors.

  Phoenix's standard JSON parser raises before a controller can respond. For
  requests under `/api/*`, malformed JSON is retained as an internal sentinel
  so controllers can return the uniform JSON error shape. Other paths retain
  Phoenix's standard parser behavior.

  Route matching uses decoded path segments, matching Phoenix router behavior
  for percent-encoded paths.
  """

  @behaviour Plug.Parsers

  @invalid_key "chronos_invalid_json"

  @doc "Initializes the JSON parser with Phoenix's configured decoder."
  @impl Plug.Parsers
  @spec init(keyword()) :: term()
  def init(opts), do: Plug.Parsers.JSON.init(opts)

  @doc "Parses JSON and retains malformed API requests as a sentinel."
  @impl Plug.Parsers
  @spec parse(Plug.Conn.t(), binary(), binary(), list(), term()) ::
          {:ok, map(), Plug.Conn.t()}
          | {:error, :too_large, Plug.Conn.t()}
          | {:next, Plug.Conn.t()}
  def parse(conn, type, subtype, headers, opts) do
    Plug.Parsers.JSON.parse(conn, type, subtype, headers, opts)
  rescue
    error in Plug.Parsers.ParseError ->
      if ChronosWeb.ApiParams.api_request?(conn) do
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

defmodule ChronosWeb.ApiParams.RequestPlug do
  @moduledoc """
  Enforces the JSON API request rules before Phoenix can consume internals.

  Runs at the endpoint ahead of `Plug.MethodOverride` and format negotiation:
  write methods reject any query string, and reserved `_`-prefixed fields are
  rejected in body and query alike. GET/HEAD keep query parameters (the export
  and scene-list endpoints use them) but still reject reserved fields.
  """

  @behaviour Plug

  @write_methods ~w(POST PUT PATCH DELETE)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if ChronosWeb.ApiParams.api_request?(conn) do
      conn = Plug.Conn.fetch_query_params(conn)

      cond do
        conn.method in @write_methods and conn.query_string != "" ->
          reject(
            conn,
            "query parameters are not accepted on #{conn.method} requests; send a JSON body"
          )

        reserved_field?(conn.body_params) or reserved_field?(conn.query_params) ->
          reject(conn, "reserved field")

        true ->
          conn
      end
    else
      conn
    end
  end

  defp reject(conn, message) do
    conn
    |> Plug.Conn.put_status(:bad_request)
    |> Phoenix.Controller.json(%{error: message})
    |> Plug.Conn.halt()
  end

  defp reserved_field?(%Plug.Conn.Unfetched{}), do: false

  defp reserved_field?(params) when is_map(params) do
    Enum.any?(params, fn {key, _value} ->
      is_binary(key) and String.starts_with?(key, "_")
    end)
  end

  defp reserved_field?(_params), do: false
end
