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

**Height-aware 2D**:
A top-down XY rendering that conveys z through visual cues while keeping the
layout planar.
_Avoid_: 2.5D, pseudo-3D

**Transmit power**:
The transmitter's output power in dBm, scaling every path gain relative to the
10 dBm reference default; it boosts the signal, not the noise floor.
_Avoid_: TX strength, power level

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

### Store and operations

**Scene store**:
The capped, file-backed store of named scenes: anonymous writes, oldest-first
eviction, ephemeral by default.
_Avoid_: database, save library

**Eviction**:
Dropping the oldest scenes (by modification time) when a scene-store cap is
exceeded; oldest first.
_Avoid_: garbage collection, pruning

**Dirty state**:
The live world differs from the last saved or loaded scene snapshot.
_Avoid_: unsaved changes, modified flag

**Telemetry event**:
A named runtime observation — render timing, session lifecycle, or an API
request — emitted with measurements and structured metadata for logging.
_Avoid_: metric (unqualified), log line

**Coverage gate**:
The minimum total Elixir test coverage (80%) the suite must reach to pass.
_Avoid_: coverage target

**Property test**:
A test that checks an invariant over generated inputs instead of fixed
examples.
_Avoid_: random test (unqualified)

**Smoke test**:
A shallow boot-and-serve check of a fresh release: readiness with the NIF
loaded, the dashboard HTML, and static assets.
_Avoid_: sanity check, integration test (for the release check)
