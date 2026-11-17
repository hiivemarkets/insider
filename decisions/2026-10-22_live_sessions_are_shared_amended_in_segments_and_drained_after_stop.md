# Live sessions are shared, amended in segments, and drained after a stop

## Context

A node has one live session, and agent testing showed agents sharing it
badly. One agent's `stop` destroyed about 2,400 receipts another agent had
not read, with no warning, because `status` could not say who was reading.
Adding one measurement meant a stop and a start, which lost the history.
Concurrent `mix insider.live` calls from one checkout waited 5 to 10 s on
Mix's build lock. The collector session (`Insider.Collector.Session`) fixes
its components, Telemetry policy, and Recorder when it starts, and only one
can run on a node at a time.

## Decision

- **Named readers.** Reads and subscriptions take an optional `"reader"`
  name. The owner keeps up to 16, each with its cursor and when it was last
  seen, and `status/1` lists them. Unnamed reads are not tracked.
- **Protected stop.** `stop/2` refuses with the new closed code
  `readers_active` while another named reader read within 30 s or is
  subscribed, unless `"force"` is set. Only named readers count, because an
  unnamed reader cannot be told apart from the stopper.
- **Drain window.** Before its collectors stop, a stop copies the
  Recorder's retained events, already through the session's redaction pass,
  into the owner. The stopped session stays readable through
  `events_since/3` for 120 s. Disclosure still applies at read time, and the
  two most recent stopped sessions stay readable. Expired and revoked
  sessions are not kept: an expired one had no reader, and a revoked one may
  disclose nothing more.
- **Amendment in segments.** `amend/2` does not change running collectors.
  It copies the running segment into the same archive, stops the collector
  session, and starts a new one with the merged options. The new session
  keeps the live session's id, readers, subscribers, and baselines. Live
  receipts stay consecutive: each segment's receipts are offset, and its
  cumulative loss and filter counters are added to those its predecessors
  ended with. A `live.session_amended` event takes the receipt between
  segments. Every view shows it, and it reports `uncollected_ms`, the time
  no collector ran. If the copy cannot finish in time, nothing changes. If
  the new options cannot start, the previous ones start again
  (`amend_failed`, rolled back). If they cannot either, the session ends
  and stays readable.
- **Handoff.** `handoff_record/1` (observer `handoff`) is a read-only record
  of what another agent needs to continue the session. It is not named
  `handoff/1`, the name the production-artifact boundary reserves for a
  host delivery client.
- **No build lock.** The Lab escript (`insider-lab live`) is the documented
  observer for concurrent agents. Every observer document reports the
  commit its Insider was built from (`installation.insider_commit`).

## Why

Changing a running collector session's components or Telemetry policy in
place would reach into the Logger, Telemetry, and Poller collectors and the
session's cleanup receipts, which are its safety boundary. Restarting
underneath, with an archive, needs only the owner and reuses the normal
start and stop paths. The same archive serves the drain window, so one
mechanism covers both. The cost is a short pause in collection at each
amendment. That pause is reported, never silent.

The escript avoids the lock because it never starts Mix. The alternatives
were worse. A long-lived observer daemon would hold a distribution identity
and the cookie between commands. `MIX_OS_CONCURRENCY_LOCK=0` would let
concurrent compiles race in one build directory.

## Consequences

- The owner holds up to 4,096 archived events (8 MiB) for an amended session
  and for each of two stopped sessions during their windows. Older archived
  events read as `evicted`.
- Events emitted while an amendment restarts the collectors are not
  recorded. Agents learn this from the amendment event.
- A stop now costs one copy of the Recorder, read through the collector at
  up to 1,000 entries per read and bounded by the request's budget. If the
  copy fails, the stop still proceeds, without a drain window.
- The escript must be rebuilt after the checkout changes. A stale escript's
  `--load` pushes its own, older Insider.
