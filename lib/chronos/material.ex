defmodule Chronos.Material do
  @moduledoc """
  Small, illustrative material catalogue for the geometric channel.

  Coefficients are amplitude losses in decibels, not calibrated link-budget
  values. They are intentionally simple and deterministic so the demo can show
  how material choice changes reflection, transmission, and diffraction without
  pretending to be a measurement-grade material database.

  A wall may override the catalogue's reflection loss with `attenuation_db`;
  transmission and diffraction losses always come from the wall's material.
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
    {:wood, "Wood", 3.0, 6.0, 3.0}
  ]

  @doc "Returns the material catalogue, sorted by id."
  @spec list() :: [t()]
  def list do
    @catalogue
    |> Enum.map(&to_struct/1)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Returns a material by atom or string id; unknown ids fall back to concrete."
  @spec get(atom() | String.t() | nil) :: t()
  def get(id) when is_atom(id), do: Enum.find(list(), &(&1.id == id)) || default()

  def get(id) when is_binary(id) do
    Enum.find(list(), &(Atom.to_string(&1.id) == id)) || default()
  end

  def get(_id), do: default()

  @doc "Returns the default material (concrete)."
  @spec default() :: t()
  def default do
    id = @default_id

    {id, name, reflection, transmission, diffraction} =
      Enum.find(@catalogue, fn entry -> elem(entry, 0) == id end) ||
        {id, "Concrete", 6.0, 18.0, 6.0}

    to_struct({id, name, reflection, transmission, diffraction})
  end

  @doc "Returns the reflection loss for a wall, preferring an explicit `attenuation_db`."
  @spec reflection_loss_db(map()) :: float()
  def reflection_loss_db(%{attenuation_db: db}) when is_number(db), do: db
  def reflection_loss_db(%{material: material}), do: get(material).reflection_loss_db
  def reflection_loss_db(_wall), do: default().reflection_loss_db

  @doc "Returns the transmission loss for a wall's material."
  @spec transmission_loss_db(map()) :: float()
  def transmission_loss_db(%{material: material}), do: get(material).transmission_loss_db
  def transmission_loss_db(_wall), do: default().transmission_loss_db

  @doc "Returns the diffraction loss for a wall's material."
  @spec diffraction_loss_db(map()) :: float()
  def diffraction_loss_db(%{material: material}), do: get(material).diffraction_loss_db
  def diffraction_loss_db(_wall), do: default().diffraction_loss_db

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
