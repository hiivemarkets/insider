# The OTLP receiver's renewal retry is capped by the lease

## Context

`2026-10-22_otlp_ingest_timeout_is_outcome_unknown_with_bounded_dedupe`
decided that a busy or timed-out renewal is retried once after a jittered
backoff of a quarter to a half of the renewal interval, and that the lease
therefore outlives a failed renewal and its retry. A later review showed that is
not always so: with the owner unavailable until 174 ms before lease expiry,
the renewal queued meanwhile timed out, and the retry's 500-1,000 ms backoff
fell after expiry, though a renewal sent at once would have succeeded.

## Decision

This supersedes the renewal clause of that record; the rest of it stands.

- The receiver keeps a conservative estimate of the lease deadline: the
  remaining lease reported by the last successful status or renewal,
  counted from before that call was sent.
- The single retry after a busy or timed-out renewal is scheduled after the
  jittered backoff, capped to leave 250 ms before that estimate, or with no
  delay when less than that remains. This is a scheduling rule, not a
  guarantee of when the call reaches the owner: timers can fire late, and a
  retry scheduled with no delay has no margin at all.
- The retry budget is unchanged: one retry, then the next scheduled
  renewal, with one renewal in flight at a time.
- The lease survives only when the owner answers the scheduled renewal or
  its retry before the lease expires. An owner unavailable for longer ends
  the session, and the receiver stops.

## Consequences

- A receiver no longer loses a lease it could have saved by waiting out a
  backoff, while a saturated owner still sees at most two renewals per
  interval.
- Recovery near the lease boundary depends on the owner answering in the
  time left; it is not promised.
