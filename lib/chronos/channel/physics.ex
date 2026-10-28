defmodule Chronos.Channel.Physics do
  @moduledoc """
  Shared propagation math used by every geometric path model.

  The helpers here are deliberately small and deterministic. They own the
  conventions that the LOS, reflection, transmission, diffraction, and
  multi-bounce models must agree on:

    * free-space amplitude decays as `1 / distance`, normalized at one metre;
    * material losses are decibels and are converted with `db_to_linear/1`;
    * Doppler uses the first and last leg of a path, projected onto the
      transmitter and receiver velocities respectively.

  Keeping the conventions in one module means each path model only has to
  describe *where* the path goes and *what* it loses.
  """

  alias Chronos.Geometry

  @default_speed_of_light 299_792_458.0
  @default_carrier_freq_hz 2.4e9

  @type vec3 :: Geometry.vec3()
  @type opts :: keyword()

  @doc "Speed of light in metres per second (default `299_792_458.0`)."
  @spec speed_of_light(opts()) :: float()
  def speed_of_light(opts), do: Keyword.get(opts, :speed_of_light, @default_speed_of_light)

  @doc "Carrier frequency in hertz (default `2.4e9`)."
  @spec carrier_freq_hz(opts()) :: float()
  def carrier_freq_hz(opts), do: Keyword.get(opts, :carrier_freq_hz, @default_carrier_freq_hz)

  @doc "Carrier wavelength in metres."
  @spec wavelength(opts()) :: float()
  def wavelength(opts), do: speed_of_light(opts) / carrier_freq_hz(opts)

  @doc "Converts a decibel ratio to a linear amplitude ratio."
  @spec db_to_linear(float()) :: float()
  def db_to_linear(db), do: :math.pow(10.0, db / 20.0)

  @doc "Free-space amplitude, normalized so a one-metre path has unit gain."
  @spec free_space_gain(float()) :: float()
  def free_space_gain(distance) when distance > 0.0, do: 1.0 / distance
  def free_space_gain(_distance), do: 1.0

  @doc "Total geometric length of a polyline path."
  @spec path_length([vec3()]) :: float()
  def path_length([]), do: 0.0

  def path_length([first | rest]) do
    rest
    |> Enum.reduce({first, 0.0}, fn point, {prev, acc} ->
      {point, acc + Geometry.distance(prev, point)}
    end)
    |> elem(1)
  end

  @doc """
  Doppler shift for a path described by its polyline points.

  The transmitter velocity is projected onto the first leg and the receiver
  velocity onto the last leg, so a straight path reduces to
  `dot(relative_velocity, direction) / wavelength`.
  """
  @spec doppler_hz([vec3()], vec3(), vec3(), float()) :: float()
  def doppler_hz(points, tx_vel, rx_vel, wavelength) when is_list(points) do
    case points do
      [first, second | _] ->
        last_leg = last_leg_direction(points)

        with {:ok, first_dir} <- Geometry.normalize(Geometry.sub(second, first)),
             {:ok, last_dir} <- last_leg do
          rate = Geometry.dot(rx_vel, last_dir) - Geometry.dot(tx_vel, first_dir)
          rate / wavelength
        else
          _ -> 0.0
        end

      _ ->
        0.0
    end
  end

  @doc """
  Linear gain for a path with a total geometric length and a total loss in dB.

  The global gain option is applied last so callers can attenuate or boost a
  whole scene without touching individual path models.
  """
  @spec path_gain(float(), float(), opts()) :: float()
  def path_gain(length, loss_db, opts) do
    free_space_gain(length) * db_to_linear(-loss_db) * global_gain(opts)
  end

  @doc "Global gain multiplier applied to every path (default `1.0`)."
  @spec global_gain(opts()) :: float()
  def global_gain(opts), do: Keyword.get(opts, :global_gain, 1.0)

  defp last_leg_direction([first, second]), do: Geometry.normalize(Geometry.sub(second, first))

  defp last_leg_direction(points) do
    [penultimate, last] = Enum.take(points, -2)
    Geometry.normalize(Geometry.sub(last, penultimate))
  end
end
