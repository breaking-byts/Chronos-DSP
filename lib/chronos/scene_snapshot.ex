defmodule Chronos.SceneSnapshot do
  @moduledoc """
  Normalized geometry snapshot of a world for dirty-state comparison (#36).

  The dirty indicator compares the live world against the last saved/loaded
  snapshot. Raw struct equality is wrong for that: `time_s` advances every
  tick and node velocities are simulation state, not edits. This snapshot
  keeps only the scene-serializable geometry — node ids/types/positions and
  wall ids/vertices/normals/material/attenuation — with ids normalized to
  strings, numbers to floats, and entries sorted by id, so an atom-id world
  (built-in scenario) and a string-id world (loaded scene) compare equal.

  `ChronosWeb.SimLive` recomputes the comparison on edits (drag commits,
  panel changes) and on save/load/reset/scenario switches — NOT on every
  tick, so simulation motion alone never lights the dirty dot.
  """

  alias Chronos.World

  @type t :: %{nodes: [map()], walls: [map()]}

  @doc """
  Builds the normalized geometry snapshot of `world` (no `time_s`, no
  velocities). Two worlds with the same geometry produce equal snapshots
  regardless of id representation (atom vs string) or number type.
  """
  @spec from_world(World.t()) :: t()
  def from_world(%World{nodes: nodes, walls: walls}) do
    %{
      nodes: nodes |> Map.values() |> Enum.map(&node_snapshot/1) |> Enum.sort_by(& &1.id),
      walls: walls |> Map.values() |> Enum.map(&wall_snapshot/1) |> Enum.sort_by(& &1.id)
    }
  end

  defp node_snapshot(%World.Node{id: id, type: type, pos: pos}) do
    %{id: to_string(id), type: type, pos: vec(pos)}
  end

  defp wall_snapshot(%World.Wall{} = wall) do
    %{
      id: to_string(wall.id),
      vertices: Enum.map(wall.vertices, &vec/1),
      normal: vec(wall.normal),
      material: to_string(wall.material),
      attenuation_db: number(wall.attenuation_db)
    }
  end

  defp vec({x, y, z}), do: [x * 1.0, y * 1.0, z * 1.0]

  defp number(nil), do: nil
  defp number(value) when is_number(value), do: value * 1.0
end
