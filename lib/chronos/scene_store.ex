defmodule Chronos.SceneStore do
  @moduledoc """
  File-backed store for named user scenes.

  A scene is a map with:

    * `"name"` - the file stem, restricted to `[a-z0-9_-]`, 1..64 chars;
    * `"description"` - optional free text;
    * `"nodes"` - list of `%{id, type ("tx"|"rx"), pos: [x,y,z], vel: [x,y,z]}`;
    * `"walls"` - list of `%{id, vertices: [[x,y,z],...], normal: [x,y,z],
      attenuation_db: number, material: optional string id}`.

  Node and wall ids are limited to 64 characters. Each scene may contain at
  most 1024 nodes and 1024 walls.

  Scenes are stored as pretty JSON, one file per scene, in a configurable
  directory (default: Application env `:chronos`, `:scene_dir`, falling back to
  `"priv/scenes"` relative to the app root).
  """

  alias Chronos.World

  @type scene :: map()

  @name_regex ~r/\A[a-z0-9_-]{1,64}\z/
  @node_types ["tx", "rx"]
  @max_id_length 64
  @max_scene_items 1024

  # Concrete is the material catalogue's default and has a 6 dB reflection
  # loss. This is also the fallback used by the built-in `wall_y` scenario.
  @default_attenuation_db 6.0

  # The material catalogue lives in another feature slice. Keep an equivalent
  # fallback here so persisted scenes remain portable while that module is
  # unavailable; when it is loaded, reflection_loss_db/1 is authoritative.
  @material_reflection_losses %{
    "brick" => 4.0,
    "concrete" => 6.0,
    "drywall" => 2.0,
    "glass" => 1.0,
    "metal" => 0.5,
    "plaster" => 3.0,
    "plywood" => 3.5,
    "reinforced_concrete" => 8.0,
    "soil" => 5.0,
    "water" => 2.0,
    "wood" => 3.0
  }

  @doc """
  Lists every stored scene sorted by name.

  Unreadable or malformed files are skipped rather than raising. A missing
  scene directory is treated as empty.
  """
  @spec list() :: [scene()]
  def list do
    dir = scene_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.filter(&valid_name?/1)
        |> Enum.flat_map(fn name ->
          case get(name) do
            {:ok, scene} -> [scene]
            _error -> []
          end
        end)
        |> Enum.sort_by(&Map.get(&1, "name", ""))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Loads a scene by name.

  Returns `{:error, :invalid_name}` when the name does not match the allowed
  pattern and `{:error, :not_found}` when no readable, schema-valid scene
  exists. Malformed and schema-invalid files are reported as not found.
  """
  @spec get(String.t()) :: {:ok, scene()} | {:error, :not_found | :invalid_name}
  def get(name) do
    with :ok <- validate_name(name) do
      read_scene(scene_path(scene_dir(), name))
    end
  end

  @doc """
  Creates a validated scene when its name is not already in use.

  Creation is serialized per scene name, so concurrent callers cannot both
  create the same name. The persisted scene is read back before it is
  returned, so the response always represents the complete file on disk.
  """
  @spec create(scene()) ::
          {:ok, scene()}
          | {:error, :invalid_scene | :invalid_name | :name_taken | File.posix()}
  def create(scene) do
    with {:ok, name} <- scene_name(scene),
         :ok <- validate(scene),
         dir = scene_dir(),
         :ok <- ensure_scene_dir(dir),
         {:ok, body} <- encode_scene(scene) do
      :global.trans(create_lock_id(dir, name), fn ->
        create_scene(dir, name, body)
      end)
    end
  end

  @doc """
  Persists a validated scene.

  The scene is written to a unique sibling temporary file and atomically
  renamed into place. Existing files are replaced.
  """
  @spec save(scene()) :: :ok | {:error, :invalid_scene | :invalid_name | File.posix()}
  def save(scene) do
    with {:ok, name} <- scene_name(scene),
         :ok <- validate(scene) do
      dir = scene_dir()

      with :ok <- ensure_scene_dir(dir) do
        write_scene(dir, name, scene)
      end
    end
  end

  @doc """
  Deletes a stored scene.

  Returns `{:error, :not_found}` when the scene does not exist.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found | :invalid_name | File.posix()}
  def delete(name) do
    with :ok <- validate_name(name) do
      case File.rm(scene_path(scene_dir(), name)) do
        :ok -> :ok
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Validates a scene against the storage schema.
  """
  @spec validate(scene()) :: :ok | {:error, :invalid_scene}
  def validate(scene) do
    if valid_scene?(scene), do: :ok, else: {:error, :invalid_scene}
  end

  @doc """
  Validates a scene name against the storage naming rules.
  """
  @spec validate_name(term()) :: :ok | {:error, :invalid_name}
  def validate_name(name) do
    if valid_name?(name), do: :ok, else: {:error, :invalid_name}
  end

  @doc """
  Builds a `Chronos.World` from a valid scene.

  Existing atoms are reused for ids when possible; otherwise ids remain
  strings, so untrusted scene data never grows the atom table. A missing wall
  attenuation uses the material's reflection loss, or 6 dB for concrete and
  unknown materials.
  """
  @spec scene_to_world(scene()) :: {:ok, World.t()} | {:error, :invalid_scene}
  def scene_to_world(scene) do
    case validate(scene) do
      :ok ->
        try do
          {:ok, build_world(scene)}
        rescue
          ArgumentError -> {:error, :invalid_scene}
        end

      {:error, :invalid_scene} ->
        {:error, :invalid_scene}
    end
  end

  # -- scene directory ------------------------------------------------------

  defp scene_dir do
    case Application.get_env(:chronos, :scene_dir) do
      dir when is_binary(dir) -> Path.expand(dir)
      dir when is_list(dir) -> dir |> List.to_string() |> Path.expand()
      _other -> Application.app_dir(:chronos, "priv/scenes")
    end
  end

  defp ensure_scene_dir(dir) do
    File.mkdir_p!(dir)
    :ok
  rescue
    error in File.Error -> {:error, error.reason}
  end

  # The name regex forbids "/" and "..". Keep an explicit path check as a
  # defence-in-depth guard before every filesystem operation.
  defp scene_path(dir, name) do
    path = Path.join(dir, name <> ".json")
    expanded_path = Path.expand(path)
    expanded_dir = Path.expand(dir)

    if Path.dirname(expanded_path) == expanded_dir and
         Path.basename(expanded_path) == name <> ".json" do
      path
    else
      raise ArgumentError, "unsafe scene path: #{inspect(path)}"
    end
  end

  defp encode_scene(scene) do
    case Jason.encode(scene, pretty: true) do
      {:ok, body} -> {:ok, body}
      {:error, _reason} -> {:error, :invalid_scene}
    end
  end

  defp write_scene(dir, name, scene) do
    with {:ok, body} <- encode_scene(scene) do
      write_json(dir, name, body)
    end
  end

  defp write_json(dir, name, body) do
    path = scene_path(dir, name)
    tmp = temporary_path(dir, name)

    case File.write(tmp, body, [:binary, :exclusive]) do
      :ok ->
        case File.rename(tmp, path) do
          :ok ->
            :ok

          {:error, reason} ->
            File.rm(tmp)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp temporary_path(dir, name) do
    unique_id = :erlang.unique_integer([:positive])
    timestamp = System.os_time(:nanosecond)
    Path.join(dir, "#{name}.tmp.#{unique_id}.#{timestamp}")
  end

  defp create_scene(dir, name, body) do
    path = scene_path(dir, name)

    if File.exists?(path) do
      {:error, :name_taken}
    else
      case write_json(dir, name, body) do
        :ok ->
          case read_scene(path) do
            {:ok, scene} -> {:ok, scene}
            {:error, _reason} -> {:error, :invalid_scene}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_lock_id(dir, name) do
    {{__MODULE__, Path.expand(dir), name}, self()}
  end

  defp read_scene(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, scene} ->
            case validate(scene) do
              :ok -> {:ok, scene}
              {:error, :invalid_scene} -> {:error, :not_found}
            end

          {:error, _reason} ->
            {:error, :not_found}
        end

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  # -- name/validation helpers ---------------------------------------------

  defp valid_name?(name) when is_binary(name), do: Regex.match?(@name_regex, name)
  defp valid_name?(_name), do: false

  defp scene_name(%{"name" => name}) when is_binary(name) do
    if valid_name?(name), do: {:ok, name}, else: {:error, :invalid_name}
  end

  defp scene_name(%{"name" => _name}), do: {:error, :invalid_name}
  defp scene_name(_scene), do: {:error, :invalid_scene}

  defp valid_scene?(scene) when is_map(scene) do
    name = Map.get(scene, "name")
    nodes = Map.get(scene, "nodes")
    walls = Map.get(scene, "walls")

    valid_name?(name) and
      valid_description?(Map.get(scene, "description")) and
      is_list(nodes) and nodes != [] and length(nodes) <= @max_scene_items and
      Enum.all?(nodes, &valid_node?/1) and
      unique_ids?(nodes) and
      is_list(walls) and length(walls) <= @max_scene_items and
      Enum.all?(walls, &valid_wall?/1) and
      unique_ids?(walls) and
      json_encodable?(scene)
  end

  defp valid_scene?(_scene), do: false

  defp valid_description?(nil), do: true
  defp valid_description?(description), do: is_binary(description)

  defp valid_node?(%{"id" => id, "type" => type, "pos" => pos, "vel" => vel}) do
    valid_id?(id) and type in @node_types and vec3?(pos) and vec3?(vel)
  end

  defp valid_node?(_node), do: false

  defp valid_wall?(%{"id" => id, "vertices" => vertices, "normal" => normal} = wall) do
    valid_id?(id) and valid_vertices?(vertices) and vec3?(normal) and
      valid_attenuation?(Map.get(wall, "attenuation_db")) and
      valid_material?(Map.get(wall, "material"))
  end

  defp valid_wall?(_wall), do: false

  defp valid_id?(id) when is_atom(id) do
    id |> Atom.to_string() |> String.length() <= @max_id_length
  end

  defp valid_id?(id) when is_binary(id) do
    id != "" and String.length(id) <= @max_id_length
  end

  defp valid_id?(_id), do: false

  defp valid_vertices?(vertices) when is_list(vertices) do
    length(vertices) >= 3 and Enum.all?(vertices, &vec3?/1)
  end

  defp valid_vertices?(_vertices), do: false

  defp valid_attenuation?(nil), do: true
  defp valid_attenuation?(value), do: is_number(value)

  defp valid_material?(nil), do: true
  defp valid_material?(value), do: is_binary(value)

  defp vec3?([x, y, z]), do: is_number(x) and is_number(y) and is_number(z)
  defp vec3?(_other), do: false

  defp unique_ids?(items) do
    ids = Enum.map(items, &normalize_id(Map.get(&1, "id")))
    length(ids) == length(Enum.uniq(ids))
  end

  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id), do: id

  defp json_encodable?(scene) do
    match?({:ok, _body}, Jason.encode(scene))
  end

  # -- scene -> world -------------------------------------------------------

  defp build_world(scene) do
    scene
    |> Map.get("nodes", [])
    |> Enum.reduce(World.new(), fn node, world -> World.add_node(world, build_node(node)) end)
    |> then(fn world ->
      scene
      |> Map.get("walls", [])
      |> Enum.reduce(world, fn wall, acc -> add_wall(acc, wall) end)
    end)
  end

  defp build_node(%{"id" => id, "type" => type, "pos" => pos, "vel" => vel}) do
    %World.Node{
      id: to_id(id),
      type: type_to_atom(type),
      pos: list_to_vec(pos),
      vel: list_to_vec(vel)
    }
  end

  defp add_wall(world, wall) do
    World.add_wall(world, build_wall(wall))
  end

  defp build_wall(%{"id" => id, "vertices" => vertices, "normal" => normal} = wall) do
    %World.Wall{
      id: to_id(id),
      vertices: Enum.map(vertices, &list_to_vec/1),
      normal: list_to_vec(normal),
      attenuation_db: wall_attenuation_db(wall)
    }
  end

  defp list_to_vec([x, y, z]), do: {x * 1.0, y * 1.0, z * 1.0}

  defp type_to_atom("tx"), do: :tx
  defp type_to_atom("rx"), do: :rx

  defp to_id(value) when is_atom(value), do: value

  defp to_id(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp wall_attenuation_db(%{"attenuation_db" => attenuation_db})
       when is_number(attenuation_db),
       do: attenuation_db

  defp wall_attenuation_db(wall) do
    material_reflection_loss_db(Map.get(wall, "material"))
  end

  defp material_reflection_loss_db(material) do
    module = Chronos.Material

    if Code.ensure_loaded?(module) and function_exported?(module, :reflection_loss_db, 1) do
      case apply(module, :reflection_loss_db, [%{attenuation_db: nil, material: material}]) do
        loss when is_number(loss) -> loss
        _other -> @default_attenuation_db
      end
    else
      fallback_material_reflection_loss_db(material)
    end
  rescue
    _error -> fallback_material_reflection_loss_db(material)
  end

  defp fallback_material_reflection_loss_db(material) when is_binary(material) do
    Map.get(@material_reflection_losses, material, @default_attenuation_db)
  end

  defp fallback_material_reflection_loss_db(_material), do: @default_attenuation_db
end
