# Live digest reads a fixed window, and the observer prints lean, compact, or full events

## Context

Agents answered "what is wrong right now" by paging `events_since/3` and
joining events with `jq`: counts, crash-loop periods, latency, error
groups. Each event's envelope was about 1.1 KB, mostly constant or null, and
raw Telemetry durations had no unit or wall time.

## Decision

- **`Insider.Live.digest/2` returns `insider.live-digest/v1`.** It folds a
  window of the session through the same `events_since/3` path and
  disclosure boundary, so it never shows more than a read would.
- **The window is fixed when the digest starts.** It runs from `"since"`
  (an integer cursor, or `"latest-N"`) to `upto`: for `"latest-N"` the newest
  receipt the lookup saw, otherwise the first read's `next_receipt`. Later
  reads ask only for what is left of the window, events past `upto` are left
  out even when a read returns them, `next_cursor` never passes `upto`, and a
  read that ran past `upto` counts its receipt-range losses only within the
  window (oldest receipts first). A digest therefore never consumes receipts
  that belong to the next one.
- **One budget.** `bounds.digest_budget_ms` (3,000 ms) starts before
  anything is read and bounds the lookup and every read; each owner call gets
  only what is left (plus the 200 ms outer margin every owner call has). No
  time before the first read is `timeout`. A window not read to `upto` is
  `complete` `false` with `stopped_by` (`deadline`, `no_progress`, or a later
  read's error code) and a `next_cursor` to continue from.
- **Diagnoses need evidence.** The human summary says a p95 near 5 s is
  "consistent with GenServer.call timeouts" only when a failing event of that
  kind, or a failing Logger event, discloses the exit
  `{:timeout, {GenServer, :call, _}}`; the counts are in each latency row's
  `call_timeouts` and in `logged_call_timeouts`. Otherwise only the latency is
  stated.
- **Observer output formats for `events` and `watch`.** `--format json` (the
  default) drops each event's constant fields (`schema`, `node`, `boot_id`,
  `clock_id`, `source_instance_id`, `source_sequence`, `monotonic_time`,
  `authority`) and its null or empty ones; `--format full` prints the target's
  document unchanged; `--format compact` prints one line per event and a `#`
  line per batch (cursors, truncation, disclosure profile, gaps, filtered),
  showing of a rendered conn only method, path, route, and status and naming
  an HTML page instead of printing it. Errors are always JSON. The read bounds
  (`limit`, `max_bytes`) are unchanged and still count full events in the
  node.
- **Time and units.** Every live event carries `wall_time`; disclosed
  integer Telemetry time measurements are repeated in microseconds under
  `attributes.durations_us`, derived after the disclosure boundary. Batches
  carry `disclosure_profile`.

## Consequences

- A digest is a snapshot: events emitted while it reads appear in the next
  digest or read, not this one.
- A reader that relied on constant envelope fields in the observer's default
  output passes `--format full`. The `Insider.Live` and `Insider.Live.JSON`
  results are unchanged apart from the added fields.
