# Telemetry dead-handler oracle is exact-event and value-free

## Context

The candidate inventory ranked a real serialized test module for global
Telemetry capture. The module called `:telemetry_test.attach_event_handlers/2`
in each setup, discarded the returned reference, and registered no detach
callback. A bounded prototype observed three passing tests increase the exact
event's dead-destination handler count from zero to three, while a real
Telemetry cleanup control left the same count at zero.

Two event atoms did not exist when the adopter's `test_helper.exs` ran. Creating
atoms from environment input would make a diagnostic artifact an atom-table
mutation surface. Scanning every event would expose unrelated handler state and
make the observer cost depend on the entire target VM.

## Decision

Ship a fixed Lab-only ExUnit artifact for one comma-separated event path. Each
segment is bounded and resolved only with `String.to_existing_atom/1`. A missing
atom proves that the initial exact-event handler count is zero; resolution is
retried after test-file loading, so the artifact creates no atoms while still
observing events first introduced by the selected code.

Telemetry's public lookup treats the selected event as a prefix. Inspect that
bounded result but count only descriptors whose event equals the selected event,
whose function is `:telemetry_test.handle_event/4`, whose configuration contains
a PID-valued `dest_pid`, and whose destination is dead. Descendant descriptors
therefore affect the lookup bounds even though they cannot affect the count.
Emit only before/after counts, delta, status, the caller-selected event strings,
bounds, and limitations. Do not emit or fingerprint handler IDs, PIDs,
functions, function environments, configuration, payloads, measurements, or
metadata.

Run each public exact-event lookup in a monitored worker with a one-second
deadline and 262,144-word maximum heap. Refuse to interpret more than 1,024
returned handlers. Timeout, worker failure, or excess handlers is inconclusive.

The caller must install the reviewed fixed path explicitly in
`test/test_helper.exs` after the intended baseline, run one selected test
command, then immediately restore the exact prior helper and verify the
worktree. The artifact never selects or starts a test command.

## Consequences

- An agent can confirm the newly observed dead-handler defect class without a
  bespoke probe or disclosure of handler/event contents.
- The oracle deliberately does not diagnose arbitrary Telemetry handlers,
  closures that capture dead PIDs, live destinations, or all-event growth.
- Handler enumeration is not an atomic snapshot; concurrent attachment and
  detachment can affect the count.
- Descendant handler volume can make the prefix lookup inconclusive even when
  the selected exact event has few handlers.
- A count change is bounded observation, not proof of causality, production
  impact, or repair correctness. The caller still binds test and revision.
- Compile or test-file load failure can prevent the after-suite callback;
  missing output is infrastructure failure, never clean evidence.
- Generic command orchestration, cross-run receipts, automatic defect promotion,
  and other handler classes remain separate evidence-gated work.
