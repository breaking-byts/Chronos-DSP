defmodule ChronosWeb.SceneController do
  @moduledoc """
  JSON endpoints for managing named user scenes.
  """

  use Phoenix.Controller

  alias Chronos.SceneStore

  @doc "Lists all stored scenes in name order."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    if conn.request_path == "/api/scenes/" do
      error(conn, :bad_request, "invalid_name")
    else
      json(conn, %{scenes: SceneStore.list()})
    end
  end

  @doc "Loads one stored scene by name."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"name" => name}) do
    case SceneStore.get(name) do
      {:ok, scene} ->
        json(conn, scene)

      {:error, :invalid_name} ->
        error(conn, :bad_request, "invalid_name")

      {:error, :not_found} ->
        error(conn, :not_found, "not_found")
    end
  end

  @doc "Validates and stores a new scene."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    scene = conn.body_params
    name = if is_map(scene), do: Map.get(scene, "name"), else: nil

    with :ok <- SceneStore.validate_name(name),
         :ok <- SceneStore.validate(scene) do
      create_scene(conn, scene)
    else
      {:error, :invalid_name} ->
        error(conn, :bad_request, "invalid_name")

      {:error, :invalid_scene} ->
        error(conn, :bad_request, "invalid_scene")
    end
  end

  @doc "Deletes a stored scene by name."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"name" => name}) do
    case SceneStore.delete(name) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :invalid_name} ->
        error(conn, :bad_request, "invalid_name")

      {:error, :not_found} ->
        error(conn, :not_found, "not_found")

      {:error, _reason} ->
        error(conn, :internal_server_error, "storage_error")
    end
  end

  defp create_scene(conn, scene) do
    case SceneStore.create(scene) do
      {:ok, persisted_scene} ->
        conn
        |> put_status(:created)
        |> json(%{scene: persisted_scene})

      {:error, :name_taken} ->
        error(conn, :conflict, "name_taken")

      {:error, :eexist} ->
        error(conn, :conflict, "name_taken")

      {:error, :invalid_scene} ->
        error(conn, :bad_request, "invalid_scene")

      {:error, :invalid_name} ->
        error(conn, :bad_request, "invalid_name")

      {:error, _reason} ->
        error(conn, :internal_server_error, "storage_error")
    end
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: code})
  end
end
