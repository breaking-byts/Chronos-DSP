# syntax=docker/dockerfile:1
#
# Multi-stage build for the Chronos DSP Phoenix release.
#
# Pinned images (verified against Docker Hub):
#   hexpm/elixir:1.19.5-erlang-28.3.3-debian-bookworm-20260824-slim
#   rust:1.89.0-bookworm
#   debian:bookworm-20260824-slim
#
# .tool-versions pins Erlang 28.3.1, which is not published on Docker Hub for
# Elixir 1.19.5. 28.3.3 is the closest available patch release of the same OTP
# minor (28.3.x) and is ABI-compatible for this project.

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.3.3-debian-bookworm-20260824-slim
ARG RUST_IMAGE=rust:1.89.0-bookworm
ARG RUNTIME_IMAGE=debian:bookworm-20260824-slim

# ---------------------------------------------------------------------------
# Rust toolchain (copied into the Elixir builder below)
# ---------------------------------------------------------------------------
FROM ${RUST_IMAGE} AS rust

# ---------------------------------------------------------------------------
# Builder: deps, Rust NIF, release
# ---------------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      libssl-dev \
 && rm -rf /var/lib/apt/lists/*

COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup

RUN rustc --version && cargo --version

WORKDIR /app

# Tooling layer: only invalidated when the base image changes.
RUN mix local.hex --force && mix local.rebar --force

# Dependency layer: only invalidated when mix.exs / mix.lock change.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
RUN mix deps.compile

# Application source. `mix compile` also invokes Rustler, which builds the
# Rust NIF from native/chronos_dsp and copies it into priv/native.
COPY native native
COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

# ---------------------------------------------------------------------------
# Runtime: minimal Debian with only the libraries the release + NIF need
# ---------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE} AS runtime

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/app \
    PORT=4000

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      libgcc-s1 \
      libncurses6 \
      libstdc++6 \
      locales \
      openssl \
      tini \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 chronos \
 && useradd --system --uid 10001 --gid chronos --home-dir /app --shell /usr/sbin/nologin chronos \
 && mkdir -p /app \
 && chown -R chronos:chronos /app

WORKDIR /app

COPY --from=builder --chown=chronos:chronos /app/_build/prod/rel/chronos ./

USER chronos

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/healthz" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/chronos", "start"]
