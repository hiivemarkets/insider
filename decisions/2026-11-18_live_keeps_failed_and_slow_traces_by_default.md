# Live keeps failed and slow traces by default

## Context

`2026-10-25_live_keeps_mutation_traces_by_default_and_names_the_graphql_client.md` kept the traces of mutation requests by default, so that `trace` found them without `--retain-traces`. In testing, a newcomer agent reproduced a failing request and then ran `trace` with no extra flags. About a minute of normal traffic had evicted thousands of Recorder events, and the trace came back empty (`0 spans`, `Lost: evicted 3014`). Only after `amend --retain-traces 5` and a second run of the request was the trace complete. The request was large (about 900 spans), and the 1,024-event lookback could not have held its early events until its stop arrived.

## Decision

- A live session keeps three kinds of trace by default, each for a named reason:
  - `failed`: a traced event with severity `error` or `critical` (an exception, a 5xx, a failed span, GraphQL errors, a Logger error);
  - `slow`: a traced Telemetry event whose `duration` or `total_time` measurement, or an OpenTelemetry span whose `duration_us`, is at least 500 ms;
  - `mutation`: unchanged.
- `failed` and `slow` are on for a session with the logger, telemetry, or otel component. `mutation` stays on with the telemetry component. No option or flag changes.
- Each reason has its own pool of at most 16 traces, the least recently active let go first. A trace with several reasons takes the strongest (mutation, then failed, then slow) and moves to that pool; it is never demoted.
- Past the store's bounds (4,096 events, 4 MiB), slow traces go first, then failed, then mutation traces, then automatic traces, then explicit pins' oldest events. An automatic trace that turns notable stays automatic until the `retain_traces` pool lets it go, and only then takes its reason.
- The lookback that supplies a notable trace's earlier events grows from 1,024 events and 1 MiB to 4,096 events and 4 MiB, the store's own bounds. Retention therefore holds at most 8 MiB on the target.
- `trace`'s `retention.pinned` is `failed` or `slow` for these traces, and its text says `Retained: kept because it failed` or `Retained: kept because it was slow (≥ 500 ms)`. `status.retention` adds `keep_failed_and_slow`, `failed_traces`, `slow_traces`, `failed_traces_max`, `slow_traces_max`, `slow_trace_ms`, and `lookback_bytes_max`. Every existing field stays; `mutation_lookback_max` now bounds the lookback for every reason.

## Why

An agent that reproduces a problem almost always reads a trace that failed, was slow, or ran a mutation. Keeping those by default turns the common first `trace` call from an empty result into evidence, without asking a newcomer to know about `--retain-traces` before the problem happens.

Separate pools stop one kind from costing another: a background job that fails every second fills only the `failed` pool and cannot push out a mutation trace. Slow goes first past the store's bounds because it is the weakest and most common signal. The 500 ms threshold is fixed rather than an option: the codebase had no existing slow threshold, an option would be one more thing a newcomer must know, and the slow pool is bounded anyway. A larger lookback is what lets a large request survive until the event that makes it notable, which for a span tree is usually the root span, exported last.

Rejected: keeping every trace by default (unbounded by intent, and it would evict the traces that matter), and a per-session threshold option (no evidence that a fixed one is wrong).

## Consequences

- Every session with the logger, telemetry, or otel component sweeps retention on the owner's tick, even with `retain_traces` 0.
- Retention memory on the target can reach 8 MiB (store plus lookback), up from 5 MiB.
- A 17th concurrent trace of one reason lets the oldest of that reason go, counted in `evicted_traces`. Events older than the lookback when the notable event arrives count as the trace's `lost`.
- A slow request whose only timed events are filtered out, or whose time measurements are not collected, is not kept as slow.
- `retention.pinned` values `failed` and `slow`, and the new `status.retention` fields, are public contract.
