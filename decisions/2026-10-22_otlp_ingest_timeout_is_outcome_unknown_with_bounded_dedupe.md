# An OTLP ingest timeout is outcome unknown, and retries are protected by a bounded dedupe

## Context

`Insider.Live.ingest_spans/2` forwards spans from the live owner to the
session's otel collector, a separate process. A review showed that a call
the collector has taken can still be recording when its caller stops
waiting: no deadline check in one process can make the other's `timeout`
reply definitive. The ingress decision of the same day
(`2026-10-22_otlp_ingress_is_a_loopback_lab_receiver_that_only_the_target_masks`)
stands; this record adds the timeout, dedupe, and retry contract it did not
cover.

## Decision

- A `timeout` from `ingest_spans` means the outcome is **unknown**: some,
  all, or none of the spans may be recorded. A call the collector takes
  after its deadline is still refused before any span or counter changes.
- Ingest is idempotent per `{trace_id, span_id}` within the session, for
  as long as the id is in the collector's FIFO seen-set of the last 16,384
  spans it recorded from ingest (`:ingest_seen_max`). A span already
  recorded is counted as `duplicate` and not recorded again. An id that
  falls out of the set is forgotten, counted as `seen_evicted`, and a later
  retry of that span is recorded again. Spans the node's own SDK ends are
  not deduplicated.
- The Lab receiver retries a chunk once after a `timeout` (from the target
  or the observer's own call bound). If that also times out, it answers the
  exporter `503 target_timeout`, reports a `refused` line, and keeps
  receiving; the exporter's own retry is then subject to the same dedupe.
- Lease renewal from the receiver is synchronous, so at most one renewal is
  in flight. A renewal refused as `busy` or timed out is retried once after
  a jittered backoff of a quarter to a half of the renewal interval, then
  left to the next scheduled renewal; renewals run at a third of the lease,
  so the lease outlives a failed renewal and its retry.

## Why

Making a cross-process timeout definitive would need a two-phase commit
between the owner and the collector for evidence that is development-only;
idempotent ingest gives retries the safety that matters at a fraction of
the cost. The seen-set is bounded because session memory must be; 16,384
ids covers many exporter batches (512 spans each) and its loss is counted,
not hidden. Retrying renewal immediately turned a saturated owner into a
distributed busy loop (a review measured 16,810 renewal calls in 3 s); one
backed-off retry keeps the lease alive without adding load when admission
is refusing it.

## Consequences

- Callers must treat `timeout` as "retry with the same spans", and must
  read `seen_evicted` before assuming a retry cannot duplicate.
- A longer outage than the seen-set can span can produce duplicate span
  events; `seen_evicted` shows when that protection has been lost.
- Changing the bound, or deduplicating SDK spans, needs a new decision.

## Clarification (review, 2026-10-23)

- The seen-set belongs to one otel collector, not to the session. Every
  amendment seals the collector and starts a replacement, and so does an
  amendment rolled back into the previous options, so every amendment
  resets dedupe: a span ingested before it is recorded again after it, and
  `seen_evicted` does not count the reset. Session-wide dedupe is not
  provided. A caller retrying across an amendment must expect a duplicate.
- A `busy` ingest is the owner's admission refusing the call before it
  runs: no span of that chunk was recorded. The receiver answers
  `503 target_busy`, without retrying at once, and keeps receiving; only
  errors that mean the session cannot accept spans stop it.
