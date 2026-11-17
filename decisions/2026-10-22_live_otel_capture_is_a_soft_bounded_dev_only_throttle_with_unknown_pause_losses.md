# Live otel capture is a soft-bounded, development-only throttle, and pauses are losses of unknown size

Supersedes, in part,
[`2026-10-22_live_otel_capture_observes_span_end_in_isolated_trace_sessions.md`](2026-10-22_live_otel_capture_observes_span_end_in_isolated_trace_sessions.md):
its second-session counting of undelivered spans (`otel_undelivered`) and
its count bound are replaced. Its capture boundary (the span-end trace in
an isolated session, no change to the node's processors or exporters), its
OTP 27 refusal, its absent byte bound, and its event and schema contract
stand.

## Decision

- The capture is throttled, not admission-controlled. A BEAM trace message
  is in the receiver's queue before the receiver can refuse it; refusing
  earlier would take a native tracer module, which Insider does not ship. A
  valve checks the collector every millisecond, pauses the trace while
  more than 1,024 span messages wait, and resumes at 256. A span received
  while more than 1,024 wait is shed before it is built.
- The bound is soft. Nothing enforces a count or byte maximum on what waits
  between two valve checks. The component runs only where live observation
  is allowed (development, test, and ci) and is accepted there as a
  development tool on that basis. A hard bound, an optional span processor
  the host configures, is a separate, later decision.
- Spans that end during a pause are not observed and are not counted.
  Every read and subscriber batch whose interval overlaps a pause reports
  it with a `nil` count: `otel_paused_ongoing` while the pause lasts when
  the batch is built, otherwise `otel_paused` when a pause started since
  the reader's baseline or was ongoing at it. The reader's baseline keeps
  the number of pause starts and the paused state.

## Evidence

- A counting session (`call_count`) switched on during pauses missed span
  ends concurrent with the switch: 8 producers ending 80,000 spans across
  a 5 ms pause left about 29,000 neither delivered nor counted (OTP 29).
  Subtracting a live call count from drained messages counted later
  arrivals as lost (a review measured 7,281 of 8,000). An unknown count is
  reported instead of a wrong one.
- Reporting only new pause starts missed losses later in one long pause
  (a review held ten span ends during a pause, and the second read had no
  gap). The overlap rule is tested with a pause held across several pull
  reads and a subscriber batch.
- Measurements, not limits (OTP 29, spans of two attributes): about 1,060
  waiting spans (590 KiB) at 38,000 spans a second; 19,987 (9.6 MiB) and,
  in a reviewer's rerun, 30,367 (15 MiB) at about 10 million spans a second
  from 8 producers; 80,000 queued with a delayed valve; 32 spans each
  holding a 1 MB attribute retained 32 MB with no pause.

## Consequences

- Under heavy span load most spans can be lost to pauses; every such read
  says so. Memory held by waiting spans is limited only in practice by the
  valve's reaction time and span size.
- The component must not be enabled outside development, test, and ci
  without the hard-bound mechanism.
