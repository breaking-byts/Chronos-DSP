# Rate limiting and request hardening for the anonymous API

Research for ticket #26 · 2026-11-20 · `research/api-rate-limits` branch.
Posture: ADR 0001 (single-node public showcase, no auth, capped ephemeral
scene store), deployed behind Fly.io or Render TLS-terminating proxies
(`docs/DEPLOYMENT.md`). All library claims below were checked against
primary sources (hexdocs, version-tagged source, official platform docs)
on 2026-11-20; citations in [Sources](#sources).

Locked versions (`mix.lock`): phoenix 1.7.21, plug 1.19.1, plug_cowboy
**2.7.5**, cowboy 2.14.2, ranch 2.2.0, jason 1.4.4, phoenix_live_view
0.20.17. (The ticket brief said plug_cowboy 2.6; the lockfile says 2.7.5.)

## TL;DR

- **Use Hammer 7 (`{:hammer, "~> 7.5"}`, ETS backend, fixed-window) as a
  small endpoint plug**: per-IP limits on `/api/*` plus one **global
  backstop key** that bounds aggregate CPU no matter how many source IPs
  an attacker uses. Actively maintained (7.5.1, 2026-10-27), zero runtime
  dependencies, ETS counters fit the single-node ADR. Deny → `429` +
  `Retry-After` (round ms up to whole seconds, floor 1).
- **Fix client-IP correctness first**: `conn.remote_ip` is the proxy's IP
  behind Fly/Render. Add the maintained `remote_ip` plug (1.3.0,
  2026-11-08) early in the endpoint, configured per host (Fly:
  `Fly-Client-IP`; Render: right-to-left `X-Forwarded-For` with known
  proxy ranges). Without this, per-IP limits throttle the proxy — i.e.
  everyone or no one.
- **Config-only hardening, no new deps**: lower `Plug.Parsers` `:length`
  (default 8 MB) and `:query_string_length` (default 1 MB); set Cowboy
  `protocol_options` timeouts/keepalive; set Ranch `transport_options`
  with `num_conns_sups: 1` so `max_connections` is a real global cap
  (plug_cowboy's defaults allow ~1.6M concurrent connections).
- **Jason has no nesting-depth option, and does not need one**: its
  decoder is iterative (explicit stack, tail-recursive), so deep nesting
  costs heap linear in body size, not a stack overflow. The body cap is
  the effective nesting bound. (Corrects the framing in the PR #9 digest.)
- **WebSockets have no built-in connection cap.** Ranch `max_connections`
  bounds HTTP + WS together (upgrade is an in-process protocol takeover).
  Phoenix/LiveView expose `connect_info` (`:peer_data`, `:x_headers`) for
  per-IP decisions at connect; LiveView `mount/3` cannot return an error,
  so rejection there means raise/redirect. Defer per-IP WS limits; the
  global connection cap + frame-size cap cover the showcase.
- `plug_attack` works but is dormant (0.4.3, 2021; last commit a 2025
  README touch-up) and blocks with **403 by default**, not 429. Not
  recommended over Hammer here.

Rate limiting bounds **aggregate** abuse. Per-request cost is bounded by
the in-flight work: #8 (`:max_paths` 32), #9 (fixed 128-sample response),
#10 export caps, #11 scene caps. Both layers are needed; neither replaces
the other.

## 1. Current state (verified in tree)

- `lib/chronos_web/endpoint.ex`: `Plug.Parsers` with
  `parsers: [:urlencoded, :multipart, :json]`, `pass: ["*/*"]`,
  `json_decoder: Phoenix.json_library()` — **no `:length` override**, so
  the 8 MB default applies to every route. No rate-limit plug anywhere.
  The LiveView socket declares only `connect_info: [session: MFA]`.
- `config/*.exs`: endpoint `http:` config is `[ip: ..., port: ...]` only —
  no `protocol_options`, no `transport_options`; all Cowboy/Ranch
  defaults apply (PR #9 digest, confirmed).
- PR #9 digest: query-string bypass (`?_format=html`, `?tick=0` with `{}`
  body) is being fixed in the land ticket; HTML-only error rendering is
  getting `ErrorJSON`. Any 429/413 plug added here should emit JSON
  errors consistent with that work, and the land ticket's generalization
  of route-scoped plugs to #11's `/api/scenes` routes must also cover the
  rate-limit plug.
- Phoenix compiles `plug :socket_dispatch` **first** in the endpoint
  pipeline ([20], `defp plug()`), so `/live` WebSocket upgrades never
  reach endpoint plugs (RemoteIp, rate limiting, parsers). WS abuse must
  be handled at the transport/socket layer (§5).

## 2. Rate-limiting options

### 2.1 Hammer (recommended)

- **Maintenance**: 7.5.1 released 2026-10-27; repo pushed 2026-11-18;
  1 open issue; ~20k Hex downloads/day; MIT; maintainers Emmanuel
  Pinault & June Kelly [1]. Requires Elixir `~> 1.14` and has **no
  runtime dependencies** (Igniter is optional installer tooling) [6].
- **API**: `defmodule Chronos.RateLimit do use Hammer, backend: :ets end`,
  started under the application supervisor (`start_link(clean_period:
  :timer.minutes(1))`). Check with
  `hit(key, scale_ms, limit) :: {:allow, count} | {:deny, retry_after_ms}`;
  `hit/4` takes an increment, so expensive actions can cost more than 1
  (e.g. charge CSV exports 5 tokens) [2][3].
- **Algorithms (ETS backend, v7.5.1 source)**: `:fix_window` (default),
  `:fix_window_per_key`, `:sliding_window`, `:leaky_bucket`,
  `:token_bucket` [4]. Note: the ticket's "ETS token bucket" description
  is not the 7.x default — fixed window is. Fixed window allows up to 2×
  the limit across a window boundary; `:fix_window_per_key` anchors each
  key's window to its first hit so boundaries aren't globally
  synchronized [2]. For a showcase, either is fine; token bucket is
  available if burst shaping is wanted later.
- **Mechanics**: counters live in an ETS table named after the module;
  hits are atomic `:ets.update_counter` operations — no GenServer
  round-trip per request. A cleaner process sweeps expired entries every
  `clean_period` (default 1 min); `key_older_than` defaults to 24 h in
  v7.5.1 code (the moduledoc's "1 hour" is stale) [4]. Memory is
  proportional to active keys (one entry per IP per window) — trivial at
  showcase scale, and bounded by the connection cap regardless.
- **429 wiring**: the official tutorial shows exactly the endpoint-plug
  pattern needed here, including the `Retry-After` subtlety: round
  `retry_after` ms **up** to whole seconds and floor at 1, or clients see
  `retry-after: 0` and retry immediately [3].
- **Distribution story**: ETS is single-node — correct under ADR 0001.
  If the posture ever changes: `Hammer.Redis` backend, or the
  "Distributed ETS" guide (Phoenix.PubSub broadcast of hits, eventually
  consistent, new nodes start with empty counters; based on hexpm's own
  limiter) [5]. Render's guidance likewise says multi-instance needs a
  shared store [11]. No Redis needed today.

### 2.2 plug_attack

- **Maintenance**: 0.4.3 released 2021-08-09; last commit 2025-04-18 is a
  README modernization only; 6 open issues; ~1.2k downloads/day;
  Apache-2.0 [7]. Effectively dormant.
- **API**: `use PlugAttack` + `rule` macros; `throttle conn.remote_ip,
  period: 60_000, limit: 10, storage: {PlugAttack.Storage.Ets, name}`;
  the ETS storage is a separate supervised child with `clean_period`.
  Throttle data exposes `limit`, `remaining`, `expires_at` for
  `x-ratelimit-*` headers [7].
- **Semantics gap**: the default `block_action/3` sends **403 Forbidden**
  (source-verified [8]); correct 429 + `Retry-After` requires overriding
  `block_action/3` yourself. The README also explicitly warns that behind
  a proxy you must first rewrite `remote_ip` (it points at the
  `remote_ip` package) [7].
- Verdict: a fine toolkit (Rack::Attack-inspired, allow/block/throttle
  rules), but for this showcase it is more wiring than Hammer, with a
  wrong-default status code and a five-year-old release.

### 2.3 Custom plug (zero-dep alternative)

A fixed-window per-IP limiter is ~40 lines: an ETS table keyed
`{ip, window_start}`, `:ets.update_counter/4` with a default tuple for
atomic create-and-increment, a periodic `:ets.select_delete` sweep, and a
plug that halts with 429. No dependency, no supply chain. Trade-offs:
you own the correctness (atomicity, cleanup, window-boundary semantics,
IPv6 formatting) and the tests; Hammer already is this, tested and
maintained. Reasonable fallback if adding a dep is objectionable, but
"simplest" here favors Hammer: one dep, ~40 lines of wiring, documented
429 pattern.

### 2.4 Cowboy / Ranch built-ins

Cowboy has **no request-rate limiting**. What it has is connection and
message hygiene (defaults from the 2.14 manual, cross-checked against
2.14.2 source [12][13]):

| Option | Default | Effect |
|---|---|---|
| `idle_timeout` | 60_000 ms | close connection when no data received |
| `request_timeout` | 5_000 ms | close connection when no complete request arrives |
| `inactivity_timeout` | 300_000 ms | deprecated since 2.13 |
| `max_keepalive` | 1000 | max requests per connection, then close |
| `max_request_line_length` | 8000 | → 414 |
| `max_header_name_length` / `max_header_value_length` / `max_headers` | 64 / 4096 / 100 | → 431 |
| `max_method_length` / `max_empty_lines` | 32 / 5 | parse hygiene |
| `max_skip_body_length` | 1_000_000 | unread body larger than this (or unknown length) → connection closed |
| `proxy_header` | false | HAProxy **PROXY protocol** only — *not* X-Forwarded-For |

These bound slowloris-style connection hoarding and header abuse, and
`max_skip_body_length` bounds the cost of requests we never read (e.g.
requests halted by a rate-limit plug placed before `Plug.Parsers`). They
do not bound request *rate* from a well-behaved client — that needs §2.1.

Ranch adds the connection-count cap (§4.4) and `alarms` (callback when a
connection supervisor crosses a `num_connections` threshold, 5 s
cooldown) — useful later for alerting, not limiting [14].

### 2.5 Comparison

| | Hammer 7 | plug_attack | custom plug | Cowboy built-ins |
|---|---|---|---|---|
| Maintained | yes (Oct 2026) | dormant (2021) | n/a | yes (locked 2.14.2) |
| Rate limiting | yes, per-key + global | yes, per-rule | yes | **no** |
| Storage | ETS (default), Redis, Mnesia, Atomic | ETS | ETS | n/a |
| 429 out of the box | pattern in tutorial (`{:deny, ms}`) | no — default 403 | you write it | n/a |
| Runtime deps | 0 | plug | 0 | already present |
| Multi-node path | Redis / distributed-ETS guide | roll your own | roll your own | n/a |
| Wiring effort | module + child + plug | module + storage child + rules + 429 override | table + sweep + plug | config only |

## 3. Per-IP correctness behind Fly/Render

**The problem.** `Plug.Conn.remote_ip` "defaults to peer's IP" and is
"meant to be overwritten by plugs that understand e.g. the
`X-Forwarded-For` header" — Plug itself never parses forwarding headers
[9]. Cowboy likewise stays out of it (`proxy_header` is PROXY-protocol
only, §2.4). Behind Fly/Render the peer is the proxy, so a naive
`conn.remote_ip` key puts **all visitors in one bucket**.

**The fix.** The `remote_ip` package (1.3.0, 2026-11-08, ~14k
downloads/day, MIT [10]) rewrites `conn.remote_ip` from `X-Forwarded-For`,
`X-Real-Ip`, `X-Client-Ip`, or RFC 7239 `Forwarded`. It walks IPs
**last-to-first**, skipping known proxies (loopback/private by default),
and stops at the first untrusted address — the anti-spoofing direction
(client-supplied leftmost entries are never trusted blindly).
Configurable `:headers`, `:parsers`, `:clients`, `:proxies`, all usable
as runtime MFA tuples; `RemoteIp.from/2` works on raw header lists
(e.g. socket `:x_headers`). Its README is explicit: **do not use it when
not behind a proxy** — gate it on the deployment environment [10].

**Platform specifics.**

- **Fly.io** (official docs [15]): Fly Proxy sets `Fly-Client-IP` (client
  IP from the proxy's perspective) and `X-Forwarded-For`, whose
  **rightmost** entry is the app's own Fly IP. Docs recommend
  `Fly-Client-IP` when nothing sits in front of Fly, and warn XFF must be
  parsed cautiously. Simplest correct config: `RemoteIp` with
  `headers: ["fly-client-ip"]`. Trust precondition: the app must only be
  reachable through Fly Proxy. Community security guidance (secondary
  source [17]) reports Fly Proxy overwrites client-supplied
  `Fly-Client-IP`, and recommends an IPv4-only bind (`0.0.0.0`, which
  this repo already uses) because Fly private networking is IPv6-only —
  an IPv4 bind is then reachable only via the proxy. Verify this trust
  boundary at deploy time.
- **Render** (official article [11]): all inbound traffic passes
  Cloudflare + Render load balancers; the app sees proxy IPs; "read the
  `x-forwarded-for` header". Community reports (secondary [18]) confirm
  Render **appends to** client-supplied XFF rather than sanitizing it,
  and that Cloudflare's `CF-Connecting-IP`/`True-Client-IP` are present.
  Consequence: RemoteIp's *default* proxy list (loopback/private) is not
  enough on Render — the rightmost entries are public Cloudflare/Render
  IPs, so you must configure `:proxies` with those ranges (or a custom
  parser for `cf-connecting-ip`). This is real operational cost; it is
  the main reason Fly is the simpler trust model for this showcase.
- **Local/dev**: no proxy → no RemoteIp; `remote_ip` stays the loopback
  peer, which is fine (and per-IP limits are effectively global there).

**Sockets**: endpoint plugs don't run for WS upgrades (§1), but
`connect_info: [:peer_data, :x_headers]` carries the same data into
socket connect / LiveView mount, and `RemoteIp.from(x_headers)` computes
the client IP there [10][20][21].

## 4. Request hardening

### 4.1 Body and query caps — Plug.Parsers (plug 1.19.1, source-verified [16])

- `:length` defaults to **8 MB**; exceeding it raises
  `Plug.Parsers.RequestTooLargeError` with `plug_status: 413`.
  (`UnsupportedMediaTypeError` → 415, `ParseError`/`BadEncodingError` →
  400.) The land ticket's `ErrorJSON` work should render all of these.
- `:query_string_length` defaults to **1_000_000** (1 MB) — already a
  cap, but far above anything legitimate; lowering it is defense-in-depth
  alongside the query-string bypass fix.
- Caps can be set per parser: `{:json, length: 100_000}`,
  `{:multipart, length: ...}`; root options forward to all parsers.
  `:json_decoder` accepts `{M, F, args}`; `:body_reader` accepts an MFA
  that can inspect the raw body before parsing (hook for a custom depth
  pre-check if ever wanted — see §4.2, not needed).
- Body parsing only happens for POST/PUT/PATCH/DELETE. With
  `pass: ["*/*"]`, other content types pass through unparsed.
- **Multipart writes temp files to disk** (`Plug.Upload`, `PLUG_TMPDIR`).
  The endpoint currently enables `:multipart` for every route although
  the API is JSON-only. LiveView form posts need `:urlencoded`, so keep
  the global parser list, but consider a route-scoped
  `Plug.Parsers, parsers: [:json]` for the `:api` pipeline to remove
  anonymous multipart disk-write surface entirely.

Recommendation: `length: 1_000_000` globally (1 MB — generous headroom
over #11's bounded scene payloads; tighten to ~100 KB once those caps
land), `query_string_length: 8_192`. Every legitimate request in this
app is far below both; the 8 MB default only benefits attackers.

### 4.2 JSON nesting — Jason 1.4.4

- `Jason.decode/2` options are `:keys`, `:strings`, `:floats`, `:objects`
  — **there is no nesting-depth limit option** [19].
- **But the decoder is not recursive.** Verified in v1.4.4
  `lib/decoder.ex` [22]: parsing uses an explicit stack (markers
  `@terminate/@array/@key/@object`) threaded through tail-recursive
  `value/array/object/key/continue` functions. Deep nesting therefore
  grows the **heap linearly in input size**, not the BEAM call stack —
  no stack-overflow crash vector. Worst-case nesting depth is bounded by
  the body cap (each level costs ≥ 1 byte), so **lowering `:length` is
  the nesting mitigation**; a separate depth limit adds nothing material
  for this app. (This corrects the PR #9 digest's "Jason nesting
  unbounded" concern: unbounded as a *policy*, yes; unbounded as a
  *crash/memory vector*, no — the body cap bounds it.)
- Related built-in: integer tokens longer than **1024 digits** are
  rejected (`:jason, :decoding_integer_digit_limit`, default 1024) [22].
- Keep the default `keys: :strings`; `:atoms` on user input is an
  atom-exhaustion DoS (documented warning [19]). Phoenix's default
  `Jason` configuration is already safe here.
- 1.4.4 (2024-07-26) is locked; 1.4.5 (2026-05-05) is the latest stable
  — routine bump, no security advisory listed on Hex [19].

### 4.3 Cowboy protocol options (config only)

Suggested `protocol_options` for the showcase (defaults → proposed):

- `idle_timeout: 60_000 → 30_000` — halves slow-connection hoarding.
- `request_timeout: 5_000` — keep; already tight.
- `max_keepalive: 1000 → 100` — cycles proxy→app connections more often;
  cheap insurance, negligible cost behind a proxy.
- Header/line limits: keep defaults (§2.4); they already produce
  414/431 before any app code runs.
- `max_skip_body_length: 1_000_000` — keep; bounds unread-body cost for
  requests halted early (e.g. by the rate-limit plug before parsers).

### 4.4 Connection caps — the plug_cowboy default is not what it looks like

- Ranch `max_connections` (default 1024) is a **soft limit per connection
  supervisor**, and `num_conns_sups` defaults to `num_acceptors` [14].
- plug_cowboy 2.7.5 sets `num_acceptors: 100` and `max_connections:
  16_384` in `transport_options` (source-verified [23]). With 100
  connection supervisors, the effective ceiling is **100 × 16_384 ≈ 1.6M
  concurrent connections** — no meaningful bound for a small VM.
- Fix: `transport_options: [num_acceptors: 100, num_conns_sups: 1,
  max_connections: 2_048]` → one supervisor, ~2048 concurrent TCP
  connections (soft; may overshoot slightly under accept concurrency
  [14]). This caps HTTP **and** WebSocket connections together (§5).
  Tune to the VM size; 2048 is generous for a showcase and far below
  file-descriptor limits.
- Ranch `alarms` (`type: :num_connections`, threshold + callback,
  cooldown 5 s) can later emit telemetry/logs near the cap [14].

## 5. WebSocket connection caps

Facts (all source/doc-verified):

- **No built-in global WS cap exists** in Cowboy, Phoenix, or LiveView.
  `cowboy_websocket` options are `idle_timeout` (60_000 ms),
  `max_frame_size` (**infinity** by default), `compress` (false),
  `validate_utf8` (true), etc. — nothing about connection counts [24].
  Phoenix `socket/3` likewise has no max-connections option; its
  `:drainer` is graceful-shutdown machinery, not a cap [20].
- **Ranch's cap covers WS.** `cowboy_websocket` is a Ranch protocol [24],
  and the HTTP→WS upgrade is an **in-process protocol takeover**:
  `cowboy_http` handles `switch_protocol` by sending 101, terminating the
  stream/children, and calling `Protocol:takeover(...)` in the same
  connection process (cowboy_http.erl 2.14.2, "Protocol takeover" clause
  [13]). The WS session therefore remains one counted Ranch connection
  for its lifetime — §4.4's `max_connections` is the WS connection cap.
- **Phoenix socket options** (1.7.21 [20]): `websocket: [timeout:
  60_000, max_frame_size: :infinity, ...]` mirror Cowboy's. Set
  `max_frame_size` (e.g. 65_536 — LV event frames are tiny) to bound
  inbound frame memory; keep `timeout` at 60 s so dead connections reap
  themselves. `check_origin` defaults to true (CSWSH protection) — keep.
- **Per-IP decisions at connect**: `connect_info` supports `:peer_data`,
  `:x_headers`, `:uri`, `:user_agent`, `{:session, cfg}` [20]. LiveView
  0.20.17 exposes these via `get_connect_info/2` **during mount only**;
  on connected mount only declared keys are available [21]. The current
  endpoint declares only `session:` — add `:peer_data, :x_headers` to
  enable IP-based checks (via `RemoteIp.from/2` on the x_headers).
- **Rejection mechanics**: LiveView `mount/3` must return
  `{:ok, socket} | {:ok, socket, opts}` — there is **no error return**
  [21]; refusing a connection means raising or redirecting from mount
  (or an `on_mount` hook). For custom `Phoenix.Socket`s, `connect/3` can
  return `{:error, reason}` and the socket's `:error_handler` MFA maps it
  to a response — the 1.7.21 docs literally show
  `{:error, :rate_limit} → send_resp(conn, 429, ...)` [20]. LiveView's
  socket is framework-managed, so that clean hook is not available for
  `/live`; mount-side checks are the LV path.
- Note again: `/live` upgrades bypass endpoint plugs (§1), so the HTTP
  rate-limit plug does not protect WS connects; the disconnected LV
  render (a normal GET) *is* covered by it.

Recommendation for the showcase: global Ranch cap (§4.4) +
`max_frame_size: 65_536` + default 60 s idle timeout now; add
`:peer_data`/`:x_headers` to `connect_info` so a per-IP connect throttle
(Hammer hit in mount, raise/redirect on deny) can be added later without
re-plumbing. Per-IP WS limits are lower priority: each LV connection is
mostly idle memory, and the global cap already bounds the count.

## 6. 429 semantics (RFC 6585)

- 429 = "too many requests in a given amount of time"; the response
  representation **SHOULD** explain the condition and **MAY** include
  `Retry-After`; 429 responses **MUST NOT** be stored by caches. The RFC
  deliberately does not define how users are identified or requests
  counted [25].
- Under active attack, answering every request with 429 itself consumes
  resources; the RFC explicitly sanctions dropping connections instead
  (§7.2) [25]. The Ranch cap + Cowboy timeouts are that backstop; 429 is
  the polite layer for ordinary overuse.
- Wiring details: `Retry-After` is whole seconds — Hammer returns ms, so
  `max(ceil(retry_after / 1000), 1)` (tutorial pattern [3]). Body should
  be JSON (`{"error": "rate limited"}`) via the land ticket's ErrorJSON;
  Plug's default `cache-control: max-age=0, private, must-revalidate`
  already prevents shared-cache storage; add `no-store` on 429 if being
  explicit. `plug_attack`'s default 403 is semantically wrong for
  throttling (403 = forbidden regardless of rate) — another reason to
  prefer Hammer's explicit deny path.

## 7. Recommendation

Simplest mechanism that bounds anonymous CPU/disk abuse under ADR 0001,
in dependency order:

1. **Config-only hardening (no deps, do first)** — endpoint `http:` in
   `config/runtime.exs`:

   ```elixir
   http: [
     ip: {0, 0, 0, 0}, port: port,
     protocol_options: [idle_timeout: 30_000, max_keepalive: 100],
     transport_options: [num_acceptors: 100, num_conns_sups: 1, max_connections: 2_048]
   ]
   ```

   `Plug.Parsers`: add `length: 1_000_000, query_string_length: 8_192`.
   LV socket: `websocket: [connect_info: [:peer_data, :x_headers,
   session: MFA], max_frame_size: 65_536]`. Bounds: concurrent
   connections (HTTP+WS), slowloris, per-connection request count, body
   and query size, JSON parse/nesting memory, inbound WS frame size.

2. **Client IP correctness** — `{:remote_ip, "~> 1.3"}`, plugged early in
   the endpoint, enabled only in proxy deployments, runtime MFA options:
   Fly → `headers: ["fly-client-ip"]`; Render →
   `headers: ["x-forwarded-for"]` + `proxies:` Cloudflare/Render ranges
   (or a `cf-connecting-ip` parser). Without this step, step 3 is
   meaningless in production.

3. **Hammer rate limiting** — `{:hammer, "~> 7.5"}`;
   `Chronos.RateLimit` (`use Hammer, backend: :ets`) in the supervision
   tree; one plug before `Plug.Parsers` matching `/api/*` (generalize to
   #11's routes per the land ticket), with starting limits:

   | Key | Window | Limit | Rationale |
   |---|---|---|---|
   | `api:simulate:<ip>` | 60 s | 60 | interactive demo use is bursty but human-scale |
   | `api:export:<ip>` | 60 s | 10 | CPU-bound CSV (#10); or `hit/4` cost-weighting |
   | `api:scenes:<ip>` | 60 s | 20 | writes/deletes (#11); disk churn brake |
   | `api:global` | 60 s | 600 | **aggregate backstop** — bounds node CPU regardless of IP count |

   On `{:deny, ms}`: `429` JSON + `Retry-After: max(ceil(ms/1000), 1)` +
   halt. The global key is the piece that actually protects a single
   small VM from distributed low-and-slow abuse; per-IP keys provide
   fairness. Numbers are starting points — PR #9 digest notes load /
   concurrency tests are missing; calibrate with a load test before
   public launch.

4. **Defer**: per-IP WS connect throttling (plumbing ready via
   `connect_info`), Ranch alarms/telemetry for 429 and connection-cap
   visibility, Redis/distributed-ETS backends (only if the single-node
   posture changes).

Why this is the simplest sufficient answer: two small maintained deps
(Hammer, remote_ip), ~60 lines of wiring, everything else is config;
ETS keeps state in-node per the ADR (no Redis, no new infrastructure);
per-request cost stays bounded by #8/#9/#10/#11 caps, aggregate cost by
the limits above, connection/memory abuse by Cowboy/Ranch caps, and disk
abuse by #11's store caps plus the multipart scoping in §4.1.

## 8. Follow-ups / open questions

- Land ticket: ErrorJSON must cover 429 (new) and 413/415 (existing);
  rate-limit plug must be generalized to #11's `/api/scenes` routes
  alongside the reserved-field/JSON-sentinel plugs.
- Verify the Fly trust boundary at deploy time (IPv4-only bind reachable
  solely via Fly Proxy; `Fly-Client-IP` overwrite behavior — community
  report [17], confirm against live headers).
- Render proxy CIDR ranges for RemoteIp `:proxies` need an operational
  source (Cloudflare publishes ranges; Render's LB ranges are not
  documented as a stable trust boundary — prefer Fly if this is brittle).
- Calibrate limits with a load test (NIF DSP cost per request under
  concurrency is unmeasured — PR #9 digest).
- Consider JSON-only `Plug.Parsers` in the `:api` pipeline (§4.1).
- Jason 1.4.4 → 1.4.5 routine bump.

## Sources

Accessed 2026-11-20. Version-pinned where the lockfile matters.

1. Hex registry API, hammer (versions, dates, downloads, maintainers):
   https://hex.pm/api/packages/hammer · https://hex.pm/packages/hammer
2. Hammer README (backends, algorithms, fixed-window default, 2×
   boundary burst, per-key variant):
   https://hexdocs.pm/hammer/readme.html
3. Hammer Tutorial (hit/3-4, endpoint plug, 429 + Retry-After rounding,
   RemoteIp pairing): https://hexdocs.pm/hammer/tutorial.html
4. Hammer.ETS docs + v7.5.1 source (algorithms, clean_period 1 min,
   key_older_than 24 h in code, atomic update_counter):
   https://hexdocs.pm/hammer/Hammer.ETS.html ·
   https://github.com/ExHammer/hammer/blob/v7.5.1/lib/hammer/ets.ex
5. Hammer Distributed ETS guide (PubSub, eventually consistent):
   https://hexdocs.pm/hammer/distributed-ets.html
6. Hammer v7.5.1 mix.exs (Elixir ~> 1.14, no runtime deps):
   https://github.com/ExHammer/hammer/blob/v7.5.1/mix.exs
7. plug_attack README + Hex API (0.4.3 2021-08-09, throttle/storage,
   proxy warning, x-ratelimit headers; repo pushed 2025-04-18, README-only
   commit, 6 open issues):
   https://github.com/michalmuskala/plug_attack ·
   https://hex.pm/api/packages/plug_attack
8. plug_attack source (default block_action = 403 "Forbidden\n" + halt):
   https://github.com/michalmuskala/plug_attack/blob/main/lib/plug_attack.ex
9. Plug.Conn docs, `remote_ip` field ("defaults to peer's IP… meant to be
   overwritten"): https://hexdocs.pm/plug/Plug.Conn.html
10. RemoteIp docs + README + Hex API (1.3.0 2026-11-08; last-to-first
    algorithm; :headers/:parsers/:clients/:proxies; from/2; no-proxy
    warning): https://hexdocs.pm/remote_ip/RemoteIp.html ·
    https://github.com/ajvondrak/remote_ip ·
    https://hex.pm/api/packages/remote_ip
11. Render, "How Render handles DDoS attacks" (Cloudflare + LB edge,
    targeted L7 is the app's job, read x-forwarded-for, distributed
    store for multi-instance):
    https://render.com/articles/how-render-handles-ddos-attacks
12. cowboy_http manual, 2.14 (option defaults; asciidoc source at tag
    2.14.2): https://ninenines.eu/docs/en/cowboy/2.14/manual/cowboy_http/ ·
    https://github.com/ninenines/cowboy/blob/2.14.2/doc/src/manual/cowboy_http.asciidoc
13. cowboy_http.erl 2.14.2 source (max_keepalive default 1000 at init;
    "Protocol takeover" clause: switch_protocol → 101 → Protocol:takeover
    in the same process):
    https://github.com/ninenines/cowboy/blob/2.14.2/src/cowboy_http.erl
14. ranch manual, 2.2 (max_connections 1024 default, per connection
    supervisor, soft limit; num_conns_sups defaults to num_acceptors;
    alarms): https://ninenines.eu/docs/en/ranch/2.2/manual/ranch/ ·
    https://github.com/ninenines/ranch/blob/2.2.0/doc/src/manual/ranch.asciidoc
15. Fly.io docs, Request headers (Fly-Client-IP, XFF rightmost = app IP,
    spoofing caution): https://docs.fly.io/networking/request-headers
16. plug v1.19.1 source, lib/plug/parsers.ex (8 MB default, :length,
    query_string_length default 1_000_000, plug_status 413/415/400,
    POST/PUT/PATCH/DELETE only, per-parser opts, :body_reader, multipart
    temp files) + docs:
    https://github.com/elixir-plug/plug/blob/v1.19.1/lib/plug/parsers.ex ·
    https://hexdocs.pm/plug/Plug.Parsers.html
17. Fly community, "Security guidance: verifying Fly Proxy socket peers
    and forwarded headers" (**secondary** — Fly-Client-IP overwrite,
    IPv4-bind trust boundary):
    https://community.fly.io/t/security-guidance-verifying-fly-proxy-socket-peers-and-forwarded-headers/28891
18. Render community, "Accessing client IPs in a Node Express app"
    (**secondary** — XFF appended, not sanitized; CF-Connecting-IP):
    https://community.render.com/t/accessing-client-ips-in-a-node-express-app/36282
19. Jason docs, decode/2 options (no depth limit; :atoms DoS warning) +
    Hex API (1.4.4 2024-07-26 locked; 1.4.5 2026-05-05 latest stable):
    https://hexdocs.pm/jason/Jason.html · https://hex.pm/api/packages/jason
20. Phoenix v1.7.21 source, lib/phoenix/endpoint.ex (socket_dispatch
    compiled first; socket/3 websocket :timeout 60_000, :max_frame_size
    infinity; connect_info keys; :error_handler 429 example; drainer):
    https://github.com/phoenixframework/phoenix/blob/v1.7.21/lib/phoenix/endpoint.ex
21. LiveView v0.20.17 source, lib/phoenix_live_view.ex
    (get_connect_info/2 keys + mount-only availability; mount/3 return
    contract {:ok, socket} | {:ok, socket, opts}):
    https://github.com/phoenixframework/phoenix_live_view/blob/v0.20.17/lib/phoenix_live_view.ex
22. Jason v1.4.4 source, lib/decoder.ex (explicit-stack iterative
    decoder; integer digit limit 1024):
    https://github.com/michalmuskala/jason/blob/v1.4.4/lib/decoder.ex
23. plug_cowboy v2.7.5 source, lib/plug/cowboy.ex (transport_options
    defaults num_acceptors 100, max_connections 16_384; protocol_options
    passthrough):
    https://github.com/elixir-plug/plug_cowboy/blob/v2.7.5/lib/plug/cowboy.ex
24. cowboy_websocket manual, 2.14 (Ranch protocol; idle_timeout 60_000,
    max_frame_size infinity, compress false, validate_utf8 true; no
    connection-count option):
    https://ninenines.eu/docs/en/cowboy/2.14/manual/cowboy_websocket/
25. RFC 6585 §4 (429 semantics, Retry-After, no caching) and §7.2
    (dropping connections under attack):
    https://www.rfc-editor.org/rfc/rfc6585

Local evidence: `mix.lock`, `lib/chronos_web/endpoint.ex`,
`config/{config,dev,prod,runtime}.exs`, `docs/adr/0001-public-showcase-posture.md`,
`docs/DEPLOYMENT.md`, PR #9 digest
(`~/.hermes/cache/scratch/chronos-journey/pr-9-digest.md`).
