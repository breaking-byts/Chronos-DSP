defmodule Chronos.SceneStore do
  @moduledoc """
  File-backed store for named user scenes — ephemeral by design (ADR 0001).

  A scene is a map with:

    * `"name"` - the file stem, restricted to `[a-z0-9_-]`, 1..64 chars;
    * `"description"` - optional free text, at most 1 KiB;
    * `"nodes"` - list of `%{id, type ("tx"|"rx"), pos: [x,y,z], vel: [x,y,z]}`;
    * `"walls"` - list of `%{id, vertices: [[x,y,z],...] (3..256), normal:
      [x,y,z], attenuation_db: optional non-negative number, material: optional
      catalogue id}`.

  Node and wall ids are limited to 64 characters; each scene may contain at
  most 1024 nodes and 1024 walls. Walls carry a `Chronos.Material` id; an
  explicit `attenuation_db` overrides only the reflection loss (and only when
  finite and non-negative), while transmission and diffraction always come
  from the material.

  Storage is capped for the anonymous public showcase: at most 100 scenes,
  10 MiB total, and 64 KiB per scene. Writing beyond a cap evicts the oldest
  scenes first (by file modification time; an overwrite refreshes a scene's
  modification time). Orphaned temporary files and invalid JSON are cleaned up
  on write. Any visitor may delete any scene (single-tenant showcase, no
  ownership — ADR 0001).

  Scenes are stored as pretty JSON, one file per scene, in a configurable
  directory (Application env `:chronos`, `:scene_dir`; `SCENE_DIR` at runtime;
  default `priv/scenes` under the app root). The default lives inside the
  release, so scenes are lost on redeploy unless `SCENE_DIR` points at a
  persistent volume. `list/0` re-reads and re-validates every file (O(N),
  bounded by the 100-scene cap); caching is a performance-track follow-up.
  """

  alias Chronos.Material
  alias Chronos.World

  @type scene :: map()

  @name_regex ~r/\A[a-z0-9_-]{1,64}\z/
  @node_types ["tx", "rx"]
  @max_id_length 64
  @max_scene_items 1024
  @max_vertices 256
  @max_description_bytes 1024
  @max_scene_bytes 64 * 1024
  @max_scenes 100
  # Defensive backstop: at 100 scenes x 64 KiB the count cap binds first
  # (~6.25 MiB < 10 MiB), so the total cap rarely evicts on its own.
  @max_total_bytes 10 * 1024 * 1024
  @material_ids Enum.map(Material.ids(), &Atom.to_string/1)

  @doc """
  The per-scene item cap (1024) shared by nodes and walls. The editing panel
  bounds its add-wall button by this cap so an edited world always stays
  saveable as a scene (#35).
  """
  @spec max_scene_items() :: pos_integer()
  def max_scene_items, do: @max_scene_items

  @doc """
  The scene-count cap (100). The save/load UI shows an "N/100 scenes" counter
  and the oldest-first-by-mtime eviction note against this cap (#36).
  """
  @spec max_scenes() :: pos_integer()
  def max_scenes, do: @max_scenes

  @doc """
  Lists every stored scene sorted by name.

  Unreadable or malformed files are skipped rather than raising. A missing
  scene directory is treated as empty.
  """
  @spec list() :: [scene()]
  def list do
    dir = scene_dir()

    dir
    |> scene_names()
    |> Enum.flat_map(fn name ->
      case get(name) do
        {:ok, scene} -> [scene]
        _error -> []
      end
    end)
    |> Enum.sort_by(&Map.get(&1, "name", ""))
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

  Writes are serialized per directory, so concurrent callers cannot both
  create the same name and the storage caps are enforced atomically. The
  persisted scene is read back before it is returned, so the response always
  represents the complete file on disk. Creating beyond a cap evicts the
  oldest scenes (by modification time).
  """
  @spec create(scene()) ::
          {:ok, scene()}
          | {:error, :invalid_scene | :invalid_name | :name_taken | File.posix()}
  def create(scene) do
    with {:ok, dir, name, body} <- prepare_scene(scene) do
      with_dir_lock(dir, fn -> create_scene(dir, name, body) end)
    end
  end

  @doc """
  Persists a validated scene, replacing any existing file with the same name.

  Like `create/1` this enforces the per-scene byte cap and evicts oldest
  scenes when a cap would be exceeded (the scene's own name is excluded from
  the count, since it is being replaced). The scene is written to a unique
  sibling temporary file and atomically renamed into place.
  """
  @spec save(scene()) :: :ok | {:error, :invalid_scene | :invalid_name | File.posix()}
  def save(scene) do
    with {:ok, dir, name, body} <- prepare_scene(scene) do
      with_dir_lock(dir, fn ->
        cleanup_orphans(dir)

        with :ok <- make_room(dir, name, byte_size(body)) do
          write_json(dir, name, body)
        end
      end)
    end
  end

  # Shared create/save pipeline: validate, resolve the directory, encode, and
  # enforce the per-scene byte cap before taking the directory lock.
  defp prepare_scene(scene) do
    with {:ok, name} <- scene_name(scene),
         :ok <- validate(scene),
         dir = scene_dir(),
         :ok <- ensure_scene_dir(dir),
         {:ok, body} <- encode_scene(scene),
         :ok <- check_scene_size(body) do
      {:ok, dir, name, body}
    end
  end

  @doc """
  Deletes a stored scene.

  Returns `{:error, :not_found}` when the scene does not exist. Any visitor
  may delete any scene (single-tenant showcase, no ownership — ADR 0001).

  Like create/save, the deletion is serialized under the per-directory lock:
  a successful create reads its file back and save evicts to make room, so an
  interleaved unlink could otherwise undo a write or make a valid create fail.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found | :invalid_name | File.posix()}
  def delete(name) do
    with :ok <- validate_name(name),
         dir = scene_dir() do
      with_dir_lock(dir, fn ->
        case File.rm(scene_path(dir, name)) do
          :ok -> :ok
          {:error, :enoent} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
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
  strings, so untrusted scene data never grows the atom table. Each wall
  carries its `Chronos.Material` id (validated against the catalogue; the
  `Material.get/1` concrete fallback is defense-in-depth). `attenuation_db` is
  the explicit reflection override, or `nil` when the material's own reflection
  loss applies.
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

  defp check_scene_size(body) do
    if byte_size(body) <= @max_scene_bytes, do: :ok, else: {:error, :invalid_scene}
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
    cleanup_orphans(dir)
    path = scene_path(dir, name)

    if File.exists?(path) do
      {:error, :name_taken}
    else
      with :ok <- make_room(dir, name, byte_size(body)) do
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
  end

  # Writes are serialized per directory so the count/byte caps and the
  # name-uniqueness check are atomic across concurrent callers. :global.trans
  # takes {ResourceId, OwnerPid}: the resource {Module, dir} is shared across
  # processes (this is what gives mutual exclusion), while self() is the
  # per-caller lock owner. Do NOT drop self() (a bare/1-tuple is not a valid
  # lock id and raises FunctionClauseError) and do NOT put self() inside the
  # resource (that would make every caller lock a different resource).
  # Verified empirically: 40 concurrent callers -> at most 1 inside.
  defp with_dir_lock(dir, fun) do
    :global.trans(dir_lock_id(dir), fun)
  end

  # Internal seam exposed so concurrency tests share the exact lock id without
  # duplicating the {Module, expanded_dir} tuple structure.
  @doc false
  def dir_lock_id(dir) do
    {{__MODULE__, Path.expand(dir)}, self()}
  end

  # Evict oldest scenes (by mtime) until adding `new_bytes` for `name`
  # fits both the scene-count and total-byte caps. `name` is excluded from the
  # existing entries so an overwrite does not count itself.
  defp make_room(dir, name, new_bytes) do
    entries =
      dir
      |> scene_files()
      |> Enum.reject(&(&1.name == name))

    evict(dir, entries, new_bytes)
  end

  defp evict(dir, entries, new_bytes) do
    count = length(entries)
    total = Enum.sum(Enum.map(entries, & &1.size))

    if count + 1 <= @max_scenes and total + new_bytes <= @max_total_bytes do
      :ok
    else
      case oldest(entries) do
        nil ->
          :ok

        entry ->
          _ = File.rm(entry.path)
          evict(dir, List.delete(entries, entry), new_bytes)
      end
    end
  end

  defp oldest([]), do: nil
  defp oldest(entries), do: Enum.min_by(entries, & &1.mtime)

  # Valid scene stems present in the directory.
  defp scene_names(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.filter(&valid_name?/1)

      {:error, _reason} ->
        []
    end
  end

  defp scene_files(dir) do
    dir
    |> scene_names()
    |> Enum.flat_map(fn name ->
      path = scene_path(dir, name)

      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{size: size, mtime: mtime}} ->
          [%{name: name, path: path, size: size, mtime: mtime}]

        {:error, _reason} ->
          []
      end
    end)
  end

  # Remove crash-orphaned temporary files and any .json that is not a valid
  # stored scene (unparseable or schema-invalid). Since create/save only write
  # validated scenes, such files are corrupt or tampered and would otherwise
  # count against the caps while remaining invisible to list/0 (ghost scenes).
  defp cleanup_orphans(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.each(names, fn entry ->
          path = Path.join(dir, entry)

          cond do
            String.contains?(entry, ".tmp.") ->
              _ = File.rm(path)

            String.ends_with?(entry, ".json") ->
              remove_invalid_scene(path)

            true ->
              :ok
          end
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp remove_invalid_scene(path) do
    case read_scene(path) do
      {:ok, _scene} -> :ok
      {:error, _reason} -> _ = File.rm(path)
    end
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

  defp valid_description?(description) do
    is_binary(description) and byte_size(description) <= @max_description_bytes
  end

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
    length(vertices) >= 3 and length(vertices) <= @max_vertices and
      Enum.all?(vertices, &vec3?/1)
  end

  defp valid_vertices?(_vertices), do: false

  defp valid_attenuation?(nil), do: true
  defp valid_attenuation?(value), do: is_number(value) and value >= 0

  defp valid_material?(nil), do: true
  defp valid_material?(value), do: is_binary(value) and value in @material_ids

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
    material = Material.get(Map.get(wall, "material"))

    %World.Wall{
      id: to_id(id),
      vertices: Enum.map(vertices, &list_to_vec/1),
      normal: list_to_vec(normal),
      material: material.id,
      attenuation_db: Map.get(wall, "attenuation_db")
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
end
