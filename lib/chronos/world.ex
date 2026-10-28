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
    @moduledoc "A planar polygon with a material that reflects and occludes signals."

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
