# Rich rendering formats ISO values itself, bounds work in reductions, and isolates schema workers

## Context

`2026-10-22_rich_rendering_runs_no_application_code_and_keeps_ecto_redaction.md`
decided that rich rendering runs no application code in the emitter and keeps
Ecto `redact: true` through metadata collected by the live owner. Review then
showed three gaps in how that record said it would be done:

- Inspecting an ISO calendar value can still reach application code when one
  of its fields holds another struct, and a missing field could make the
  handler drop the whole event.
- A schema worker's failure could still deliver an unbounded term to the
  owner as a monitor `DOWN` reason, and the worker's heap cap ignored
  reference-counted binaries.
- A wall-clock deadline per payload made rendering fail under machine load
  without bounding work any better.

This record supersedes the parts of that record that describe calendar
rendering, the schema-collection mechanism, and the per-payload deadline. The
rest of it stays in force.

## Decision

- **ISO values are formatted by Insider.** `Date`, `Time`, `NaiveDateTime`, and
  `DateTime` values in `Calendar.ISO` render as sigil text built by Insider,
  only when every required field is present and an in-range scalar. Nothing
  calls `inspect` or a `Calendar` function on caller data. Any other value,
  including one with a missing field, renders field by field.
- **The rendering budget is counted in reductions.** Each payload has a work
  budget of 2,000,000 reductions (about 40 ms of one scheduler); past it,
  rendering fails closed to `…[time_limit]`. Reductions do not depend on
  machine load, so the bound is the same in tests, under load, and on a
  developer laptop.
- **Schema workers can send only a validated list.** At session start the
  owner asks each loaded `__schema__/1` module in its own process:
  - the worker catches every error, throw, and exit from the accessor and
    always sends a freshly built list of at most 64 atoms, or `:invalid`;
  - replies go to a process alias that is deactivated at the 200 ms
    deadline, so a late reply is dropped by the runtime, and stragglers are
    killed;
  - workers are neither monitored nor linked, so no exit reason, however a
    worker dies, is delivered to the owner;
  - each worker's memory cap (65,536 words) counts reference-counted
    binaries, so building or holding a large term or binary kills it.

## Why

Formatting known scalar fields is simpler than proving that `inspect` cannot
reach application code, and it degrades to the bounded field walker instead of
failing. Counting work rather than wall time keeps the bound meaningful while
making results reproducible. With no monitor and an alias, the only term a
schema can make the owner copy is the list the worker validated, which closes
the class of "unbounded reply" problems rather than each instance.

## Consequences

- A schema whose worker dies, is killed, or exceeds its memory cap is simply
  absent from the table and falls back to credential-name masking; the owner
  waits for the rest until the 200 ms deadline.
- The 40 ms figure is an approximation; the contract is the reduction count.
- The memory cap counts shared binaries but cannot account for memory a
  schema allocates in other processes it starts.
