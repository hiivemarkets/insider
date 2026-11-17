# Live call trace ingress is bounded by a measuring inlet

## Context

`2026-10-22_live_call_traces_are_session_owned_isolated_and_refused_on_otp_27.md`
accepted that "trace messages carry the full argument terms into the
collector before they are rendered and capped; the count, rate, and queue
limits bound how many arrive, not their size". Review showed that this
leaves the target's memory unbounded: one queued call holding a
200,000-element list cost the collector 3.2 MB, and a queued 16 MiB shared
binary was invisible to every per-process measure, because a message waiting
in an off-heap mailbox shows in neither the process's memory nor its binary
list. This record supersedes that consequence; the rest of the earlier
decision stands.

## Decision

Call-trace ingress is bounded in bytes before the collector reads it:

- In the strict profile the trace session uses the `arity` flag, so a call
  message carries `{m, f, arity}` and no argument leaves the calling process.
- Trace messages are delivered to an inlet process, not the collector. The
  inlet measures each message with `:erlang.external_size/1`, which counts
  every shared binary it references, and forwards it with its size. The
  bytes forwarded and not yet handled by the collector are counted; a
  message that would take them above the budget (8 MiB) is dropped, the
  inlet removes the trace itself, and the trace records `call.stopped` with
  reason `ingress_bytes`. Dropped messages are counted as shed.
- The collector and the inlet are excluded from the trace session before
  any function pattern is set, so neither can trace itself.
- The collector's heap, shared binaries included, is limited to 64 MiB (at
  least eight times the budget) with `kill: true` as a last resort.

## Why

A periodic check of the collector's memory cannot see what an off-heap
mailbox holds, and an on-heap mailbox shows shared binaries only after the
messages sent concurrently into heap fragments are merged by a collection
(measured: 2 of 40 MB visible before a forced collection). Measuring each
message once, as it is read by a process that does nothing else, counts
every byte, including shared binaries, and lets the trace be removed while
the collector is busy or suspended.

## Consequences

- Not bounded: messages waiting in the inlet's mailbox before it reads them,
  and one message larger than the budget, which the runtime copies once
  before the inlet drops it.
- Measuring adds the cost of `external_size/1` per traced message (linear in
  the term, constant for a binary).
- A heap-limit kill ends the collector session as `cleanup_incomplete`.
