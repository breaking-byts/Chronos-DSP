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
  @default_tx_power 10
  @min_tx_power 0
  @max_tx_power 30
  @min_attenuation 0.0
  @max_attenuation 40.0
  @min_z -5.0
  @max_z 5.0

  @doc """
  The unsigned 32-bit ceiling for API noise seeds. `Chronos.SimFrame` mixes the
  tick into the seed before passing it to the native renderer's unsigned 64-bit
  seed, so capping the seed at `u32` keeps `seed + tick` in range. Shared by the
  simulation and export controllers.
  """
  @spec max_seed() :: pos_integer()
  def max_seed, do: @max_seed

  @doc """
  The default transmit power in dBm for API channel opts. Matches
  `Chronos.Channel.Physics.tx_power_dbm/1`; the model's unit-gain-at-one-metre
  normalization is calibrated to it, so the default leaves renders unchanged.
  Shared by the simulation and export controllers.
  """
  @spec default_tx_power() :: integer()
  def default_tx_power, do: @default_tx_power

  @doc """
  The transmit-power bounds in dBm (`0..30`) for API channel opts, matching the
  interactive-editing design lock. Shared by the simulation and export
  controllers.
  """
  @spec tx_power_range() :: {integer(), integer()}
  def tx_power_range, do: {@min_tx_power, @max_tx_power}

  @doc """
  Validates a `tx_power` value from a JSON body: an integer in `0..30` dBm.
  Floats, negatives, out-of-range integers, and non-numbers are rejected, the
  JSON-body counterpart to `parse_query_integer/5` on the export endpoints.
  Returns `{:ok, value}` or `{:error, message}`.
  """
  @spec validate_tx_power(term()) :: {:ok, integer()} | {:error, String.t()}
  def validate_tx_power(value) do
    {minimum, maximum} = tx_power_range()

    if is_integer(value) and value >= minimum and value <= maximum do
      {:ok, value}
    else
      {:error, "tx_power must be an integer between #{minimum} and #{maximum}"}
    end
  end

  @doc """
  The per-wall attenuation-override bounds in dB (`0..40`) for the editing
  panel (#35), matching the interactive-editing design lock. Mirrored by
  `Chronos.PanelEdit.attenuation_range/0`.
  """
  @spec attenuation_range() :: {float(), float()}
  def attenuation_range, do: {@min_attenuation, @max_attenuation}

  @doc """
  Validates a per-wall attenuation override: a finite number in `0..40` dB.
  Form values arrive as strings, so the LiveView parses them before calling;
  non-numbers, negatives, out-of-range and non-finite values are rejected.
  `nil` is NOT accepted here — "Auto (use material)" is a separate checkbox
  event that clears `wall.attenuation_db` to `nil`.
  Returns `{:ok, value}` or `{:error, message}`.
  """
  @spec validate_attenuation(term()) :: {:ok, number()} | {:error, String.t()}
  def validate_attenuation(value) do
    {minimum, maximum} = attenuation_range()

    if is_number(value) and Chronos.Channel.Physics.finite?(value) and
         value >= minimum and value <= maximum do
      {:ok, value}
    else
      {:error, "attenuation must be a number between #{minimum} and #{maximum} dB"}
    end
  end

  @doc """
  The z-height bounds in metres (`-5..+5`) for the editing panel's node/wall
  height fields (#35), matching the interactive-editing design lock. Mirrored
  by `Chronos.PanelEdit.z_range/0`.
  """
  @spec z_range() :: {float(), float()}
  def z_range, do: {@min_z, @max_z}

  @doc """
  Validates a z-height edit: a finite number in `-5..+5` m. Form values arrive
  as strings, so the LiveView parses them before calling; non-numbers,
  out-of-range and non-finite values are rejected.
  Returns `{:ok, value}` or `{:error, message}`.
  """
  @spec validate_z(term()) :: {:ok, number()} | {:error, String.t()}
  def validate_z(value) do
    {minimum, maximum} = z_range()

    if is_number(value) and Chronos.Channel.Physics.finite?(value) and
         value >= minimum and value <= maximum do
      {:ok, value}
    else
      {:error, "z must be a number between #{minimum} and #{maximum} m"}
    end
  end

  @doc """
  Validates a wall material id against the 11-material `Chronos.Material`
  catalogue (#35). Accepts a string or atom id present in the catalogue and
  returns the catalogue atom; unknown ids are rejected (never defaulted).
  Returns `{:ok, atom_id}` or `{:error, message}`.
  """
  @spec validate_material(term()) :: {:ok, atom()} | {:error, String.t()}
  def validate_material(value) do
    case Chronos.Material.fetch(value) do
      nil -> {:error, "material must be one of the catalogue ids"}
      material -> {:ok, material.id}
    end
  end

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
