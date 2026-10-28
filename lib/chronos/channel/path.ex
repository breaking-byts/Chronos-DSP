defmodule Chronos.Channel.Path do
  @moduledoc """
  A single propagation path between a transmitter and receiver.

  The DSP only consumes `delay_s`, `gain`, and `doppler_hz`. The remaining
  fields describe how the path was built and are used by the dashboard and
  tests:

    * `kind` - which model produced the path (`:los`, `:reflection`,
      `:transmission`, or `:diffraction`);
    * `bounces` - how many reflections the path underwent;
    * `points` - the polyline the signal follows, including the transmitter and
      receiver positions;
    * `interactions` - what happened along the path, one entry per interaction
      (`:reflection`, `:transmission`, or `:diffraction`).
  """

  @enforce_keys [:delay_s, :gain, :doppler_hz]
  defstruct [
    :delay_s,
    :gain,
    :doppler_hz,
    kind: :los,
    bounces: 0,
    points: [],
    interactions: []
  ]

  @type kind :: :los | :reflection | :transmission | :diffraction
  @type vec3 :: {float(), float(), float()}
  @type interaction ::
          {:reflection, term()}
          | {:transmission, term()}
          | {:diffraction, term(), vec3()}

  @type t :: %__MODULE__{
          delay_s: float(),
          gain: float(),
          doppler_hz: float(),
          kind: kind(),
          bounces: non_neg_integer(),
          points: [vec3()],
          interactions: [interaction()]
        }

  @doc """
  Builds a path from keyword attributes.

  Unknown attributes raise, so typos surface at compile time rather than
  silently producing a half-populated path.
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs), do: struct(__MODULE__, attrs)
end
