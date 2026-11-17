# Candidate oracle hints are static data

## Context

`2026-09-12_candidate_targets_are_static_inert_hints.md` records that a
candidate target does not select an oracle. Since then two fixed Lab-only
oracle artifacts exist, each validating a small set of environment inputs
that are a direct re-encoding of an identity the scanner already emits: an
application and key for `insider.application-env-oracle/v1`, and a
comma-separated atom path for `insider.telemetry-dead-handlers-oracle/v1`.
The inventory also did not name the event captured by
`:telemetry_test.attach_event_handlers/2`, the call pattern that motivated the
Telemetry oracle, so an agent had to reopen the source to recover an identity
that had already been parsed.

## Decision

At scanner revision `ast-v8-telemetry-event-targets` the inventory emits a
`telemetry_event` target for each literal event path passed to
`:telemetry.attach/4`, `:telemetry.attach_many/4`, or
`:telemetry_test.attach_event_handlers/2`. Dynamic lists and elements become
one unresolved target. `:telemetry_test.attach_event_handlers/2` is ranked
with the existing `global_telemetry_handler` signal and never receives
cleanup credit: its handler id is the returned reference, so no static
`:telemetry.detach/1` signature can be shown to match it, including a detach
of the variable the reference was bound to.

Every target carries an `oracle` field. It is `null`, or a map of the fixed
artifact's schema and the exact environment variable names and values the
artifact validates. A hint is emitted only when the identity is present
(resolved or syntactic) and the artifact would accept it unchanged; a segment
containing a comma, or a name or path beyond the artifact's byte and segment
bounds, yields `null` rather than a lossy encoding. `telemetry_handler`
targets have no matching artifact and are always `null`.

The hint is data. The scanner does not read `priv/oracles/`, install an
artifact, write `test_helper.exs`, select or start a test command, or treat the
hint as authorization. This narrows the earlier "does not select an oracle"
wording to "does not act on an oracle" without changing the inert-hint
boundary: nothing in the inventory executes or configures anything.

## Consequences

- An agent can move from a candidate target to the documented artifact
  invocation without re-deriving the environment encoding by hand.
- A `syntactic` identity still has to be validated by the agent before the
  hinted inputs are used; the hint repeats the identity, it does not confirm
  it.
- Candidate content identity and the configuration fingerprint change with
  the revision, so inventories from v7 and v8 are not comparable by `id`.
- The 64-target cap is shared across kinds; a test attaching many events can
  truncate application-env targets from the same candidate, and truncation
  stays visible.
- Binding analysis that would credit `ref = :telemetry_test.attach_event_handlers(...)`
  with an `on_exit(fn -> :telemetry.detach(ref) end)` cleanup remains
  separate, evidence-gated work.
