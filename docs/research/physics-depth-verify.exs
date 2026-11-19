# Physics-depth verification suite — research ticket #24 (docs/research/physics-depth.md).
#
# Pure Elixir, no deps. Run: elixir docs/research/physics-depth-verify.exs
# Every number quoted in the findings doc is produced here. The algorithms
# (Boersma Fresnel evaluation, knife-edge J(v), P.526 §6 UTD screen) are the
# same ones proposed for the Rust NIF + pure-Elixir reference mirror.
#
# Primary sources implemented:
#   ITU-R P.526-16 (11/2025): Eqs (8)-(10) Boersma, (26)-(31) knife-edge,
#     (71)-(72) finite-width screen, (90)-(106) UTD finitely conducting wedge.
#   ITU-R P.525-5 (11/2024): Eqs (5)-(6) free-space basic transmission loss.
#   ITU-R M.1225 (1997): Annex 2 Tables 2-5 tap profiles.
#   3GPP TR 38.901 v16.1.0: Tables 7.7.2-1/-3, Eq (7.7-1) delay scaling.
#   Goldsmith, Wireless Communications (author draft, Feb 2020): two-ray
#     Eqs (2.13)-(2.22), coherence bandwidth §3.3.

defmodule Cx do
  @moduledoc "Minimal complex arithmetic ({re, im} tuples) — mirrorable in Rust."
  def add({a, b}, {c, d}), do: {a + c, b + d}
  def mul({a, b}, {c, d}), do: {a * c - b * d, a * d + b * c}
  def scale({a, b}, s), do: {a * s, b * s}
  def expj(t), do: {:math.cos(t), :math.sin(t)}
  def mag({a, b}), do: :math.sqrt(a * a + b * b)
end

defmodule Fresnel do
  @moduledoc "Fresnel integrals C(v), S(v) and knife-edge loss J(v)."
  @pi :math.pi()

  @doc "Reference values: composite Simpson on [0, v] (not for production)."
  def cs_simpson(v) do
    n = max(2000, trunc(40.0 * v * v))
    n = if rem(n, 2) == 1, do: n + 1, else: n
    h = v / n

    f = fn t ->
      a = @pi * t * t / 2.0
      {:math.cos(a), :math.sin(a)}
    end

    {c0, s0} = f.(0.0)
    {cn, sn} = f.(v)

    {sc, ss} =
      Enum.reduce(1..(n - 1), {0.0, 0.0}, fn i, {ac, as} ->
        {cc, ss} = f.(i * h)
        w = if rem(i, 2) == 1, do: 4.0, else: 2.0
        {ac + w * cc, as + w * ss}
      end)

    {(c0 + cn + sc) * h / 3.0, (s0 + sn + ss) * h / 3.0}
  end

  # Boersma coefficients exactly as printed in ITU-R P.526-16 §2.7.
  @a [1.595769140, -0.000001702, -6.808568854, -0.000576361, 6.920691902,
      -0.016898657, -3.050485660, -0.075752419, 0.850663781, -0.025639041,
      -0.150230960, 0.034404779]
  @b [-0.000000033, 4.255387524, -0.000092810, -7.780020400, -0.009520895,
      5.075161298, -0.138341947, -1.363729124, -0.403349276, 0.702222016,
      -0.216195929, 0.019547031]
  @c [0.000000000, -0.024933975, 0.000003936, 0.005770956, 0.000689892,
      -0.009497136, 0.011948809, -0.006748873, 0.000246420, 0.002102967,
      -0.001217930, 0.000233939]
  @d [0.199471140, 0.000000023, -0.009351341, 0.000023006, 0.004851466,
      0.001903218, -0.017122914, 0.029064067, -0.027928955, 0.016497308,
      -0.005598515, 0.000838386]

  defp horner(coefs, x) do
    Enum.reduce(Enum.reverse(coefs), {0.0, 0.0}, fn {ar, ai}, {accr, acci} ->
      {accr * x + ar, acci * x + ai}
    end)
  end

  @doc """
  P.526-16 Eqs (8a)/(8b)/(9): Fc(v) = C(v) + jS(v), x = pi v^2 / 2.
  (8a) Fc = exp(jx) sqrt(x/4) sum (a_n - j b_n)(x/4)^n, 0 <= x < 4
  (8b) Fc = (1+j)/2 + exp(jx) sqrt(4/x) sum (c_n - j d_n)(4/x)^n, x >= 4
  Negative v via Eqs (10a)/(10b): C(-v) = -C(v), S(-v) = -S(v).
  """
  def cs_boersma(v) when v < 0 do
    {c, s} = cs_boersma(-v)
    {-c, -s}
  end

  def cs_boersma(v) do
    x = @pi * v * v / 2.0

    if x < 4.0 do
      coefs = Enum.zip(@a, @b) |> Enum.map(fn {ar, br} -> {ar, -br} end)
      sum = horner(coefs, x / 4.0)
      Cx.mul(Cx.expj(x), Cx.scale(sum, :math.sqrt(x / 4.0)))
    else
      coefs = Enum.zip(@c, @d) |> Enum.map(fn {cr, dr} -> {cr, -dr} end)
      sum = horner(coefs, 4.0 / x)
      Cx.add({0.5, 0.5}, Cx.mul(Cx.expj(x), Cx.scale(sum, :math.sqrt(4.0 / x))))
    end
  end

  @doc "Exact knife-edge loss, P.526-16 Eq (30)."
  def j_exact(v, method \\ :boersma) do
    {c, s} =
      case method do
        :simpson ->
          {c, s} = cs_simpson(abs(v))
          if v < 0, do: {-c, -s}, else: {c, s}

        :boersma ->
          cs_boersma(v)
      end

    mag = :math.sqrt(:math.pow(1.0 - c - s, 2) + :math.pow(c - s, 2)) / 2.0
    -20.0 * :math.log10(mag)
  end

  @doc "P.526-16 Eq (31) approximation (v > -0.78); zero below, as in §4.5.1."
  def j_approx(v) when v < -0.78, do: 0.0

  def j_approx(v) do
    6.9 + 20.0 * :math.log10(:math.sqrt(:math.pow(v - 0.1, 2) + 1.0) + v - 0.1)
  end
end

defmodule UTD do
  @moduledoc "P.526-16 §6 UTD wedge diffraction, specialized to a screen (n=2)."
  @pi :math.pi()

  @doc """
  Transition function F(x), Eqs (92)-(93), expressed via Fresnel C/S:
  F(x) = 2j sqrt(x) exp(jx) sqrt(pi/2) [(1/2 - C(u)) - j(1/2 - S(u))],
  u = sqrt(2x/pi), since integral_0^sqrt(x) exp(-jt^2) dt = sqrt(pi/2)(C(u)-jS(u)).
  """
  def f_transition(x, cs_fun) do
    u = :math.sqrt(2.0 * x / @pi)
    {c, s} = cs_fun.(u)
    inner = {0.5 - c, -(0.5 - s)}
    pref = Cx.scale(Cx.mul({0.0, 2.0 * :math.sqrt(x)}, Cx.expj(x)), :math.sqrt(@pi / 2.0))
    Cx.mul(pref, inner)
  end

  defp round_int(x), do: trunc(Float.round(x * 1.0))

  # One cot*F term of Eq (91); s = +1/-1 selects a^+/a^- and cot((pi+s*beta)/2n).
  # Near shadow/reflection boundaries use the finite limit, Eq (102),
  # with eps per Eqs (103)/(104).
  defp term(beta, s, n, k, l, cs_fun) do
    n_int = round_int((beta + s * @pi) / (2.0 * n * @pi))
    a = 2.0 * :math.pow(:math.cos((2.0 * n * @pi * n_int - beta) / 2.0), 2)
    eps = @pi + s * beta - 2.0 * @pi * n * n_int

    if abs(eps) < 1.0e-3 do
      sg = if eps > 0, do: 1.0, else: (if eps < 0, do: -1.0, else: 0.0)
      inner = {sg * :math.sqrt(2.0 * @pi * k * l), 0.0}
      inner = Cx.add(inner, Cx.scale(Cx.expj(@pi / 4.0), -2.0 * k * l * eps))
      Cx.scale(Cx.mul(inner, Cx.expj(@pi / 4.0)), n * 1.0)
    else
      cot = 1.0 / :math.tan((@pi + s * beta) / (2.0 * n))
      Cx.scale(f_transition(k * l * a, cs_fun), cot)
    end
  end

  @doc "Diffraction coefficient D, Eq (91), with face reflection coefficients r0/rn."
  def diff_coeff(phi1, phi2, n, k, l, r0, rn, cs_fun) do
    bm = phi2 - phi1
    bp = phi2 + phi1
    t1 = term(bm, +1, n, k, l, cs_fun)
    t2 = term(bm, -1, n, k, l, cs_fun)
    t3 = Cx.mul(r0, term(bp, -1, n, k, l, cs_fun))
    t4 = Cx.mul(rn, term(bp, +1, n, k, l, cs_fun))
    sum = Cx.add(Cx.add(t1, t2), Cx.add(t3, t4))
    pref = -1.0 / (2.0 * n * :math.sqrt(2.0 * @pi * k))
    Cx.mul(Cx.scale(sum, pref), Cx.expj(-@pi / 4.0))
  end

  defp screen(s1, s2, delta, lambda, cs_fun, r0, rn) do
    k = 2.0 * @pi / lambda
    l = s1 * s2 / (s1 + s2)
    phi1 = @pi / 2.0
    phi2 = 3.0 * @pi / 2.0 + delta
    d = diff_coeff(phi1, phi2, 2.0, k, l, r0, rn, cs_fun)
    s = :math.sqrt(s1 * s1 + s2 * s2 + 2.0 * s1 * s2 * :math.cos(delta))
    # Eq (90) with e0 = 1; Eq (105) adds the LOS ray in the lit region.
    e = Cx.mul(Cx.expj(-k * s1), Cx.scale(d, :math.sqrt(s1 / (s2 * (s1 + s2))) / s1))
    e = Cx.mul(e, Cx.expj(-k * s2))
    e_total = if phi2 < phi1 + @pi, do: Cx.add(e, Cx.scale(Cx.expj(-k * s), 1.0 / s)), else: e
    # Eq (106): dB relative to free space (negative = loss).
    e_db = 20.0 * :math.log10(Cx.mag(Cx.scale(e_total, s)))
    h = s1 * s2 * :math.sin(delta) / s
    v = h * :math.sqrt(2.0 * (s1 + s2) / (lambda * s1 * s2))
    {e_db, v}
  end

  @doc "Absorbing screen (R0=Rn=0) — the ITU canonical knife-edge equivalence case."
  def screen_case(s1, s2, delta, lambda, cs_fun),
    do: screen(s1, s2, delta, lambda, cs_fun, {0.0, 0.0}, {0.0, 0.0})

  @doc "PEC screen, soft polarization (R0=Rn=-1)."
  def screen_case_pec(s1, s2, delta, lambda, cs_fun),
    do: screen(s1, s2, delta, lambda, cs_fun, {-1.0, 0.0}, {-1.0, 0.0})
end

defmodule Profiles do
  @moduledoc "RMS delay spread of a tap list [{delay_ns, power_db}]."
  def rms_ds(taps) do
    ps = Enum.map(taps, fn {_t, db} -> :math.pow(10.0, db / 10.0) end)
    ts = Enum.map(taps, fn {t, _db} -> t end)
    sp = Enum.sum(ps)
    m1 = Enum.sum(Enum.zip(ps, ts) |> Enum.map(fn {p, t} -> p * t end)) / sp
    m2 = Enum.sum(Enum.zip(ps, ts) |> Enum.map(fn {p, t} -> p * t * t end)) / sp
    :math.sqrt(m2 - m1 * m1)
  end

  # ITU-R M.1225 Annex 2 Tables 3-5 (relative delay ns, average power dB).
  def indoor_a, do: [{0, 0}, {50, -3.0}, {110, -10.0}, {170, -18.0}, {290, -26.0}, {310, -32.0}]
  def indoor_b, do: [{0, 0}, {100, -3.6}, {200, -7.2}, {300, -10.8}, {500, -18.0}, {700, -25.2}]
  def pedestrian_a, do: [{0, 0}, {110, -9.7}, {190, -19.2}, {410, -22.8}]
  def vehicular_a, do: [{0, 0.0}, {310, -1.0}, {710, -9.0}, {1090, -10.0}, {1730, -15.0}, {2510, -20.0}]

  # 3GPP TR 38.901 v16.1.0 Tables 7.7.2-1 and 7.7.2-3 (normalized delays).
  def tdl_a, do: [{0.0000,-13.4},{0.3819,0},{0.4025,-2.2},{0.5868,-4},{0.4610,-6},{0.5375,-8.2},{0.6708,-9.9},{0.5750,-10.5},{0.7618,-7.5},{1.5375,-15.9},{1.8978,-6.6},{2.2242,-16.7},{2.1718,-12.4},{2.4942,-15.2},{2.5119,-10.8},{3.0582,-11.3},{4.0810,-12.7},{4.4579,-16.2},{4.5695,-18.3},{4.7966,-18.9},{5.0066,-16.6},{5.3043,-19.9},{9.6586,-29.7}]
  def tdl_c, do: [{0,-4.4},{0.2099,-1.2},{0.2219,-3.5},{0.2329,-5.2},{0.2176,-2.5},{0.6366,0},{0.6448,-2.2},{0.6560,-3.9},{0.6584,-7.4},{0.7935,-7.1},{0.8213,-10.7},{0.9336,-11.1},{1.2285,-5.1},{1.3083,-6.8},{2.1704,-8.7},{2.7105,-13.2},{4.2589,-13.9},{4.6003,-13.9},{5.4902,-15.8},{5.6077,-17.1},{6.3065,-16},{6.6374,-15.7},{7.0427,-21.6},{8.6523,-22.8}]
end

defmodule Report do
  def fmt(x, p \\ 4), do: :erlang.float_to_binary(x * 1.0, decimals: p)
  def section(t), do: IO.puts("\n== #{t} ==")
end

pi = :math.pi()
c = 299_792_458.0
f = 2.4e9
lambda = c / f
csb = fn u -> Fresnel.cs_boersma(u) end

IO.puts("Chronos physics-depth verification (ticket #24)")
IO.puts("lambda = #{Report.fmt(lambda, 9)} m  (c = #{c} m/s, f = #{f} Hz)")

# --- 1. Boersma accuracy -----------------------------------------------------
errs =
  for v <- Enum.map(0..600, fn i -> i * 0.01 end) do
    {cb, sb} = Fresnel.cs_boersma(v)
    {cs, ss} = Fresnel.cs_simpson(v)
    max(abs(cb - cs), abs(sb - ss))
  end

IO.puts("\nBoersma (P.526 Eqs 8-9) vs Simpson reference: max |err| on v=0..6 step 0.01 = #{Report.fmt(Enum.max(errs), 9)}")

# --- 2. Knife-edge J(v) ------------------------------------------------------
Report.section("Knife-edge J(v): exact Eq (30) vs approximation Eq (31)")

for v <- [-3.0, -2.0, -1.5, -1.2, -1.0, -0.78, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0] do
  je = Fresnel.j_exact(v, :simpson)
  jb = Fresnel.j_exact(v, :boersma)
  ja = Fresnel.j_approx(v)
  IO.puts("v=#{Report.fmt(v, 2)}  J_exact=#{Report.fmt(je)}  J_boersma=#{Report.fmt(jb)}  J_approx=#{Report.fmt(ja)}  approx-exact=#{Report.fmt(ja - je)}")
end

# --- 3. UTD screen vs knife-edge (ITU canonical equivalence) -----------------
Report.section("UTD screen n=2 R=0 vs exact J(v) — P.526-16 §6 note after Eq (106)")
IO.puts("Geometry: edge at origin, screen along +x; Tx=(0,100), Rx=(100 sin d, -100 cos d); f=2.4 GHz")

utd_errs =
  for deg <- [-10.0, -5.0, -2.0, -1.0, -0.5, -0.1, 0.1, 0.5, 1.0, 2.0, 5.0, 10.0] do
    d = deg * pi / 180.0
    {e_db, v} = UTD.screen_case(100.0, 100.0, d, lambda, csb)
    je = Fresnel.j_exact(v, :simpson)
    err = -e_db - je
    IO.puts("delta=#{Report.fmt(deg, 1)} deg  v=#{Report.fmt(v)}  UTD_loss=#{Report.fmt(-e_db)} dB  J_exact=#{Report.fmt(je)} dB  err=#{Report.fmt(err, 5)} dB")
    abs(err)
  end

IO.puts("max |UTD_loss - J_exact| = #{Report.fmt(Enum.max(utd_errs), 5)} dB over v in [-4.93, 4.93]")

{e_in, _} = UTD.screen_case(100.0, 100.0, 1.0e-7, lambda, csb)
{e_out, _} = UTD.screen_case(100.0, 100.0, -1.0e-7, lambda, csb)
IO.puts("Shadow boundary (v=0): total field #{Report.fmt(e_in)} dB (shadow side) / #{Report.fmt(e_out)} dB (lit side); expect -6.0206")

Report.section("PEC screen (R0=Rn=-1) vs absorbing screen (R=0), dB rel. free space")

for deg <- [-10.0, -5.0, -2.0, 2.0, 10.0] do
  d = deg * pi / 180.0
  {e_abs, v} = UTD.screen_case(100.0, 100.0, d, lambda, csb)
  {e_pec, _} = UTD.screen_case_pec(100.0, 100.0, d, lambda, csb)
  IO.puts("delta=#{Report.fmt(deg, 1)} deg  v=#{Report.fmt(v)}  absorbing=#{Report.fmt(e_abs)} dB  PEC=#{Report.fmt(e_pec)} dB")
end

# --- 4. Finite-width screen (P.526 §5.1) -------------------------------------
Report.section("Finite-width screen: 3 equal-v edges, Eqs (71)/(72)")

for v <- [0.0, 1.0, 2.0] do
  j = Fresnel.j_approx(v)
  jlin = :math.pow(10.0, j / 20.0)
  jmin = -20.0 * :math.log10(3.0 / jlin)
  jav = -10.0 * :math.log10(3.0 / (jlin * jlin))
  IO.puts("v=#{Report.fmt(v, 1)}: single-edge J=#{Report.fmt(j)} dB; Jmin=#{Report.fmt(jmin)} dB (#{Report.fmt(jmin - j)} dB); Jav=#{Report.fmt(jav)} dB (#{Report.fmt(jav - j)} dB)")
end

# --- 5. Friis / P.525 ---------------------------------------------------------
Report.section("Friis FSPL = 20log10(4 pi d / lambda); P.525-5 Eqs (5)/(6)")
fspl = fn d -> 20.0 * :math.log10(4.0 * pi * d / lambda) end

for d <- [1.0, 2.0, 10.0, 100.0] do
  exact = fspl.(d)
  practical = 32.4 + 20.0 * :math.log10(f / 1.0e6) + 20.0 * :math.log10(d / 1000.0)
  IO.puts("d=#{Report.fmt(d, 0)} m  FSPL_exact=#{Report.fmt(exact)} dB  P.525(32.4)=#{Report.fmt(practical)} dB  offset=#{Report.fmt(exact - practical)} dB")
end

IO.puts("Pr example: Pt=20 dBm, Gt=Gr=0 dBi, d=10 m -> Pr=#{Report.fmt(20.0 - fspl.(10.0))} dBm")
IO.puts("lambda/(4 pi) = #{Report.fmt(lambda / (4.0 * pi), 9)} (= #{Report.fmt(20.0 * :math.log10(lambda / (4.0 * pi)))} dB vs current 1/r-at-1m normalization)")

# --- 6. Two-ray (Goldsmith §2.4) ----------------------------------------------
Report.section("Two-ray ground reflection, ht=hr=1.5 m, R=-1, unit gains")
ht = 1.5
hr = 1.5
IO.puts("critical distance dc = 4 ht hr / lambda = #{Report.fmt(4.0 * ht * hr / lambda)} m (Eq 2.22)")

for d <- [50.0, 100.0, 200.0] do
  dlos = :math.sqrt(d * d + :math.pow(ht - hr, 2))
  dref = :math.sqrt(d * d + :math.pow(ht + hr, 2))
  k = 2.0 * pi / lambda
  ph = Cx.add(Cx.scale(Cx.expj(-k * dlos), 1.0 / dlos), Cx.scale(Cx.expj(-k * dref), -1.0 / dref))
  pr_exact = :math.pow(lambda / (4.0 * pi), 2) * :math.pow(Cx.mag(ph), 2)
  pr_asym = :math.pow(ht * hr, 2) / :math.pow(d, 4)
  IO.puts("d=#{Report.fmt(d, 0)} m: exact Pr/Pt=#{Report.fmt(10.0 * :math.log10(pr_exact))} dB; asymptotic G ht^2 hr^2/d^4=#{Report.fmt(10.0 * :math.log10(pr_asym))} dB")
end

# --- 7. Delay spreads ----------------------------------------------------------
Report.section("RMS delay spread recomputed from tap tables")
IO.puts("M.1225 Indoor A: #{Report.fmt(Profiles.rms_ds(Profiles.indoor_a()), 2)} ns (Table 2 nominal 35)")
IO.puts("M.1225 Indoor B: #{Report.fmt(Profiles.rms_ds(Profiles.indoor_b()), 2)} ns (Table 2 nominal 100)")
IO.puts("M.1225 Pedestrian A: #{Report.fmt(Profiles.rms_ds(Profiles.pedestrian_a()), 2)} ns (Table 2 nominal 45)")
IO.puts("M.1225 Vehicular A: #{Report.fmt(Profiles.rms_ds(Profiles.vehicular_a()), 2)} ns (Table 2 nominal 370)")
IO.puts("TR 38.901 TDL-A normalized rms DS: #{Report.fmt(Profiles.rms_ds(Profiles.tdl_a()), 4)} (target 1.0)")
IO.puts("TR 38.901 TDL-C normalized rms DS: #{Report.fmt(Profiles.rms_ds(Profiles.tdl_c()), 4)} (target 1.0)")
IO.puts("TDL-C scaled to DS=100 ns (Eq 7.7-1): max delay = #{Report.fmt(8.6523 * 100.0, 1)} ns")

sa = Profiles.rms_ds(Profiles.indoor_a())
sb = Profiles.rms_ds(Profiles.indoor_b())
IO.puts("Coherence BW (Goldsmith/Lee): Bc(0.5)=0.2/sigma, Bc(0.9)=0.02/sigma")
IO.puts("  Indoor A: #{Report.fmt(0.2 / (sa * 1.0e-9) / 1.0e6, 2)} MHz / #{Report.fmt(0.02 / (sa * 1.0e-9) / 1.0e6, 2)} MHz")
IO.puts("  Indoor B: #{Report.fmt(0.2 / (sb * 1.0e-9) / 1.0e6, 2)} MHz / #{Report.fmt(0.02 / (sb * 1.0e-9) / 1.0e6, 2)} MHz")

# --- 8. TDL mechanics -----------------------------------------------------------
Report.section("TDL mechanics")
IO.puts("48 kHz sample period = #{Report.fmt(1.0e6 / 48_000.0, 3)} us (>> indoor A max excess delay 310 ns)")
IO.puts("Indoor A tap indices at fs=100 MHz (Ts=10 ns, nearest bin): " <>
  (Enum.map(Profiles.indoor_a(), fn {t, _} -> "#{trunc(Float.round(t / 10.0))}" end) |> Enum.join(", ")))

IO.puts("Linear-interp fractional delay |H(f)| at frac=0.5 sample (current NIF):")

for fdiv <- [0.1, 0.25, 0.4, 0.5] do
  th = 2.0 * pi * fdiv
  h = Cx.add({0.5, 0.0}, Cx.scale(Cx.expj(-th), 0.5))
  IO.puts("  f/fs=#{fdiv}: |H|=#{Report.fmt(Cx.mag(h))} (#{Report.fmt(20.0 * :math.log10(max(Cx.mag(h), 1.0e-16)))} dB)")
end

IO.puts("Two equal-amplitude paths, excess delay lambda/(2c) = #{Report.fmt(lambda / (2.0 * c) * 1.0e9, 5)} ns (path diff #{Report.fmt(lambda / 2.0 * 100.0, 4)} cm):")
IO.puts("  with static carrier phase: DC null (fc*dtau = 0.5); without: constructive at t=0")

# --- 9. Current-implementation quirk magnitudes ---------------------------------
Report.section("Quirk magnitudes (current PR #8 behavior vs corrected)")
h = -0.5
d1 = 10.0
d2 = 10.0
v_signed = h * :math.sqrt(2.0 / lambda * (1.0 / d1 + 1.0 / d2))
IO.puts("Edge 0.5 m BELOW LOS, d1=d2=10 m: signed v=#{Report.fmt(v_signed)} -> J=#{Report.fmt(Fresnel.j_approx(v_signed))} dB; unsigned v=#{Report.fmt(-v_signed)} -> J=#{Report.fmt(Fresnel.j_approx(-v_signed))} dB")
IO.puts("Material double-count: J(1)=#{Report.fmt(Fresnel.j_approx(1.0))} dB + concrete 6 dB = #{Report.fmt(Fresnel.j_approx(1.0) + 6.0)} dB vs #{Report.fmt(Fresnel.j_approx(1.0))} dB (J is already the total edge loss)")
