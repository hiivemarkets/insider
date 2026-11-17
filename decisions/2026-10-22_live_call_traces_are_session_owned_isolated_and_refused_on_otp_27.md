# Live call traces are session-owned, isolated, and refused on OTP 27

## Decision

The live `"calls"` component traces calls to named, already loaded functions
only inside a collector session, in an isolated OTP trace session
(`:trace.session_create/3`) owned by the session's call-trace collector. It
never calls the node-global `:erlang.trace/3` or `:erlang.trace_pattern/3`.
On OTP 27 the component is refused with `component_unavailable`
(`requires_otp_28`) before anything starts.

The trace ends with its collector session: at stop, at lease expiry, and when
an amendment replaces the segment. The cleanup receipt carries
`cleanup.call_trace`, and the session's outcome is `stopped` only when the
collector session's own check of the runtime's session inventory
(`:trace.session_info/1`) finds none of the traced functions still traced by
that trace session.

Limits follow `recon_trace`: a total count of calls (after which new calls
are not traced but the results of running calls are still recorded) and a
`{max, per_ms}` rate of trace messages (after which the whole trace stops),
plus a collector queue bound. Arguments, results, and reasons are rendered
only in the rich profile, through the rich renderer with credential masking
and a per-value byte cap; the strict profile collects none of them.

Preloaded runtime modules and Insider's own modules cannot be traced, and the
collector process is excluded from its own trace.

## Why

Agents used `recon_trace` in a comparison of debugging tools: its tracer
dies with the process that started it (a trace driven over `erpc` printed
nothing), its arguments are not size-bounded (about 710 KB for one trace),
and `recon_trace:clear/0` changes node-wide trace state that other observers
may share. Owning the trace in the session gives it the session's lease,
cleanup receipt, and disclosure boundary.

OTP 27 has trace sessions, but Insider's supported isolated mode starts with
OTP 28, as for the system monitor and the OpenTelemetry span capture; the
legacy node-global mode can clear another tool's flags, which a call trace
must never do. Refusing is simpler and more honest than a second, conflict-
prone mode.

## Consequences

- Call tracing is available only on OTP 28 and later nodes in development,
  test, and ci.
- A function must be loaded before the session starts; tracing does not load
  code or create atoms, and a module loaded later is not traced.
- Trace messages carry the full argument terms into the collector before they
  are rendered and capped; the count, rate, and queue limits bound how many
  arrive, not their size.
- Pausing and resuming a trace, per-process scoping, and match-spec filters
  are left to a later decision.
