# Live call trace ingress has a documented soft bound

## Context

`2026-10-22_live_call_trace_ingress_is_bounded_by_a_measuring_inlet.md`
claimed that measuring each trace message in an inlet "counts every byte,
including shared binaries". Review showed two gaps: `:erlang.external_size/1`
counts a sub-binary's own bytes, not the larger binary it keeps alive, and
the inlet's own mailbox is unbounded. BEAM trace delivery cannot be
admission-controlled without a native tracer: a message is copied to the
tracer before any Erlang code sees it. The OpenTelemetry span capture
accepted the same limit as a documented, development-only soft
bound with measured worst cases. This record supersedes the earlier record's
claim that every byte is counted; its inlet design stands.

## Decision

Call-trace ingress keeps the inlet and has a soft byte bound, documented in
README "Call traces" with measured worst cases:

- The strict profile traces with the `arity` flag, so no argument is copied;
  it is the safe default.
- The inlet charges each message its external size plus, for a top-level
  binary argument or result, the bytes of the binary it keeps alive beyond
  its own (`:binary.referenced_byte_size/1`). Nested sub-binaries are charged
  only their own bytes.
- The inlet's mailbox, before it reads a message, is not bounded.
- Flush and stop drain through the inlet: the inlet requests the runtime's
  delivery marker and answers the collector after forwarding everything
  before it. A stop whose drain times out counts what the inlet still holds
  as `undrained` (gap `calls_undrained`).

No further machinery (a native tracer, deep sub-binary scans, or mailbox
admission) is built for these limits.

## Consequences

- Measured on OTP 29 under load: a tight-loop burst of 400,000 calls from
  8 processes in about 60 ms stopped the trace at once, but the inlet's
  mailbox peaked at about 100 MB in rich (49 MB in strict) before draining.
- Call tracing stays development and test tooling; the README tells agents to
  avoid functions called in tight loops and to prefer the strict profile.
- A native tracer or a sampling match specification could make the bound
  hard; that is left to a later decision.
