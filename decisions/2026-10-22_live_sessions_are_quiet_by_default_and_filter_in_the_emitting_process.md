# Live sessions are quiet by default and filter in the emitting process

## Decision

- **Quiet by default.** A live session started without options records
  Logger events at `warning` or more severe, OTP SASL-domain reports at
  `info` or more severe, the node's discovered Ecto query events over 100 ms,
  every Phoenix request (`phoenix.endpoint.stop`), and every Telemetry error.
  It records nothing that Oban's own machinery emits. Callers widen it
  explicitly (`logger_level`, `telemetry_min_duration_ms`,
  `exclude_origins: []`).
- **Record-time filters run in the emitting process, first.** The Logger and
  Telemetry handlers consult a compiled gate before any other work. A
  dropped event costs one decision and one counter increment: no sequence
  number, no handler statistic, no normalization, no inbox write. The gate
  lives in `:persistent_term`; handler configurations carry only its key.
- **Origin is decided in the node and never disclosed.** Origin rules read
  the emitting process's initial call, Logger metadata, and Ecto's telemetry
  options only to decide. Oban's origin is `Oban.Repo`'s `oban_conf`
  telemetry option and Oban's own processes, never job execution.
- **Summaries are fixed-size histograms.** A summarized event updates
  counters in the emitting process; the collector records one summary event
  per interval with samples, with percentiles as histogram bucket upper
  bounds (at most 1/16 high).
- **Views are per reader and never change what is recorded.** Read-time
  views narrow one reader's batches over the one recorded stream.
- **Silence is never ambiguous.** Every batch reports filtered counts per
  filter: record-time since the reader's cursor was issued, read-time for
  its own view.

## Why

A development node of a real application emitted about 16 events per second
at idle, almost all of them a job library's polling queries. Recording them
costs work in every emitting process and evicts useful history from the
bounded Recorder in a few minutes, while an agent debugging the application
rarely cares about them.
Dropping at the source keeps the cost in the emitting process to a decision,
and reporting what was dropped keeps the agent from mistaking a quiet session
for an idle node. Several agents may share one node, so narrowing for one
reader must not hide events from another: views are read-time and per
reader, and record-time filters are a session property every reader sees in
`"filtered"`.

## Consequences

- A session started with the old defaults sees fewer events; tests and
  callers that need every log line or query pass `logger_level: "debug"` or
  `telemetry_min_duration_ms: 0`.
- Ending a session erases its gate from `:persistent_term`, which schedules
  one global literal-area check per session stop. Live sessions are
  development tooling, so this is accepted.
- Module namespace rules are resolved at start; modules loaded later are not
  matched until the next session.
