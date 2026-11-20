defmodule Chronos.PanelEdit do
  @moduledoc """
  Server-side validation and application of editing-panel property commits
  (issue #35, slice 3 of #20). Sibling of `Chronos.SceneEdit` (drag commits):
  the panel edits properties, not XY geometry, so every function here preserves
  x/y. The client is never trusted — `ChronosWeb.SimLive` parses and validates
  form values through `ChronosWeb.ApiParams` first, and this module re-guards
  types, ranges, catalogue membership, entity existence, and the scene caps
  before touching the world. Commits reach the session through
  `Chronos.SimServer.update_world/2`.

  Semantics:

    * Attenuation override — a finite number in `0..40` dB sets
      `wall.attenuation_db`, overriding ONLY the material's reflection loss
      (`Chronos.Material.reflection_loss_db/1`). `nil` means "Auto (use
      material)": the override is cleared and the material's value applies.
    * z height — a finite number in `-5..+5` m. For a node it replaces pos z
      (x/y and velocity preserved). For a wall the single field edits the
      wall's reference height (`Chronos.World.wall_z/1`, the mean vertex z):
      every vertex shifts by the same delta, keeping the wall's shape and
      vertical extent. Drag never edits z (#34).
    * Material — must be one of the 11 `Chronos.Material` catalogue ids.
    * Add wall — creates a short default vertical wall near the viewport
      center, bounded by the scene item cap (`Chronos.SceneStore`, 1024
      walls) so edited worlds stay saveable. Node count is FIXED: no panel
      operation adds or removes nodes.
  """

  alias Chronos.Channel.Physics
  alias Chronos.Material
  alias Chronos.SceneStore
  alias Chronos.World

  # Range constants mirror ChronosWeb.ApiParams (the form-boundary validators).
  @attenuation_range {0.0, 40.0}
  @z_range {-5.0, 5.0}
  @default_wall_half_length 0.5
  @default_wall_half_height 0.5
  # Repeated adds stagger along x so new walls do not stack exactly.
  @add_stagger 0.25
  @add_stagger_period 8

  @doc "The attenuation-override bounds in dB (`0..40`), per the design lock."
  @spec attenuation_range() :: {float(), float()}
  def attenuation_range, do: @attenuation_range

  @doc "The z-height bounds in metres (`-5..+5`), per the design lock."
  @spec z_range() :: {float(), float()}
  def z_range, do: @z_range

  @doc "Maximum walls in an edited world (the scene item cap)."
  @spec max_walls() :: pos_integer()
  def max_walls, do: SceneStore.max_scene_items()

  @doc """
  Sets a wall's reflection-loss override, or clears it with `nil` (Auto).
  Returns `{:ok, world}` or `{:error, :invalid_payload | :invalid_value |
  :unknown_entity}`.
  """
  @spec set_wall_attenuation(World.t(), term(), number() | nil) ::
          {:ok, World.t()} | {:error, :invalid_payload | :invalid_value | :unknown_entity}
  def set_wall_attenuation(%World{} = world, id, db) do
    with {:ok, wall} <- fetch_wall(world, id),
         :ok <- validate_attenuation(db) do
      World.set_wall_attenuation(world, wall.id, db)
    end
  end

  @doc """
  Sets a node's z height (x/y and velocity preserved).
  Returns `{:ok, world}` or `{:error, :invalid_payload | :invalid_value |
  :unknown_entity}`.
  """
  @spec set_node_z(World.t(), term(), number()) ::
          {:ok, World.t()} | {:error, :invalid_payload | :invalid_value | :unknown_entity}
  def set_node_z(%World{} = world, id, z) do
    with {:ok, node} <- fetch_node(world, id),
         :ok <- validate_z(z) do
      World.set_node_z(world, node.id, z)
    end
  end

  @doc """
  Moves a wall to a new reference height by a pure z translation (x/y and
  shape preserved). Returns `{:ok, world}` or `{:error, :invalid_payload |
  :invalid_value | :unknown_entity}`.
  """
  @spec set_wall_z(World.t(), term(), number()) ::
          {:ok, World.t()} | {:error, :invalid_payload | :invalid_value | :unknown_entity}
  def set_wall_z(%World{} = world, id, z) do
    with {:ok, wall} <- fetch_wall(world, id),
         :ok <- validate_z(z) do
      World.set_wall_z(world, wall.id, z)
    end
  end

  @doc """
  Sets a wall's material from a catalogue id (atom or string). Unknown ids are
  rejected, never silently defaulted. Returns `{:ok, world}` or
  `{:error, :invalid_payload | :invalid_value | :unknown_entity}`.
  """
  @spec set_wall_material(World.t(), term(), atom() | String.t()) ::
          {:ok, World.t()} | {:error, :invalid_payload | :invalid_value | :unknown_entity}
  def set_wall_material(%World{} = world, id, material) do
    with {:ok, wall} <- fetch_wall(world, id),
         {:ok, catalogue_id} <- validate_material(material) do
      World.set_wall_material(world, wall.id, catalogue_id)
    end
  end

  @doc """
  Adds a short default wall (1 m long, 1 m tall, concrete, Auto attenuation)
  near the center of `bounds` (tuple form, `Chronos.Scene.bounds/1`). Bounded
  by `max_walls/0`; nodes are never touched. Returns `{:ok, world}` or
  `{:error, :wall_cap_reached}`.
  """
  @spec add_wall(World.t(), Chronos.Scene.bounds()) ::
          {:ok, World.t()} | {:error, :wall_cap_reached}
  def add_wall(%World{walls: walls} = world, %{min: {min_x, min_y}, max: {max_x, max_y}}) do
    if map_size(walls) >= max_walls() do
      {:error, :wall_cap_reached}
    else
      cx = (min_x + max_x) / 2.0 + @add_stagger * rem(map_size(walls), @add_stagger_period)
      cy = (min_y + max_y) / 2.0
      hl = @default_wall_half_length
      hh = @default_wall_half_height

      wall = %World.Wall{
        id: World.next_wall_id(world),
        vertices: [
          {cx, cy - hl, -hh},
          {cx, cy + hl, -hh},
          {cx, cy + hl, hh},
          {cx, cy - hl, hh}
        ],
        normal: {1.0, 0.0, 0.0},
        material: Material.default().id,
        attenuation_db: nil
      }

      {:ok, World.add_wall(world, wall)}
    end
  end

  @doc """
  Removes a wall by id. Nodes are never touched (fixed node count, v1).
  Returns `{:ok, world}` or `{:error, :invalid_payload | :unknown_entity}`.
  """
  @spec remove_wall(World.t(), term()) ::
          {:ok, World.t()} | {:error, :invalid_payload | :unknown_entity}
  def remove_wall(%World{} = world, id) do
    with {:ok, wall} <- fetch_wall(world, id) do
      World.remove_wall(world, wall.id)
    end
  end

  # -- validation (pure; mirrors the ChronosWeb.ApiParams form validators) --

  defp validate_attenuation(nil), do: :ok

  defp validate_attenuation(db) do
    {minimum, maximum} = @attenuation_range

    if is_number(db) and Physics.finite?(db) and db >= minimum and db <= maximum do
      :ok
    else
      {:error, :invalid_value}
    end
  end

  defp validate_z(z) do
    {minimum, maximum} = @z_range

    if is_number(z) and Physics.finite?(z) and z >= minimum and z <= maximum do
      :ok
    else
      {:error, :invalid_value}
    end
  end

  defp validate_material(id) do
    case Material.fetch(id) do
      nil -> {:error, :invalid_value}
      material -> {:ok, material.id}
    end
  end

  defp fetch_node(_world, id) when not is_binary(id), do: {:error, :invalid_payload}

  defp fetch_node(world, id) do
    case Enum.find(world.nodes, fn {node_id, _node} -> to_string(node_id) == id end) do
      {_id, node} -> {:ok, node}
      nil -> {:error, :unknown_entity}
    end
  end

  defp fetch_wall(_world, id) when not is_binary(id), do: {:error, :invalid_payload}

  defp fetch_wall(world, id) do
    case Enum.find(world.walls, fn {wall_id, _wall} -> to_string(wall_id) == id end) do
      {_id, wall} -> {:ok, wall}
      nil -> {:error, :unknown_entity}
    end
  end
end
