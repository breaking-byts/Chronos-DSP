defmodule Chronos.Channel.DiffractionTest do
  use ExUnit.Case, async: true

  alias Chronos.Channel.Diffraction
  alias Chronos.Channel.Physics
  alias Chronos.Geometry
  alias Chronos.Material
  alias Chronos.World

  @wall_id :blocking_wall
  @tx_pos {-1.0, 0.0, 0.0}
  @rx_pos {1.0, 0.0, 0.0}

  test "a blocking wall yields one diffracted path around an edge" do
    tx = tx_node()
    rx = rx_node()
    wall = blocking_wall()

    assert [path] = Diffraction.paths(tx, rx, [wall], speed_of_light: 1.0)

    assert path.kind == :diffraction
    assert path.bounces == 0
    assert [_tx_pos, edge_point, _rx_pos] = path.points
    assert [{:diffraction, @wall_id, ^edge_point}] = path.interactions

    straight_length = Physics.path_length([@tx_pos, @rx_pos])
    diffracted_length = Physics.path_length(path.points)
    assert diffracted_length > straight_length
    assert path.delay_s == diffracted_length / 1.0
  end

  test "diffraction loss makes the gain lower than unobstructed free space" do
    [diffracted_path] = Diffraction.paths(tx_node(), rx_node(), [blocking_wall()], [])

    straight_length = Physics.path_length([@tx_pos, @rx_pos])
    unobstructed_gain = Physics.free_space_gain(straight_length)

    assert diffracted_path.gain < unobstructed_gain

    assert diffracted_path.gain <
             Physics.free_space_gain(Physics.path_length(diffracted_path.points))
  end

  test "gain uses the ITU knife-edge and material losses" do
    opts = [carrier_freq_hz: 2.4e9]
    wall = blocking_wall()

    [path] = Diffraction.paths(tx_node(), rx_node(), [wall], opts)
    [_tx_pos, edge_point, _rx_pos] = path.points

    height = 1.5
    distance_to_tx = Geometry.distance(@tx_pos, edge_point)
    distance_to_rx = Geometry.distance(edge_point, @rx_pos)
    wavelength = Physics.wavelength(opts)

    fresnel_parameter =
      height *
        :math.sqrt(2.0 / wavelength * (1.0 / distance_to_tx + 1.0 / distance_to_rx))

    loss_db = knife_edge_loss_db(fresnel_parameter) + Material.diffraction_loss_db(wall)
    expected_gain = Physics.path_gain(Physics.path_length(path.points), loss_db, opts)

    assert_in_delta path.gain, expected_gain, 1.0e-12
  end

  test "no diffraction path is emitted when line of sight is clear" do
    wall = %World.Wall{
      id: :clear_wall,
      vertices: [{0.0, 2.0, -1.0}, {0.0, 3.0, -1.0}, {0.0, 3.0, 1.0}, {0.0, 2.0, 1.0}],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 3.0
    }

    assert Diffraction.paths(tx_node(), rx_node(), [wall], []) == []
  end

  test "diffraction can be disabled" do
    assert Diffraction.paths(tx_node(), rx_node(), [blocking_wall()], diffraction: false) == []
  end

  test "loss grows with carrier frequency for the same geometry" do
    [low_path] =
      Diffraction.paths(tx_node(), rx_node(), [blocking_wall()], carrier_freq_hz: 2.4e9)

    [high_path] =
      Diffraction.paths(tx_node(), rx_node(), [blocking_wall()], carrier_freq_hz: 60.0e9)

    assert high_path.gain < low_path.gain
    assert high_path.points == low_path.points
  end

  test "a diffracted path is rejected when another wall blocks both legs" do
    blocker = %World.Wall{
      id: :leg_blocker,
      vertices: [{-0.5, -2.0, -2.0}, {-0.5, 2.0, -2.0}, {-0.5, 2.0, 2.0}, {-0.5, -2.0, 2.0}],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 3.0
    }

    assert Diffraction.paths(tx_node(), rx_node(), [blocking_wall(), blocker], []) == []
  end

  test "repeated calls return identical paths" do
    walls = [blocking_wall()]

    first = Diffraction.paths(tx_node(), rx_node(), walls, carrier_freq_hz: 2.4e9)
    second = Diffraction.paths(tx_node(), rx_node(), walls, carrier_freq_hz: 2.4e9)

    assert first == second
  end

  test "degenerate inputs return no paths without raising" do
    assert Diffraction.paths(tx_node(), rx_node(), [], []) == []

    same_position_tx = %World.Node{
      id: :tx,
      type: :tx,
      pos: @tx_pos,
      vel: {0.0, 0.0, 0.0}
    }

    assert Diffraction.paths(same_position_tx, same_position_tx, [blocking_wall()], []) == []
  end

  test "a wall with fewer than three vertices is skipped" do
    wall = %World.Wall{
      id: :degenerate,
      vertices: [{0.0, -1.0, 0.0}, {0.0, 1.0, 0.0}],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 3.0
    }

    assert Diffraction.paths(tx_node(), rx_node(), [wall], []) == []
  end

  test "max_paths is a hard cap" do
    assert Diffraction.paths(tx_node(), rx_node(), [blocking_wall()], max_paths: 0) == []
  end

  defp tx_node do
    %World.Node{id: :tx, type: :tx, pos: @tx_pos, vel: {0.0, 0.0, 0.0}}
  end

  defp rx_node do
    %World.Node{id: :rx, type: :rx, pos: @rx_pos, vel: {0.0, 0.0, 0.0}}
  end

  defp blocking_wall do
    %World.Wall{
      id: @wall_id,
      vertices: [
        {0.0, -1.5, -1.5},
        {0.0, 1.5, -1.5},
        {0.0, 1.5, 1.5},
        {0.0, -1.5, 1.5}
      ],
      normal: {1.0, 0.0, 0.0},
      attenuation_db: 3.0
    }
  end

  test "knife edge loss is negligible deep in the shadow region" do
    # ITU-R P.526: below v = -0.78 the obstruction is deep in the shadow
    # region and the diffraction loss is negligible.
    assert Diffraction.knife_edge_loss_db(-1.0) == 0.0
    assert Diffraction.knife_edge_loss_db(-5.0) == 0.0
  end

  test "knife edge loss matches the ITU-R P.526 reference values" do
    # Canonical single knife-edge values: ~6 dB at v = 0, ~14 dB at v = 1 and
    # ~19 dB at v = 2.
    assert_in_diffraction_loss(Diffraction.knife_edge_loss_db(0.0), 6.03, 0.05)
    assert_in_diffraction_loss(Diffraction.knife_edge_loss_db(1.0), 13.93, 0.05)
    assert_in_diffraction_loss(Diffraction.knife_edge_loss_db(2.0), 19.04, 0.05)
  end

  defp assert_in_diffraction_loss(actual, expected, tolerance) do
    assert abs(actual - expected) <= tolerance
  end

  defp knife_edge_loss_db(fresnel_parameter),
    do: Diffraction.knife_edge_loss_db(fresnel_parameter)
end
