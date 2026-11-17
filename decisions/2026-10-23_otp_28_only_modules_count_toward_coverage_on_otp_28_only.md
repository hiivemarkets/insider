# OTP-28-only modules count toward coverage on OTP 28 and later only

## Context

Insider supports Elixir 1.17 on OTP 27, and CI runs `mix test --cover` with a
90% floor on Elixir 1.17/OTP 27, 1.19/OTP 28, and 1.20/OTP 29. The call-trace
component and the otel span capture need isolated trace sessions
(`:trace.session_create/3`, OTP 28). On OTP 27, the call-trace collector is
refused before it starts, and the tracing backends only report
`requires_otp_28`. Their lines therefore cannot run on OTP 27. When the call
traces and the otel capture were combined in one batch, they pulled the OTP 27
total down to 89.13%, though each part had passed alone and every module was
tested on OTP 28+.

## Decision

Below OTP 28, the coverage total leaves out the modules whose work cannot run
there. These are the modules that open an isolated trace session and have no
OTP 27 mode, and the collectors whose start is refused below OTP 28. Today they
are:

- `Insider.Collector.Calls`;
- `Insider.Collector.Calls.Tracing`;
- `Insider.Collector.Otel.Tracing`.

`mix.exs` lists them (`otp_28_only_modules/0`) and adds them to
`test_coverage[:ignore_modules]` only when `System.otp_release()` is below 28.
On OTP 28 and later they count. The 90% floor is unchanged and applies to every
run.

A module that does real work on OTP 27 stays counted on every release, even
when part of it needs OTP 28. This covers the otel collector, whose ingest-only
mode runs everywhere, and the system monitor backend, which falls back to the
legacy node-global monitor. `Insider.Collector.Calls.Trace` (pure call pairing)
also stays counted.

A guardrail test derives the list from the source and fails when the list in
`mix.exs` differs. The derived list is the `:trace.session_create` callers
without an OTP 27 mode, plus the modules whose start requires
`Tracing.preflight()`.

## Why

A floor that fails because a runtime cannot execute a feature measures the
runtime matrix, not the tests. The rejected alternatives:

- **Lowering the floor** would hide real gaps elsewhere.
- **Moving the gate to one OTP 28 job** would stop measuring the OTP 27 consumer
  floor at all.
- **Hand-picking low-coverage modules** would erode the gate a module at a time.
  Deriving the list from the code keeps it at exactly what OTP 27 cannot run.

## Consequences

- The OTP 27 total measures the code that OTP 27 can run. OTP 28 and OTP 29
  carry the evidence for the excluded modules.
- If the OTP 28+ jobs stop running, those modules lose all coverage evidence.
- A new module that opens an isolated trace session or refuses to start below
  OTP 28 fails the guardrail until it is classified. One with an OTP 27 mode
  must show that mode in its source.
- Dropping OTP 27 support removes the exclusion. Excluding anything else needs a
  new decision.
