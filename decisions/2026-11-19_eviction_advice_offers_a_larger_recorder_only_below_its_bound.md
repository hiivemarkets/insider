# Eviction advice offers a larger Recorder only below its bound

## Decision

- The digest's `evicted` anomaly takes its advice from the digest's hints
  and never states a Recorder size itself. It offers `raise_capacity`'s
  command only when that hint exists, so only while the session's
  `max_events` is below its bound. Otherwise it gives the command of the
  first flood hint that has one and names that hint's family (a Telemetry
  kind, a span name, a Logger origin, or the Poller), or, with only
  `record_less`, a `mark` command. Without the session's configuration
  (no hints) it gives `status`.
- `raise_capacity` offers a value strictly larger than the session's
  `max_events` and at most the bound, read from the table that
  `Insider.Live.Options.start/1` validates with.
- `hints[].kind` gains two values:
  - `record_less`, given for a flood that a larger Recorder cannot help
    (`max_events` is at its bound, or the flood is over a byte share). It
    has no command. Its `evidence` has `max_events`, `max_events_bound`,
    `evicted` per share group, and `dominant` (`source`, `name`, `events`:
    the family that evicted most in the window, `name` `null` when the
    window disclosed none). Its reason lists the flags that record less and
    how to keep one request.
  - `reduce_otel`, given for a span flood with the `otel` component: a
    higher `otel_min_duration_ms` (10 ms from 0, else twice the current
    value, at most the option's bound), with `evidence.span`,
    `evidence.events` and `evidence.otel_min_duration_ms`. At the bound it
    has no command.
- The evidence fold counts span names (at most 64 distinct names) only to
  name them in these hints. A name comes only from an event the read
  disclosed, and it never enters a `command`.

## Why

A sweep at `--max-events 4096` evicted most of its requests, and the
anomaly said to amend to `--max-events 4096`, the session's value and the
most allowed, so following it changed nothing. The agent had to guess which
of its telemetry and spans to stop recording. The anomaly had a fixed
command and no view of the session's configuration, while the hints
already had both. So the anomaly now reads the hints rather than duplicating
their reasoning. A command-less `record_less` hint was chosen over silently
dropping the advice at the bound, because "a larger Recorder is not
possible" is the fact the agent was missing.

## Consequences

- A consumer that switches on `hints[].kind` sees two new values. Existing
  kinds keep their fields.
- A digest whose session is at the bound and floods carries one more
  `Next:` line, `record_less`, after the source hints.
- How large the Recorder may be is unchanged; changing its bound or the
  per-source shares is left to a later decision.
