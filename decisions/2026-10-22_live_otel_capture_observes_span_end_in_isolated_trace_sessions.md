# Live otel capture observes the SDK's span end in isolated trace sessions

Date: 2026-10-22.

## Decision

- The Live `otel` component captures finished spans by tracing the return
  value of `otel_span_utils:end_span/2` (OpenTelemetry Erlang SDK 1.x span
  record layout) in an isolated `:trace` session. It never adds, replaces,
  or reconfigures a span processor, exporter, tracer, or sampler, so the
  node's own export configuration (including `traces_exporter: :none`) is
  unchanged.
- A second isolated session counts every span end (`call_count`). A valve
  pauses message delivery while more than 1,024 span messages wait, and the
  spans never delivered are counted exactly (`otel_undelivered`).
- The queue has a count bound, not a byte bound. A byte cap on the
  collector's `memory` plus its `binary` list was tried with
  `message_queue_data: :off_heap`: 200 spans each holding a distinct
  100,000-byte binary (20 MB) were queued at a suspended collector, and
  neither value grew, so the valve never paused. A check that cannot see
  the bytes would be a false bound. Instead each span is bounded when its
  event is built (name 256 bytes, status message 1,024, rendered attributes
  7,000, event 16 KiB), and the count bound limits how many wait.
- OTP 27 has only node-global tracing, where a process has one tracer and
  cleanup can clear another tool's flags; the component is refused there
  (`component_unavailable`, reason `requires_otp_28`).
- The span event (`otel.span`) is built by `Insider.Collector.Otel.Span`;
  span attributes live in the rich payload because Event v1 caps attributes
  at 4 KiB. `Insider.Live.trace/3` (`insider.live-trace/v1`) and
  `Insider.Live.timeline/2` (`insider.live-timeline/v1`) read the session
  through `events_since/3`, so the disclosure boundary applies.

## Consequences

- The capture costs one trace message per span in the ending process.
- Memory held by waiting spans is bounded only through their count: at
  most about 1,024 spans plus one 5 ms tick, each as large as the SDK made
  it (the SDK's own span limits apply: 128 attributes by default).
