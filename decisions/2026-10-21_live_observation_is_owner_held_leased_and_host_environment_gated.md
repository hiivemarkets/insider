# Live observation is owner-held, leased, and gated by the node's own environment

## Decision

`Insider.Live` is the in-node, transport-agnostic surface for observing a
running node. Its contract is plain, distribution-safe data: string-keyed maps,
binaries, integers, booleans, `nil`, and lists. The only process identifier it
accepts is a subscriber pid, and it returns none. `Insider.Live.JSON` returns
the same results as canonical JSON. Errors use the closed `code` vocabulary in
`Insider.Live.Error`, and gaps use the closed reason vocabulary in
`Insider.Live.Batch`. The README documents both, and tests pin them to it.

A named `Insider.Live.Owner` under `Insider.Supervisor` owns the one collector
session, never the caller. Each session has a lease of 1,000 to 900,000 ms.
Reads and `renew/1` renew it. Status calls and subscriptions do not. Expiry
stops the session through `Insider.Collector.Session.stop/1` and retains the
cleanup receipt.

The node resolves its own environment. `config :insider, :environment` wins.
Otherwise a node launched by Mix maps its running Mix environment. A node with
neither is `unconfigured`. The owner exists, and a live session can start,
only for development, test, and ci. No caller-supplied value takes part in that
decision.

Event content leaves only through `Insider.Collector.Session.read_events/3`. It
redacts every event under the session's trusted classification policy. Logger
message content, report fields, and metadata are never collected for a live
session: the transport caller cannot supply the host disclosure policy that
would classify them, and the fixed policy only bounds and validates values.
For the same reason every live event crosses a fixed disclosure boundary
(`Insider.Live.Disclosure`): causality survives only as W3C-shaped
`trace_id`/`span_id` hex, binary supervisor ids are digested, and Telemetry
measurements are numeric values whose names come from a host allowlist
(`config :insider, :live_telemetry_measurements`), never from the caller.

The environment is checked on every observation, not only at start. When it
stops being allowed, the next observation call, subscription tick, or lease
check stops the active session through the normal cleanup path as `revoked`.
Status, stop, and unsubscribe stay available so cleanup can always complete.
Calls use bounded owner admission and absolute deadlines, so a request the
owner handles too late is refused before any side effect.

## Why

Agents reach a node through short-lived processes: a Tidewave `project_eval`
runs in a new process each time, and an `:erpc` call from an observer node ends
with the call. The collector session stops when its owner dies, so caller
ownership made every multi-step observation either impossible or dependent on
the caller parking a process. A supervised owner removes that dependency. The
lease restores the cleanup guarantee that caller death used to provide.

`Insider.Runtime` takes its environment from the trusted host caller. A live
transport caller is not that host, so it cannot assert one. Application
configuration is the explicit host statement. The Mix environment is the
implicit one for `iex -S mix` and `mix phx.server`, which is how development
servers run. A release has no Mix, so it is denied unless configured.

Rejected alternatives:

- Requiring `config :insider, :environment` everywhere. Insider is loaded into
  development servers that do not configure it, and setting the value from the
  eval would be the caller asserting its own environment.
- Starting the owner in every environment and refusing calls. The production
  artifact would then always run an extra process with session authority.
- Renewing the lease while a subscriber is alive. A forgotten long-lived
  subscriber, such as an IEx shell, would keep a session open indefinitely.
- Reading the Recorder under its admission lock, as `snapshot/1` does. Frequent
  live reads would make concurrent producers drop with `:contended`.

## Consequences

- Receipts are a public cursor. Exact eviction accounting depends on the
  Recorder assigning them consecutively on admission and inserting an entry
  before it publishes the new receipt. A Recorder change that breaks either
  property must change the gap contract.
- Losses without a receipt are counter deltas against the first issuance of a
  cursor. A second reader of the same cursor can see a loss reported twice, but
  no reader misses one.
- There is still one collector session per node. A live session and a
  host-started `Insider.Collector.Session` exclude each other.
- The Erlang-distribution observer node builds on this contract.
  Changing a key, code, or reason is a contract change for that transport.
- Live sessions cannot name Poller process targets. Polling registered
  processes needs its own protected-target review.
