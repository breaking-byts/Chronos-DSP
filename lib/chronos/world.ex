defmodule Chronos.World do
  defmodule Node do
    @enforce_keys [:id, :type, :pos, :vel]
    defstruct [:id, :type, :pos, :vel]
  end

  defmodule Wall do
    @enforce_keys [:id, :vertices, :normal, :attenuation_db]
    defstruct [:id, :vertices, :normal, :attenuation_db]
  end

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
