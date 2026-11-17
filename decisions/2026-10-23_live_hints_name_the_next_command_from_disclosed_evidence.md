# Live hints name the next command from disclosed evidence

## Context

Usability testing found three gaps. An agent never found the call trace and
left Insider for recon_trace when a crash report was cut at its depth limit.
Agents lost hundreds of events to Recorder eviction without using Logger
summaries or the Recorder's shares. The human digest blamed the application
for Insider's own Recorder table and omitted the port leak.

## Decision

- A digest and an events batch carry `"hints"`: the next command, as an
  observer `command` (with `$N` for the target flags) and as `amend/2`
  `options`, with a `kind`, a `reason` with the counts it rests on, and the
  `evidence`. Hints are built only from what the read disclosed and from
  the session's own configuration, so they never reveal more than a read.
- A call-trace hint names a function only from evidence: the first
  application frame of a crash's or exception's disclosed stack that
  `--calls` would accept (never a runtime, preloaded, or Insider module),
  else, for a supervised child that keeps crashing, its exported GenServer
  callbacks. It keeps the session's components and traced functions,
  because an amendment's list options replace the whole list. Before OTP 28
  it is `trace_calls_unavailable`, with the recon_trace call instead of a
  command.
- An eviction hint is given only for a share group over its share whose
  entries the Recorder evicted (`recorder.sources`), and names the change
  that stops that group's flood. The owner keeps the Recorder's per-source
  usage from each read (the collector's read result carries it, read
  lock-free), and a digest asks for it with the session configuration in one
  call that does not wait for collector health, within the digest budget.
- The digest's `vm.target` and `--human` VM line show the node's
  processes, process memory, and ETS without Insider's own share; a total
  the Poller did not split says it includes Insider's.

## Consequences

- An amendment starts a new Recorder segment, so per-source eviction counts
  start again at 0, and a digest after it shows whether the hint worked.
- A hint is a suggestion: applying it is the agent's decision, and the
  command is printed, never run.

## Addendum (review)

- Every value a hint puts in a `command` is single-quoted (`'\''` for a
  quote inside), and a Logger origin is offered only when the session would
  accept it as a rule, so no disclosed value can become shell syntax.
- A source floods when it holds more than its share of events or of bytes;
  `raise_capacity` is offered only for event floods, since the byte bound is
  fixed.
- A hint whose amendment would pass a list option's limit (`calls`,
  `logger_summaries`, `telemetry_summaries`) is given without a command and
  says the limit is reached, rather than printing an amendment the session
  would refuse.
- The crash recipe reads call exceptions from the amendment's marker receipt,
  never from `latest`.
