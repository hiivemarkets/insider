# Reading a report

Every Insider document separates four things that are usually conflated: what
was observed, whether the observation completed, how certain it is, and what
it is allowed to mean. This page gives the vocabulary and the reading order so
an agent does not promote one axis into another.

## Reading order

1. **Schema and identity.** Check `schema` is the one you expected and, for
   content-addressed documents, that `id` equals `"sha256:" <> integrity.content_digest`
   and that the appropriate `validate_with_*` function accepts the document
   with its exact inputs. Standalone validation proves structure and content
   identity only.
2. **Operational status.** Did the operation run to completion? Protocol
   results: `ok`, `error`, `timeout`, `cancelled`, `unsupported`. Confirmation
   records: `operational_status` of `completed`, `cancelled`, `error`,
   `timeout`. CLI exits: 0, 1, 124, 130, 3. A non-completed operation can
   still carry a true partial finding, but never a success.
3. **Domain outcome.** The thing the operation was asked about. Oracles:
   `changed` / `unchanged` / `inconclusive` (or `increased` / `unchanged` /
   `decreased` / `inconclusive`). Confirmation: `matching_failure`,
   `nonreproduced`, `repaired`, `unrelated_failure`, `infrastructure_failure`.
   Verification: `verified` or `invalid`. Minimizer and bisection: `completed`,
   `exhausted`, `inconclusive`, with a `reason`.
4. **Bounds and truncation.** `truncated`, `truncation_reasons`, `dropped`,
   `requested_limits` versus `effective_limits`, `consumption`, `bounds`,
   `*_truncated`, `*_observed`. A bound that was hit narrows every conclusion
   to what fit inside it.
5. **Cleanup.** `not_required`, `complete`, `partial`, `uncertain`,
   `unknown`, or for searches `complete` / `incomplete` / `unknown`. Only
   `complete` and `not_required` mean nothing was left behind.
6. **Confidence and uncertainty.** `confidence` (`certain`, `high`, `medium`,
   `low`, `unknown`) and the `uncertainty` list of named facts the component
   could not establish. Read every entry; they are the component telling you
   where its claim stops.
7. **Controls and limitations.** Fixed per schema. `controls` say what the
   artifact cannot do; `limitations` say what it cannot know. They do not vary
   per run and are not a verdict; they are the contract you are reading under.

## Words that are not success

| Word | What it means | What it does not mean |
|---|---|---|
| `candidate` | a static signal worth investigating | a defect, a cause, an impact |
| `syntactic` | an identity read from source without macro expansion | a runtime fact |
| `changed` | a global differed between the two captures of one run | which test changed it, that it matters, that it reaches production |
| `inconclusive` | a bound or read failure prevented comparison | unchanged, clean, or safe |
| `operational_failure` | the artifact never observed anything | any statement about the target |
| `nonreproduced` | the scenario ran and the expected finding was not observed | the defect is absent; the scenario recipe ran, which is all completion means |
| `matching_failure` | the expected finding was observed on a disposable target | causality, production impact, or a repair direction |
| `repaired` | a configured positive oracle reported repair | repair of anything outside the declared bounded scenario |
| `failed` (regression) | two fresh, distinct runs both reproduced on the same baseline | that the record's asserted execution occurred; a trusted runtime must have produced the live records |
| `completed` (minimizer) | no single remaining whole step can be deleted | a globally smallest reproducer |
| `adjacent_boundary_isolated` | one adjacent nonreproduced/reproducing pair on the search path | earliest reproducing target, or cause |
| `not_proven` | the search exhausted its budget; the best bracket so far | failure of the search |
| `verified` | both after-runs passed with exact provenance and complete cleanup | generalized bug freedom; proof of the declared scenario only |
| `invalid` | at least one verification reason | that the candidate is wrong; it may be a cleanup or provenance problem |
| `declared_unverified` | candidate bytes bound to a handoff | anything about the candidate's effect |
| `eligible` (proposal) | the evidence graph recomputes | permission to publish; `publication=blocked` stands |
| `provider_reported_created` | what the test provider said | independently verified remote state |
| `passed` (load) | every structural gate held on this host | a production budget or capacity |
| `no_canary_hits` | no declared token surfaced from the supplied items | application coverage or redaction approval |
| `mock: true`, `not_attempted` | the observability mapping is deterministic data | delivery or integration |

## Fingerprints and identities

- `sha256:` identities are content, not authenticity. Two equal digests mean
  equal bytes; they do not say who produced them. Trust comes from the
  configured adapter, provider, or host that validated the inputs.
- Oracle `hmac-sha256:` fingerprints use a random per-run key that is never
  exported. Compare them only inside the report they appear in.
- Provenance has five components (`code`, `configuration`, `dependencies`,
  `runtime`, `target`), each available, unavailable with a reason, or redacted
  under a named policy fingerprint. An `unavailable` component is not a
  mismatch; it is a documented gap, and the manifest keeps unavailable and
  redacted distinct.
- `context` in an oracle report is whatever the caller passed in. It is
  echoed, never verified, and every report says so.

## Binding evidence to the world

No oracle, inventory, or load report binds itself to the test you ran, the
revision you ran it on, or the ticket you are working. The inventory gives
you `source_fingerprint` and candidate `id`; the oracle gives you `context`;
the load report binds `git_sha` and tree state but only for the host it ran
on. You must record the command, the exact selected test, the revision, and
the inventory identity next to the report. `caller_must_bind_test_and_revision`
appears in every oracle report for this reason.

## When to stop

Stop and report rather than proceed when:

- a `70` exit, a missing oracle line, or `infrastructure_failure` appears:
  the environment is broken, not clean;
- an inventory's `completeness` is anything but `complete` (exits `3` to `5`)
  and you were about to treat a missing candidate as absence of risk;
- `scanner_revision` differs between inventories you are comparing;
- `cleanup` is anything but `complete` or `not_required` on a step whose next
  step assumes a clean executor;
- `uncertainty` names the exact thing your next inference depends on;
- a `syntactic` identity has not yet been validated against the real module
  environment;
- a record validates standalone but you have not run its `validate_with_*`
  with the exact inputs.

An unconfirmed finding does not authorize a repair, and a verified repair does
not authorize publication. Those are the two sentences the whole chain is
built to keep true.
