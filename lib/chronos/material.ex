defmodule Chronos.Material do
  @moduledoc """
  Illustrative material catalogue for the geometric channel.

  Each coefficient is a loss magnitude in decibels. A positive value means
  attenuation and is applied as a linear amplitude factor of
  `10 ** (-loss_db / 20)`, consistent with
  `Chronos.Channel.Physics.db_to_linear/1`.

  The values below are intentionally simple and illustrative; they are not
  calibrated measurements. They let the simulator demonstrate how material
  choice changes reflection, transmission, and diffraction without presenting
  the catalogue as a measurement-grade database.

  A wall's material supplies all three losses. An explicit numeric
  `wall.attenuation_db` overrides only the reflection loss; transmission and
  diffraction always come from the material.
  """

  @default_id :concrete

  @enforce_keys [:id, :name, :reflection_loss_db, :transmission_loss_db, :diffraction_loss_db]
  defstruct [
    :id,
    :name,
    :reflection_loss_db,
    :transmission_loss_db,
    :diffraction_loss_db
  ]

  @type id :: atom() | String.t()

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          reflection_loss_db: float(),
          transmission_loss_db: float(),
          diffraction_loss_db: float()
        }

  # {id, display name, reflection loss dB, transmission loss dB, diffraction loss dB}
  @catalogue [
    {:brick, "Brick", 4.0, 10.0, 4.0},
    {:concrete, "Concrete", 6.0, 18.0, 6.0},
    {:drywall, "Drywall", 2.0, 4.0, 2.0},
    {:glass, "Glass", 1.0, 3.0, 1.0},
    {:metal, "Metal", 0.5, 40.0, 2.0},
    {:plaster, "Plaster", 3.0, 8.0, 3.0},
    {:plywood, "Plywood", 3.5, 7.0, 3.5},
    {:reinforced_concrete, "Reinforced Concrete", 8.0, 24.0, 8.0},
    {:soil, "Soil", 5.0, 12.0, 5.0},
    {:water, "Water", 2.0, 20.0, 2.0},
    {:wood, "Wood", 3.0, 6.0, 3.0}
  ]

  @doc "Returns the material catalogue, sorted by id."
  @spec list() :: [t()]
  def list do
    @catalogue
    |> Enum.map(&to_struct/1)
    |> Enum.sort_by(&Atom.to_string(&1.id))
  end

  @doc "Returns all material ids, sorted by id."
  @spec ids() :: [id()]
  def ids, do: Enum.map(list(), & &1.id)

  @doc "Returns a material by atom or string id; unknown ids fall back to concrete."
  @spec get(id() | nil) :: t()
  def get(id), do: fetch(id) || default()

  @doc """
  Returns a material by atom or string id.

  Raises `ArgumentError` when the id is not present in the catalogue.
  """
  @spec get!(id()) :: t()
  def get!(id) do
    case fetch(id) do
      nil -> raise ArgumentError, "unknown material id: #{inspect(id)}"
      material -> material
    end
  end

  @doc "Returns the default material (concrete)."
  @spec default() :: t()
  def default, do: get!(@default_id)

  @doc """
  Returns the material for a wall.

  A known `material` id is used directly. Missing or unknown ids fall back to
  the default material and never raise.
  """
  @spec for_wall(map()) :: t()
  def for_wall(%{material: id}), do: fetch(id) || default()
  def for_wall(_wall), do: default()

  @doc "Returns the reflection loss for a wall, preferring an explicit `attenuation_db`."
  @spec reflection_loss_db(map()) :: float()
  def reflection_loss_db(%{attenuation_db: db}) when is_number(db), do: db
  def reflection_loss_db(wall), do: for_wall(wall).reflection_loss_db

  @doc "Returns the transmission loss for a wall's material."
  @spec transmission_loss_db(map()) :: float()
  def transmission_loss_db(wall), do: for_wall(wall).transmission_loss_db

  @doc "Returns the diffraction loss for a wall's material."
  @spec diffraction_loss_db(map()) :: float()
  def diffraction_loss_db(wall), do: for_wall(wall).diffraction_loss_db

  @doc "Returns a JSON-friendly material map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = material) do
    %{
      id: Atom.to_string(material.id),
      name: material.name,
      reflection_loss_db: material.reflection_loss_db,
      transmission_loss_db: material.transmission_loss_db,
      diffraction_loss_db: material.diffraction_loss_db
    }
  end

  defp fetch(id) when is_atom(id) do
    @catalogue
    |> Enum.find(&(elem(&1, 0) == id))
    |> material_struct()
  end

  defp fetch(id) when is_binary(id) do
    @catalogue
    |> Enum.find(&(Atom.to_string(elem(&1, 0)) == id))
    |> material_struct()
  end

  defp fetch(_id), do: nil

  defp material_struct(nil), do: nil
  defp material_struct(entry), do: to_struct(entry)

  defp to_struct({id, name, reflection, transmission, diffraction}) do
    %__MODULE__{
      id: id,
      name: name,
      reflection_loss_db: reflection,
      transmission_loss_db: transmission,
      diffraction_loss_db: diffraction
    }
  end
end
