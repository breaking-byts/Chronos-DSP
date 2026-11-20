defmodule ChronosWeb.ApiParamsTest do
  @moduledoc """
  Shared validation rules for the editing panel (#35): attenuation override
  0..40 dB, z height -5..+5 m, and material ids restricted to the catalogue.
  """
  use ExUnit.Case, async: true

  alias Chronos.Material
  alias ChronosWeb.ApiParams

  describe "attenuation override" do
    test "range is 0..40 dB" do
      assert ApiParams.attenuation_range() == {0.0, 40.0}
    end

    test "accepts finite numbers in range, including the boundaries" do
      for value <- [0, 0.0, 40, 40.0, 12.5, 6] do
        assert {:ok, ^value} = ApiParams.validate_attenuation(value)
      end
    end

    test "rejects out-of-range, negative, non-finite-scale, and non-number values" do
      for value <- [-0.1, -1, 40.1, 1000, 1.0e308, "12", nil, :foo, true] do
        assert {:error, message} = ApiParams.validate_attenuation(value)
        assert message =~ "attenuation"
      end
    end
  end

  describe "z height" do
    test "range is -5..+5 m" do
      assert ApiParams.z_range() == {-5.0, 5.0}
    end

    test "accepts finite numbers in range, including the boundaries" do
      for value <- [-5, -5.0, 5, 5.0, 0, 2.5, -1.25] do
        assert {:ok, ^value} = ApiParams.validate_z(value)
      end
    end

    test "rejects out-of-range and non-number values" do
      for value <- [-5.01, 5.01, 100, -100, 1.0e308, "1", nil, :foo] do
        assert {:error, message} = ApiParams.validate_z(value)
        assert message =~ "z must"
      end
    end
  end

  describe "material id" do
    test "accepts every catalogue id as string or atom and returns the atom" do
      for id <- Material.ids() do
        assert {:ok, ^id} = ApiParams.validate_material(id)
        assert {:ok, ^id} = ApiParams.validate_material(Atom.to_string(id))
      end

      assert length(Material.ids()) == 11
    end

    test "rejects unknown ids instead of defaulting to concrete" do
      for value <- ["unobtainium", "", "Concrete", nil, 123, :vibranium] do
        assert {:error, message} = ApiParams.validate_material(value)
        assert message =~ "catalogue"
      end
    end
  end
end
