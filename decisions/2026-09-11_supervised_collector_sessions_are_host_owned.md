# Supervised collector sessions are host-owned and failure-isolated

## Decision

Add `Insider.Collector.Session` as the smallest opt-in composition boundary for
the already permitted Logger, Telemetry, Poller, and Recorder collectors. A
caller supplies a trusted `Insider.Runtime.HostPolicy` at startup and receives
an opaque local handle. The session binds the policy to its own PID, Recorder,
and selected components before Poller starts. Public inputs cannot override
that policy or the environment, authority, clocks, fixed Logger filter ID, or
fixed session Telemetry handler ID through nested options.

The root application remains `one_for_one`. It owns a dedicated
`Insider.Collector.Session.RootSupervisor` containing the Session Manager and
its DynamicSupervisor under `one_for_all`. A crash of either resets the other
and removes every temporary session child; unrelated present or future root
children are not coupled. Logger, Telemetry, Poller, Recorder, and the session
itself are temporary session-owned processes: a component failure degrades the
session and is recorded rather than restarted. There is one active session
globally because Logger's `:insider_logger` filter is global. The Manager can
reclaim only a provably stale Insider filter with a dead owned ETS inbox; it
does not remove a foreign filter using that ID.

Session startup is staged and carries the current ownership inventory through
each stage, so a Logger, Telemetry, or Poller failure cleans all earlier
resources. Staging and production are denied before that first side effect.
Owner death, explicit stop, kill, and unexpected termination use bounded
cleanup and return a receipt that distinguishes verified absence, inspection
unavailable, and residual presence. The inventory covers component processes,
the fixed Logger filter, session Telemetry handler, Recorder ownership, session
timers, monitors, and the Manager entry. It records policy-reference drop only:
an immutable policy is not a resource to release.

Terminal receipts are retained in Manager memory only, at a bound of 32. A
repeat control call inside that window returns the exact receipt. Evicted,
forged, or unknown handles return `expired_or_unknown_session`; after a
Manager/session-root crash terminal knowledge is intentionally lost. Health is
bounded and reports liveness separately from validated bounded component status
evidence, so it never calls liveness proof of correct collection.

## Consequences

- Legacy standalone `Poller` remains unchanged; the session is a new host API.
- Logger, Telemetry, and Poller are composable; `SystemMonitor` is excluded
  pending an explicit protected-subject ingress decision.
- This adds no network, Git, provider, repository, identity, assignment,
  authorization, mutation, deployment, or production-enablement authority.
- A later durable session lifecycle, shared cross-node ownership, persistence,
  or production/staging enablement requires a separate authority and retention
  decision.
