defmodule Chronos.Scene do
  @type vec3 :: {float(), float(), float()}

  def project({x, y, _z}, %{min: {min_x, min_y}, max: {max_x, max_y}}, %{width: w, height: h}) do
    if max_x == min_x or max_y == min_y do
      raise ArgumentError,
            "bounds must have non-zero span for x/y: min={#{min_x}, #{min_y}} max={#{max_x}, #{max_y}}"
    end

    nx = (x - min_x) / (max_x - min_x)
    ny = (y - min_y) / (max_y - min_y)
    {nx * w, (1.0 - ny) * h}
  end
end
