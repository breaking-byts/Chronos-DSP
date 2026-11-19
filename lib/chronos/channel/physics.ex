defmodule Chronos.Channel.Physics do
  @moduledoc """
  Shared propagation math used by every geometric path model.

  The helpers here are deliberately small and deterministic. They own the
  conventions that the LOS, reflection, transmission, diffraction, and
  multi-bounce models must agree on:

    * free-space amplitude decays as `1 / distance`, normalized at one metre;
    * material losses are decibels and are converted with `db_to_linear/1`;
    * transmit power (`:tx_power`, integer dBm) scales every path gain as a
      relative dB offset from the default, which calibrates the one-metre
      unit-gain normalization;
    * Doppler uses the first and last leg of a path, projected onto the
      transmitter and receiver velocities respectively.

  Keeping the conventions in one module means each path model only has to
  describe *where* the path goes and *what* it loses.
  """

  alias Chronos.Geometry

  @default_speed_of_light 299_792_458.0
  @default_carrier_freq_hz 2.4e9
  @default_tx_power_dbm 10
  @min_tx_power_dbm 0
  @max_tx_power_dbm 30

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
  @spec db_to_linear(number()) :: float()
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

  The transmit-power factor and the global gain option are applied last so
  callers can attenuate or boost a whole scene without touching individual
  path models.
  """
  @spec path_gain(float(), float(), opts()) :: float()
  def path_gain(length, loss_db, opts) do
    free_space_gain(length) * db_to_linear(-loss_db) * tx_gain(opts) * global_gain(opts)
  end

  @doc "Global gain multiplier applied to every path (default `1.0`)."
  @spec global_gain(opts()) :: float()
  def global_gain(opts), do: Keyword.get(opts, :global_gain, 1.0)

  @doc """
  Transmit power in dBm (default `10`, range `0..30`).

  The transmit-power term of the link budget. The model's free-space
  normalization (unit gain at one metre) is calibrated to this default, so
  `tx_gain/1` applies the relative offset `tx_power - 10` dB and the default
  leaves every path gain unchanged.
  """
  @spec tx_power_dbm(opts()) :: integer()
  def tx_power_dbm(opts), do: Keyword.get(opts, :tx_power, @default_tx_power_dbm)

  @doc """
  Linear amplitude factor for `:tx_power` relative to the default transmit
  power: `10 ** ((tx_power - 10) / 20)`. Exactly `1.0` at the default, so
  existing renders are unchanged; received power scales with its square.
  """
  @spec tx_gain(opts()) :: float()
  def tx_gain(opts), do: db_to_linear(tx_power_dbm(opts) - @default_tx_power_dbm)

  @doc "Returns true when `number` is a finite float (not NaN or infinity)."
  @spec finite?(number()) :: boolean()
  def finite?(number) when is_number(number) do
    number == number and abs(number) < 1.0e308
  end

  def finite?(_number), do: false

  @doc "Returns true when `number` is a finite, strictly positive float."
  @spec finite_positive?(number()) :: boolean()
  def finite_positive?(number), do: finite?(number) and number > 0.0

  @doc """
  Validates the shared propagation options, raising `ArgumentError` on the
  first invalid value. Every public path model calls this so invalid options
  fail loudly and uniformly instead of raising arithmetic errors deep in the
  math or silently returning no paths.

  Checked: `:speed_of_light` (1.0..1.0e12 m/s) and `:carrier_freq_hz`
  (1.0..1.0e15 Hz), with a finite positive wavelength; `:global_gain` (finite,
  magnitude <= 1.0e100); `:tx_power` (integer, 0..30 dBm when present);
  `:max_paths`, `:max_bounces`, and `:max_candidates` (positive integers when
  present); and `:extra_transmission_loss_db` (finite, 0..1.0e6 dB when
  present). The magnitude bounds keep downstream float arithmetic from
  overflowing into arithmetic errors on this OTP, which raises on overflow
  instead of producing infinity.
  """
  @spec validate_opts!(opts()) :: opts()
  def validate_opts!(opts) do
    c = speed_of_light(opts)
    f = carrier_freq_hz(opts)

    unless finite_positive?(c) and c >= 1.0 and c <= 1.0e12 do
      raise ArgumentError, ":speed_of_light must be in 1.0..1.0e12 m/s, got: #{inspect(c)}"
    end

    unless finite_positive?(f) and f >= 1.0 and f <= 1.0e15 do
      raise ArgumentError, ":carrier_freq_hz must be in 1.0..1.0e15 Hz, got: #{inspect(f)}"
    end

    # The division itself can overflow to an arithmetic error on extreme but
    # finite inputs; treat that as an invalid wavelength, not a crash.
    wavelength =
      try do
        c / f
      rescue
        ArithmeticError -> :overflow
      end

    unless finite_positive?(wavelength) do
      raise ArgumentError,
            ":speed_of_light / :carrier_freq_hz must yield a finite positive wavelength, got: #{inspect(wavelength)}"
    end

    gain = global_gain(opts)

    unless finite?(gain) and abs(gain) <= 1.0e100 do
      raise ArgumentError,
            ":global_gain must be finite with magnitude <= 1.0e100, got: #{inspect(gain)}"
    end

    case Keyword.fetch(opts, :tx_power) do
      {:ok, value} ->
        unless is_integer(value) and value >= @min_tx_power_dbm and value <= @max_tx_power_dbm do
          raise ArgumentError,
                ":tx_power must be an integer in #{@min_tx_power_dbm}..#{@max_tx_power_dbm} dBm, got: #{inspect(value)}"
        end

      :error ->
        :ok
    end

    for key <- [:max_paths, :max_bounces, :max_candidates] do
      case Keyword.fetch(opts, key) do
        {:ok, value} when is_integer(value) and value > 0 ->
          :ok

        {:ok, value} ->
          raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"

        :error ->
          :ok
      end
    end

    case Keyword.fetch(opts, :extra_transmission_loss_db) do
      {:ok, value} ->
        unless finite?(value) and value >= 0.0 and value <= 1.0e6 do
          raise ArgumentError,
                ":extra_transmission_loss_db must be finite and in 0..1.0e6 dB, got: #{inspect(value)}"
        end

      :error ->
        :ok
    end

    opts
  end

  defp last_leg_direction([first, second]), do: Geometry.normalize(Geometry.sub(second, first))

  defp last_leg_direction(points) do
    [penultimate, last] = Enum.take(points, -2)
    Geometry.normalize(Geometry.sub(last, penultimate))
  end
end
