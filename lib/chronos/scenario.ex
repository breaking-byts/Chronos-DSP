defmodule Chronos.Scenario do
  @moduledoc """
  Built-in demo scenes and their kinematics.

  A scenario owns both a world and an optional per-tick update. The dashboard
  uses `:orbit` by default: a receiver circles a transmitter in front of two
  planar walls, so line-of-sight, reflections, path loss and Doppler all change
  over time. `:open_field` uses the same motion without walls.
  """

  alias Chronos.World

  # The receiver orbits on an ellipse in front of the transmitter. The walls sit
  # behind the transmitter (lower-left) so they add reflections without ever
  # cutting the receiver off from every path.
  @orbit_center {2.4, 0.0}
  @orbit_rx 1.6
  @orbit_ry 1.8
  @orbit_omega 0.55
  @orbit_phase 0.0
  @default_bounds %{min: {-3.0, -3.0}, max: {4.4, 3.0}}

  @scenarios [
    %{
      id: "orbit",
      name: "Orbit + corner walls",
      description: "A receiver orbits in front of two reflective walls."
    },
    %{
      id: "open_field",
      name: "Open field",
      description: "Line-of-sight only; useful as a clean baseline."
    }
  ]

  @type id :: String.t()

  @doc "Returns the scenario catalogue used by the UI."
  @spec list() :: [%{id: id(), name: String.t(), description: String.t()}]
  def list, do: @scenarios

  @doc "Returns the default scenario id."
  @spec default_id() :: id()
  def default_id, do: "orbit"

  @doc "Returns all valid scenario ids."
  @spec ids() :: [id()]
  def ids, do: Enum.map(@scenarios, & &1.id)

  @doc "Returns a human-readable scenario name."
  @spec name(id()) :: String.t()
  def name(id) do
    Enum.find_value(@scenarios, fn scenario ->
      if scenario.id == normalize(id), do: scenario.name
    end) || normalize(id)
  end

  @doc "Builds a fresh world for the given scenario."
  @spec world(id() | atom()) :: World.t()
  def world(id \\ default_id())

  def world("orbit"), do: base_world() |> add_orbit_walls()
  def world("open_field"), do: base_world()
  def world(other) when is_atom(other), do: world(Atom.to_string(other))
  def world(_other), do: world(default_id())

  @doc "Returns the fixed viewport bounds for a scenario."
  @spec bounds(id() | atom()) :: Chronos.Scene.bounds()
  def bounds(_id \\ default_id()), do: @default_bounds

  @doc """
  Advances a scenario by `dt` seconds.

  Unknown/custom scenarios fall back to `Chronos.World.step/2`, which applies
  each node's velocity linearly.
  """
  @spec step(World.t(), id() | atom(), float()) :: World.t()
  def step(%World{} = world, id, dt) when is_number(dt) and dt >= 0.0 do
    case normalize(id) do
      "orbit" -> step_orbit(world, dt)
      "open_field" -> step_orbit(world, dt)
      _other -> World.step(world, dt)
    end
  end

  defp step_orbit(%World{} = world, dt) do
    time_s = world.time_s + dt
    angle = @orbit_phase + time_s * @orbit_omega

    case World.move_node(world, :rx1, orbit_position(angle), orbit_velocity(angle)) do
      {:ok, moved} -> %{moved | time_s: time_s}
      {:error, :unknown_node} -> World.step(world, dt)
    end
  end

  defp base_world do
    angle = @orbit_phase

    World.new()
    |> World.add_node(%World.Node{
      id: :tx1,
      type: :tx,
      pos: {0.0, 0.0, 0.0},
      vel: {0.0, 0.0, 0.0}
    })
    |> World.add_node(%World.Node{
      id: :rx1,
      type: :rx,
      pos: orbit_position(angle),
      vel: orbit_velocity(angle)
    })
  end

  defp add_orbit_walls(world) do
    world
    |> World.add_wall(%World.Wall{
      id: :wall_x,
      vertices: [
        {-1.2, -2.6, -1.0},
        {-1.2, 2.6, -1.0},
        {-1.2, 2.6, 1.0},
        {-1.2, -2.6, 1.0}
      ],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 4.0
    })
    |> World.add_wall(%World.Wall{
      id: :wall_y,
      vertices: [
        {-2.6, -1.2, -1.0},
        {1.0, -1.2, -1.0},
        {1.0, -1.2, 1.0},
        {-2.6, -1.2, 1.0}
      ],
      normal: {0.0, 1.0, 0.0},
      attenuation_db: 6.0
    })
  end

  defp orbit_position(angle) do
    {cx, cy} = @orbit_center
    {cx + @orbit_rx * :math.cos(angle), cy + @orbit_ry * :math.sin(angle), 0.0}
  end

  defp orbit_velocity(angle) do
    {
      -@orbit_rx * @orbit_omega * :math.sin(angle),
      @orbit_ry * @orbit_omega * :math.cos(angle),
      0.0
    }
  end

  defp normalize(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize(id) when is_binary(id), do: id
  defp normalize(id), do: to_string(id)
end
