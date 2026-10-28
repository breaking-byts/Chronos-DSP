defmodule Chronos.Channel do
  @moduledoc """
  Deterministic geometric channel model.

  Each transmitter/receiver pair gets the paths that the scene geometry
  supports:

    * a line-of-sight path when the segment is not blocked;
    * reflection paths off wall polygons, of first order and higher, found with
      the image-source method (`Chronos.Channel.MultiBounce`);
    * a diffracted path around the edge of a blocking wall
      (`Chronos.Channel.Diffraction`);
    * a transmission path through a blocking wall
      (`Chronos.Channel.Transmission`).

  The models are intentionally simple: free-space amplitude decays with
  `1 / distance`, wall hits apply their material attenuation, and Doppler is
  derived from the relative velocity projected onto the path. They share the
  conventions in `Chronos.Channel.Physics`, so every path answers the same
  questions the same way.

  ## Options

    * `:max_bounces` - highest reflection order to compute (default `2`)
    * `:max_paths` - hard cap on the paths returned per receiver (default `32`)
    * `:diffraction` - set to `false` to skip diffracted paths (default `true`)
    * `:transmission` - set to `false` to skip penetrating paths (default `true`)
  """

  alias Chronos.Channel.Diffraction
  alias Chronos.Channel.MultiBounce
  alias Chronos.Channel.Path
  alias Chronos.Channel.Physics
  alias Chronos.Channel.Transmission
  alias Chronos.Geometry
  alias Chronos.World

  @default_max_bounces 2
  @default_max_paths 32

  @doc """
  Returns every path from all transmitters to `rx_id`.

  Returns `{:error, :unknown_rx}` when the receiver id does not exist.
  """
  @spec paths_for_rx(World.t(), term(), keyword()) ::
          {:ok, list(Path.t())} | {:error, :unknown_rx}
  def paths_for_rx(%World{} = world, rx_id, opts \\ []) do
    case World.node(world, rx_id) do
      %World.Node{type: :rx} = rx ->
        txs =
          world
          |> World.nodes_by_type(:tx)
          |> Enum.sort_by(&to_string(&1.id))

        walls =
          world.walls
          |> Map.values()
          |> Enum.sort_by(&to_string(&1.id))

        paths =
          Enum.flat_map(txs, fn tx ->
            los = los_path(tx, rx, walls, opts)
            reflections = MultiBounce.paths(tx, rx, walls, bounce_opts(opts))
            diffraction = Diffraction.paths(tx, rx, walls, opts)
            transmission = Transmission.paths(tx, rx, walls, opts)

            [
              los
              | sort_by_strength(reflections ++ diffraction ++ transmission)
            ]
            |> Enum.reject(&is_nil/1)
          end)

        {:ok, Enum.take(paths, max_paths(opts))}

      %World.Node{} ->
        {:error, :unknown_rx}

      nil ->
        {:error, :unknown_rx}
    end
  end

  @doc "Like `paths_for_rx/3` but raises for an unknown receiver."
  @spec paths_for_rx!(World.t(), term(), keyword()) :: list(Path.t())
  def paths_for_rx!(%World{} = world, rx_id, opts \\ []) do
    case paths_for_rx(world, rx_id, opts) do
      {:ok, paths} ->
        paths

      {:error, :unknown_rx} ->
        raise ArgumentError, "unknown rx node: #{inspect(rx_id)}"
    end
  end

  @doc "Builds a line-of-sight path, or returns `nil` when a wall blocks it."
  @spec los_path(World.Node.t(), World.Node.t(), list(World.Wall.t()), keyword()) ::
          Path.t() | nil
  def los_path(
        %World.Node{pos: tx_pos, vel: tx_vel},
        %World.Node{pos: rx_pos, vel: rx_vel},
        walls,
        opts
      ) do
    if segment_occluded?(tx_pos, rx_pos, walls, nil) do
      nil
    else
      distance = Geometry.distance(tx_pos, rx_pos)
      delay_s = distance / Physics.speed_of_light(opts)
      gain = Physics.path_gain(distance, 0.0, opts)
      doppler_hz = Physics.doppler_hz([tx_pos, rx_pos], tx_vel, rx_vel, Physics.wavelength(opts))

      %Path{
        delay_s: delay_s,
        gain: gain,
        doppler_hz: doppler_hz,
        kind: :los,
        bounces: 0,
        points: [tx_pos, rx_pos],
        interactions: []
      }
    end
  end

  @doc """
  Builds first-order reflection paths for each wall.

  The transmitter is mirrored across the wall plane. If the mirrored segment
  crosses the wall polygon and neither leg is occluded by another wall, the hit
  point defines a valid reflection path. Higher-order reflections are built by
  `Chronos.Channel.MultiBounce`.
  """
  @spec reflection_paths(World.Node.t(), World.Node.t(), list(World.Wall.t()), keyword()) ::
          list(Path.t())
  def reflection_paths(tx, rx, walls, opts) do
    MultiBounce.paths(tx, rx, walls, Keyword.put(opts, :max_bounces, 1))
  end

  @doc """
  Returns true when the segment `a`-`b` intersects any wall polygon.

  Pass a wall id as `ignore_wall_id` to skip the wall that produced the
  reflection being validated.
  """
  @spec segment_occluded?(
          Geometry.vec3(),
          Geometry.vec3(),
          list(World.Wall.t()),
          term() | nil
        ) :: boolean()
  def segment_occluded?(a, b, walls, ignore_wall_id \\ nil) do
    World.segment_occluded_by?(a, b, walls, List.wrap(ignore_wall_id))
  end

  @doc "Doppler shift for a direct path, in hertz."
  @spec doppler(Geometry.vec3(), Geometry.vec3(), Geometry.vec3(), Geometry.vec3(), keyword()) ::
          float()
  def doppler(tx_pos, tx_vel, rx_pos, rx_vel, opts) do
    Physics.doppler_hz([tx_pos, rx_pos], tx_vel, rx_vel, Physics.wavelength(opts))
  end

  @doc "Free-space amplitude, normalized so a one-metre path has unit gain."
  @spec free_space_gain(float()) :: float()
  defdelegate free_space_gain(distance), to: Physics

  @doc "Converts a decibel ratio to linear amplitude."
  @spec db_to_linear(float()) :: float()
  defdelegate db_to_linear(db), to: Physics

  defp max_paths(opts), do: Keyword.get(opts, :max_paths, @default_max_paths)

  defp bounce_opts(opts), do: Keyword.put_new(opts, :max_bounces, @default_max_bounces)

  # Strongest paths first, ties broken by construction order, so the path cap
  # keeps the paths that contribute the most energy.
  defp sort_by_strength(paths) do
    paths
    |> Enum.with_index()
    |> Enum.sort_by(fn {path, index} -> {-path.gain, index} end)
    |> Enum.map(fn {path, _index} -> path end)
  end
end
