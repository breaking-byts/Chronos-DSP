# Chronos-DSP

Real-time wireless propagation simulation: a small 3D world of transmitters,
receivers, and planar walls, rendered into complex baseband samples. This
glossary fixes the language for the simulator's domain; implementation details
live in `docs/ARCHITECTURE.md`.

## Language

### World and propagation

**Scene**:
A user-defined world (nodes and walls) saved under a name in the scene store.
_Avoid_: scenario (for user worlds), map, level

**Scenario**:
A built-in parametric world generator (`orbit`, `open_field`).
_Avoid_: scene (for built-ins), preset

**Path**:
One propagation route from transmitter to receiver — line-of-sight, reflection,
diffraction, or transmission — carrying gain, delay, and Doppler.
_Avoid_: ray, link

**Bounce order**:
The number of wall reflections a path undergoes; first order is a single
reflection.
_Avoid_: hop count, bounce count

**Material**:
A catalogued wall substance with reflection, transmission, and diffraction
losses in dB.
_Avoid_: surface type, wall kind

**Knife-edge diffraction**:
The ITU-R P.526 single knife-edge model currently implemented for paths bending
around wall edges.
_Avoid_: UTD (not implemented)

**Transmission path**:
A path through a blocking wall, summing the transmission losses of the walls it
crosses.
_Avoid_: penetration ray

### Simulation

**Session**:
One browser connection's supervised simulation process, discarded on
disconnect.
_Avoid_: user, connection (in domain prose)

**Tick**:
One simulation step advancing 0.1 s of simulation time; the wall-clock interval
is clamped to 20–2000 ms.

**Frame**:
One rendered snapshot at a tick: paths, DSP samples, and metrics.

### Engine

**Reference fallback**:
The pure-Elixir DSP implementation used when the native artifact is unavailable
outside production.
_Avoid_: software mode, slow path

**NIF parity**:
Bit-level agreement between the Rust NIF and the reference fallback: same
xorshift64* RNG, sample order, interpolation, Doppler rotation, and noise
scaling.
_Avoid_: equivalence (unqualified)