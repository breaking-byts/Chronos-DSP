defmodule Chronos.World do
  @moduledoc """
  Mutable-by-replacement world state for the propagation simulator.

  Nodes are transmitters (`:tx`) or receivers (`:rx`) with a 3D position and
  velocity. Walls are planar polygons associated with a material. An optional
  explicit reflection attenuation can override that material's reflection loss.
  """

  alias Chronos.Geometry

  defmodule Node do
    @moduledoc "A transmitter or receiver in the world."

    @type t :: %__MODULE__{
            id: term(),
            type: :tx | :rx,
            pos: {float(), float(), float()},
            vel: {float(), float(), float()}
          }

    @enforce_keys [:id, :type, :pos, :vel]
    defstruct [:id, :type, :pos, :vel]
  end

  defmodule Wall do
    @moduledoc """
    A planar polygon with a material that reflects and occludes signals.

    An optional `attenuation_db` overrides the material's reflection loss only
    when finite and non-negative; invalid overrides are ignored
    (`Chronos.Material.reflection_loss_db/1`).
    """

    @type t :: %__MODULE__{
            id: term(),
            vertices: list({float(), float(), float()}),
            normal: {float(), float(), float()},
            material: atom(),
            attenuation_db: number() | nil
          }

    @enforce_keys [:id, :vertices, :normal]
    defstruct [:id, :vertices, :normal, material: :concrete, attenuation_db: nil]
  end

  @type vec3 :: {float(), float(), float()}
  @type t :: %__MODULE__{time_s: float(), nodes: map(), walls: map()}

  # Tolerance used when deciding whether a segment intersection happens in the
  # interior of the segment rather than at one of its ends.
  @epsilon 1.0e-9

  @enforce_keys [:time_s, :nodes, :walls]
  defstruct [:time_s, :nodes, :walls]

  @spec new() :: %__MODULE__{}
  def new, do: %__MODULE__{time_s: 0.0, nodes: %{}, walls: %{}}

  @spec add_node(%__MODULE__{}, Node.t()) :: %__MODULE__{}
  def add_node(%__MODULE__{nodes: nodes} = world, %Node{id: id} = node) do
    %{world | nodes: Map.put(nodes, id, node)}
  end

  @spec add_wall(%__MODULE__{}, Wall.t()) :: %__MODULE__{}
  def add_wall(%__MODULE__{walls: walls} = world, %Wall{id: id} = wall) do
    %{world | walls: Map.put(walls, id, wall)}
  end

  @spec node(%__MODULE__{}, term()) :: Node.t() | nil
  def node(%__MODULE__{nodes: nodes}, id), do: Map.get(nodes, id)

  @doc """
  Returns true when the segment `a`-`b` intersects any wall polygon.

  `ignore_ids` lists the walls that are skipped, which is how a path model
  allows the walls it legitimately touches (the wall it reflects off, for
  example) without treating them as occluders.
  """
  @spec segment_occluded_by?(Geometry.vec3(), Geometry.vec3(), [Wall.t()], [term()]) ::
          boolean()
  def segment_occluded_by?(_a, _b, [], _ignore_ids), do: false

  def segment_occluded_by?(a, b, walls, ignore_ids) do
    Enum.any?(walls, fn
      %Wall{id: id, vertices: vertices, normal: normal} ->
        id not in ignore_ids and length(vertices) >= 3 and
          Geometry.segment_intersects_polygon?(a, b, vertices, normal)

      _ ->
        false
    end)
  end

  @doc """
  Returns true when the segment `a`-`b` passes *through* a wall polygon.

  Unlike `segment_occluded_by?/4`, an intersection at the very end of the
  segment does not block the path: a leg that only grazes the corner of a wall
  it does not bounce off is not blocked by that wall.
  """
  @spec segment_blocked_by?(Geometry.vec3(), Geometry.vec3(), [Wall.t()], [term()]) ::
          boolean()
  def segment_blocked_by?(a, b, walls, ignore_ids) do
    Enum.any?(walls, fn
      %Wall{id: id, vertices: vertices, normal: normal} ->
        id not in ignore_ids and length(vertices) >= 3 and
          blocks?(a, b, vertices, normal)

      _ ->
        false
    end)
  end

  defp blocks?(a, b, vertices, normal) do
    case Geometry.segment_plane_intersect(a, b, hd(vertices), normal) do
      {:ok, point, t} ->
        # Only an intersection in the interior of the leg, and strictly inside
        # the wall, blocks the leg. A leg that ends on a wall (the wall it
        # bounces off) or that grazes a wall edge passes it.
        t > @epsilon and t < 1.0 - @epsilon and
          Geometry.point_strictly_inside_polygon?(point, vertices, normal)

      _ ->
        false
    end
  end

  @doc """
  Moves an existing node to a new position and velocity.

  Returns `{:ok, world}` or `{:error, :unknown_node}`. Prefer this over
  `add_node/2` when updating kinematics because it will not silently create a
  node with a typoed id.
  """
  @spec move_node(t(), term(), vec3(), vec3()) :: {:ok, t()} | {:error, :unknown_node}
  def move_node(%__MODULE__{nodes: nodes} = world, id, pos, vel) do
    case Map.fetch(nodes, id) do
      {:ok, %Node{} = node} ->
        {:ok, %{world | nodes: Map.put(nodes, id, %{node | pos: pos, vel: vel})}}

      :error ->
        {:error, :unknown_node}
    end
  end

  @spec wall(%__MODULE__{}, term()) :: Wall.t() | nil
  def wall(%__MODULE__{walls: walls}, id), do: Map.get(walls, id)

  @doc """
  Removes a wall by id. Returns `{:ok, world}` or `{:error, :unknown_wall}`.
  Nodes are never touched: the TX/RX node count is fixed for v1 (#35).
  """
  @spec remove_wall(t(), term()) :: {:ok, t()} | {:error, :unknown_wall}
  def remove_wall(%__MODULE__{walls: walls} = world, id) do
    case Map.pop(walls, id) do
      {nil, _walls} -> {:error, :unknown_wall}
      {_wall, remaining} -> {:ok, %{world | walls: remaining}}
    end
  end

  @doc """
  Sets a node's z height, preserving its x/y position and velocity.
  Returns `{:ok, world}` or `{:error, :unknown_node}`.
  """
  @spec set_node_z(t(), term(), number()) :: {:ok, t()} | {:error, :unknown_node}
  def set_node_z(%__MODULE__{nodes: nodes} = world, id, z) do
    case Map.fetch(nodes, id) do
      {:ok, %Node{pos: {x, y, _}} = node} ->
        {:ok, %{world | nodes: Map.put(nodes, id, %{node | pos: {x, y, z * 1.0}})}}

      :error ->
        {:error, :unknown_node}
    end
  end

  @doc """
  The wall's reference height: the mean z of its vertices. The panel's single
  per-wall z field displays and edits this value (#35).
  """
  @spec wall_z(Wall.t()) :: float()
  def wall_z(%Wall{vertices: []}), do: 0.0

  def wall_z(%Wall{vertices: vertices}) do
    Enum.sum(Enum.map(vertices, fn {_x, _y, z} -> z end)) / length(vertices)
  end

  @doc """
  Moves a wall to a new reference height (`wall_z/1`), preserving x/y.

  Every vertex is shifted by the SAME delta `z - wall_z(wall)`, so the wall
  keeps its shape and vertical extent (a vertical wall stays vertical). This
  is a pure z translation: setting all vertices to one flat z would collapse
  the default vertical walls to a degenerate line. For a wall whose vertices
  already share one z, the shift is equivalent to setting that z directly.
  Returns `{:ok, world}` or `{:error, :unknown_wall}`.
  """
  @spec set_wall_z(t(), term(), number()) :: {:ok, t()} | {:error, :unknown_wall}
  def set_wall_z(%__MODULE__{walls: walls} = world, id, z) do
    case Map.fetch(walls, id) do
      {:ok, %Wall{vertices: vertices} = wall} ->
        delta = z * 1.0 - wall_z(wall)
        moved = Enum.map(vertices, fn {x, y, vz} -> {x, y, vz + delta} end)
        {:ok, %{world | walls: Map.put(walls, id, %{wall | vertices: moved})}}

      :error ->
        {:error, :unknown_wall}
    end
  end

  @doc """
  Sets a wall's material id (a `Chronos.Material` catalogue atom).
  Returns `{:ok, world}` or `{:error, :unknown_wall}`. Catalogue membership is
  validated by the caller (`Chronos.PanelEdit` / `ChronosWeb.ApiParams`).
  """
  @spec set_wall_material(t(), term(), atom()) :: {:ok, t()} | {:error, :unknown_wall}
  def set_wall_material(%__MODULE__{walls: walls} = world, id, material) do
    case Map.fetch(walls, id) do
      {:ok, %Wall{} = wall} ->
        {:ok, %{world | walls: Map.put(walls, id, %{wall | material: material})}}

      :error ->
        {:error, :unknown_wall}
    end
  end

  @doc """
  Sets a wall's explicit reflection-loss override, or clears it with `nil`
  ("Auto": the material's reflection loss applies, `Chronos.Material`).
  Returns `{:ok, world}` or `{:error, :unknown_wall}`.
  """
  @spec set_wall_attenuation(t(), term(), number() | nil) ::
          {:ok, t()} | {:error, :unknown_wall}
  def set_wall_attenuation(%__MODULE__{walls: walls} = world, id, attenuation_db) do
    case Map.fetch(walls, id) do
      {:ok, %Wall{} = wall} ->
        {:ok, %{world | walls: Map.put(walls, id, %{wall | attenuation_db: attenuation_db})}}

      :error ->
        {:error, :unknown_wall}
    end
  end

  @doc """
  Returns a fresh unique wall id (`"wall_1"`, `"wall_2"`, ...) not present in
  the world, for the panel's add-wall button (#35). Ids stay strings so
  untrusted sessions never grow the atom table.
  """
  @spec next_wall_id(t()) :: String.t()
  def next_wall_id(%__MODULE__{walls: walls}) do
    existing = MapSet.new(walls, fn {id, _wall} -> to_string(id) end)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn n ->
      id = "wall_#{n}"
      if MapSet.member?(existing, id), do: nil, else: id
    end)
  end

  @spec nodes_by_type(%__MODULE__{}, atom()) :: list(Node.t())
  def nodes_by_type(%__MODULE__{nodes: nodes}, type) do
    nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == type))
  end

  @spec step(%__MODULE__{}, float()) :: %__MODULE__{}
  def step(%__MODULE__{} = world, dt) do
    nodes =
      world.nodes
      |> Enum.map(fn {id, node} -> {id, update_node(node, dt)} end)
      |> Map.new()

    %{world | nodes: nodes, time_s: world.time_s + dt}
  end

  @spec update_node(Node.t(), float()) :: Node.t()
  def update_node(%Node{pos: {x, y, z}, vel: {vx, vy, vz}} = node, dt) do
    %Node{node | pos: {x + vx * dt, y + vy * dt, z + vz * dt}}
  end
end
