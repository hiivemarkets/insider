# The Sentinel chain

Every artifact in `tools/insider_lab/lib/insider/sentinel/` is a canonical
JSON document with a `schema`, a SHA-256 `id` of the form `sha256:<digest>`,
and an `integrity` object repeating that digest. Most carry fixed `controls`
that record what the artifact cannot do; a verification candidate carries only
its content fields, and a regression carries an `execution_policy` instead.
Standalone validation proves structure and content identity only. Each
schema's `validate_with_*` function (`validate_with_evidence`,
`validate_with_proposal`, `validate_with_capsule`, `validate_with`) recomputes
the artifact from its exact inputs; those are the only evidence-bearing checks.
SHA-256 gives content identity, not authenticity: a record is trusted only
through the host or adapter that produced and validated it.

[Architecture and trust boundary](../../docs/architecture.md#architecture-and-trust-boundary),
[Collector-to-Sentinel handoff](../../docs/sentinel-and-proof-workflow.md#collector-to-sentinel-handoff),
and [Proof workflow](../../docs/sentinel-and-proof-workflow.md#proof-workflow) are the full
reference; this page is the ordered map with the claims each step does and
does not make.

## Order of operations

```text
Manifest ─► Confirmation ─► Regression ─┬─► Minimizer
                                        ├─► Bisection
                                        └─► Handoff ─► CandidateSubmission
                                                              │
                        Verification ◄────────────────────────┘
                              │
                 RepairReport ─► DraftProposal ─► SourceOwnership
                                       │              Dedup
                                       └─► DraftCreation (gate)
```

## 1. `Insider.Sentinel.Manifest` (`insider.sentinel-manifest/v1`)

Binds the exact capsule id, byte size, and full-byte digest; lists six
prerequisites (`code`, `configuration`, `dependencies`, `runtime`, `target`,
`scenario`) as available, unavailable with a reason, or policy-redacted; and
fixes `execution_policy` with `purpose=confirmation`,
`source_mutation=prohibited`, `target_class=disposable`.
`validate_with_capsule/2` must be called with the canonical capsule bytes at
untrusted ingress; `readiness/2` also requires them.

Does not claim: that the external runtime will honor the policy. The runtime
must independently prove its environment and target class.

## 2. `Insider.Sentinel.Confirmation.run/6` (`insider.confirmation-record/v1`)

Jointly validates manifest, capsule, scenario, and target provenance; requires
the capsule's primary finding in the scenario's expected set; arms a trusted
allowlisted observer; runs the scenario on a live owner lease; and finalizes
a run-correlated receipt. `outcome` is one of `matching_failure`,
`nonreproduced`, `repaired` (only through a configured positive oracle),
`unrelated_failure`, `infrastructure_failure`; `operational_status` is one of
`completed`, `cancelled`, `error`, `timeout`. The record carries
`requested_target_fingerprint`, `observed_target_fingerprint`,
`observed_fingerprints`, `evidence`, `cleanup`, and `uncertainty`.

Does not claim: completeness unless evidence is zero-loss, cleanup is
inventory-backed, and observed target provenance is exact. A nonzero exit from
an external-process body can be valid failing-before evidence when the exact
report carries the expected finding.

## 3. `Insider.Sentinel.Regression` (`insider.regression/v1`)

Materializes a data-only recipe from one eligible confirmation record and its
exact scenario: both wire documents embedded, expected incident fingerprint and
observer identity derived, and a fixed policy of `required_runs=2`,
`source_mutation=prohibited`, `target_class=disposable`. `classify/2` over two
fresh confirmation records reports `failed` only when both are distinct
observation runs binding the same capsule, manifest, scenario, expected
incident, observer, and exact baseline target, with complete evidence and
cleanup. Reusing the embedded source run, or any duplicate, incomplete,
unrelated, nonreproduced, repaired, or cross-bound run, is inconclusive.

Does not claim: that materializing the recipe proves the incident failed
again, or that a record's asserted execution occurred.

## 4. `Insider.Sentinel.Minimizer.run/6` (`insider.minimization-record/v1`)

Greedy restart-after-accept deletion of whole scenario steps
(`algorithm=greedy_delete_steps_v1`). The original regression must fail in two
fresh confirmations first; each candidate runs three fresh confirmations
(one materializes a candidate regression, two must satisfy `classify/2`).
`status` is `completed`, `exhausted`, or `inconclusive`; reasons are
`one_step_minimal`, `unchanged_one_step_minimal`, `max_candidates_exhausted`,
`total_deadline_exhausted`, `baseline_inconclusive`,
`baseline_nondeterministic`, `candidate_nondeterministic`,
`candidate_inconclusive`, `executor_not_clean`, `executor_state_unknown`.
`duration_scope=execution_search` means the ceiling covers the effectful phase
from clean-executor preflight through final cleanup, not input validation.

Does not claim: a globally smallest reproducer; exhaustion returns the best
regression so far with `not_proven` minimality. Argument shrinking is not
implemented.

## 5. `Insider.Sentinel.Bisection.run/6` (`insider.bisection-record/v1`)

Binary search (`algorithm=binary_search_declared_targets_v1`) over a
host-declared ordered list of 2 to 64 `insider.sandbox-target/v1` documents,
oldest to newest, with up to 2 confirmations per probed index (an index whose
first confirmation is not clean stops without a second) and at most 128 probes.
Both endpoints are proven first: the oldest must not reproduce and the newest
must, or the record is `inconclusive` with `baseline_not_bracketed`. Other
stops: `probe_nondeterministic`, `probe_inconclusive`, `executor_not_clean`,
`executor_state_unknown`; exhaustion is `max_probes_exhausted` or
`total_deadline_exhausted`. Each trial records a `role` (`oldest_endpoint`,
`newest_endpoint`, `midpoint`) and a `decision` (`nonreproduced`,
`reproduced`, `nondeterministic`, `inconclusive`, `exhausted`).

Controls: `repository_read=none`, `checkout=none`,
`source_mutation=prohibited`, `git_authority=none`, `network_effect=none`.
Limitations: `outcome_monotonicity_is_a_host_assumption`,
`indices_off_the_search_path_are_not_probed`,
`target_causality_is_not_claimed`.

A `completed` record's `culprit` has `boundary_nonreproduced_index`,
`boundary_reproducing_index`, `proof=adjacent_boundary_isolated`, and the
declared `target_id` and `target_fingerprint` at the reproducing index.
Exhaustion returns `proof=not_proven` with null target fields and whichever
boundary indices were established; both are null when the budget ran out
before an endpoint was proven (for example `max_probes: 1`).

Does not claim: the earliest reproducing target (that is the host's
monotonicity assumption), or that the target caused the failure. Insider never
reads a repository, orders revisions, or checks anything out. Because
confirmation binds each target's five prerequisite fingerprints to the
manifest, targets in one list currently share the capsule's provenance
fingerprint and differ by provider identity; the evidence graph binds a probe
to its declared fingerprint, not to one target id, when fingerprints coincide.
See `decisions/2026-10-01_bisection_is_offline_over_declared_targets.md`.

## 6. `Insider.Sentinel.CodingAgent.Handoff` (`insider.coding-agent-handoff/v1`)

`new/4` takes the capsule, manifest, regression, and exactly two fresh failed
confirmation records and emits `kind=confirmed_regression_repair_request` with
a fixed `request`: `objective=propose_candidate_repair`,
`output_schema=insider.verification-candidate/v1`,
`candidate_status=unverified`, `verification=required`. Controls:
`credentials=none`, `deploy=prohibited`, `merge=prohibited`,
`model_invocation=none`, `network_effect=none`, `provider_effect=none`,
`repository_mutation=none`, `review_required=true`. At most 1,572,864 canonical
bytes.

Does not accept: caller-authored instructions or causal claims. Does not
claim anything about a future candidate.

## 7. `Insider.Sentinel.Verification.Candidate` and `CodingAgent.CandidateSubmission`

A candidate (`insider.verification-candidate/v1`) is a format name, `opaque/v1`
or `unified-diff/v1`, and at most 16,384 bytes of content. It cannot select a
module, command, or path; only a host-selected body module interprets it.
`CandidateSubmission.new/2` binds the candidate to the exact handoff
(`insider.coding-agent-candidate-submission/v1`,
`kind=inert_candidate_submission`) with `status`
`candidate=declared_unverified`, `draft_eligible=false`,
`repair_claim=none`, and controls `application=none`,
`disclosure=unattested`, `provider_creation=blocked`, `publication=blocked`,
`verification=required`, plus the shared deploy/merge/network/repository
prohibitions. At most 32,768 bytes.

Does not: invoke a model, run a command, apply a patch, read or mutate a
repository, or claim repair success.

## 8. `Insider.Sentinel.Verification.run/7` (`insider.verification-record/v1`)

Runs exactly two fresh live confirmations against the regression baseline and
dispatches candidate work only when `Regression.classify/2` reports `failed`;
then runs exactly two independent post-repair sandbox attempts through a
host-allowlisted body module. One validated request is shared across the
sequence and its `deadline_monotonic` is the single absolute deadline. The
record is `verified` when `reasons` is empty and `invalid` otherwise; reasons
include `after_run_failed`, `after_uncertain`, `target_mismatch`,
`executor_leak`, and the cleanup, gate, provenance, and receipt-binding
reasons derived from each attempt. Verification never reuses the handoff's
earlier failure runs.

`verified` requires: both after-runs observe no failure, agree on changed code
and unchanged configuration/dependencies/runtime/target provenance, carry
distinct positive oracle receipts, clean up completely, and leave the executor
at zero active and zero quarantined leases.

## 9. `Insider.Sentinel.RepairReport.Manifest` (`insider.repair-report-manifest/v1`)

Recomputed from the capsule, pre-execution manifest, and verification record;
`validate_with_evidence/4` is the evidence-bearing operation and
`RepairReport.render_markdown/4` calls it before rendering deterministic
Markdown. Cleanup is reported from the full release/count/fingerprint
predicate and the proof includes final executor counts. A valid but
inconclusive verification stays visibly `invalid` and is still reportable.

Does not: accept caller-authored causal or success prose. The candidate diff
is shown for review but is not covered by the capsule's redaction policy, so
reports are internal artifacts until a disclosure policy exists.

## 10. `Insider.Sentinel.DraftProposal` (`insider.draft-proposal/v1`)

`new/4` rechecks the five-run matrix, cleanup, gates, provenance, and exact
evidence identities. Controls: `draft=true`, `merge_prohibited=true`,
`network_effect=none`, `repository_mutation=none`, `review_required=true`.
Eligibility: `evidence=eligible`, `provider_creation=blocked`,
`publication=blocked`, reason `candidate_disclosure_attestation_missing`.
Disclosure: `candidate=unattested`, `verification=unattested`,
`status=missing`, `attestation_id=null`. `validate_with_evidence/5` recomputes
it. At most 131,072 bytes.

Does not: create a pull request or carry disclosure approval.

## 11. `Insider.Sentinel.SourceOwnership` (`insider.source-ownership/v1`)

`new/2` takes a proposal and declaration bytes (at most 16,384) in a small
CODEOWNERS-like syntax; derives paths only from a `unified-diff/v1` candidate;
last matching rule wins; unmatched paths stay unassigned. Controls:
`assignment=prohibited`, `authorization=prohibited`, `mutation=none`,
`network_effect=none`. `validate_with_proposal/3` recomputes it. Unsafe,
binary, rename/copy, malformed, duplicate, or out-of-bound paths fail closed.

Does not: read a working tree, Git metadata, or repository. Owner labels are
opaque routing hints, not people, principals, reviewers, or permissions.

## 12. `Insider.Sentinel.Dedup` (`insider.dedup-receipt/v1`)

An in-memory ledger. `ingest_capsule/2` accepts exact canonical capsule bytes;
`ingest_proposal/6` accepts a proposal only after recomputing it from its
capsule, manifest, verification record, and repair report, and only if that
capsule is already retained. Artifacts are grouped by a SHA-256 projection of
the capsule finding fingerprint. Receipt `outcome` is `new_evidence`,
`duplicate`, or `capacity_refused` (with `capacity` naming `groups`,
`artifacts_per_group`, `receipts`, or `retained_bytes`). Default limits: 32
groups, 8 artifacts per group, 2,097,152-byte single input, 2,097,152 retained
bytes, 256 receipt slots. No eviction; a refused input leaves state unchanged.

Receipts contain a hashed group id, content-addressed references, an
`evidence_bytes` total, and counts. They never contain capsule or proposal
bodies, diffs, findings, providers, repository, network, Git, assignment,
authorization, or mutation fields. The ledger itself retains canonical
evidence bytes and is internal sensitive state.

## 13. `Insider.Sentinel.DraftCreation.Executor`

Disabled by default. When enabled in an isolated Lab process it accepts only
provider and disclosure-authority modules from host configuration; portable
identities select among that allowlist and can never resolve a module. Starting
the executor calls each configured module's `identity/0` even while effects are
disabled. Before any authorization or creation callback it recomputes the
verified proposal, validates the handoff and
submission, and requires both to bind the same candidate. The authority must
approve the exact provider-visible payload for one destination fingerprint;
the decision becomes an `insider.draft-creation-request/v1` whose controls are
`merge=prohibited`, `publication=draft_only`,
`repository_mutation=draft_creation_only`,
`network_effect=configured_provider_only`, `review_required=true`. The
provider result becomes an `insider.draft-creation-receipt/v1` with `outcome`
one of `provider_reported_created`, `provider_reported_existing`,
`provider_reported_rejected`, `provider_outcome_unknown`,
`provider_output_invalid`.

Does not: have a real GitHub or network provider in this phase (only test
fixtures), verify remote state (`created` and `existing` are
provider-reported), or provide crash-safe exactly-once execution (providers
must enforce the idempotency key). A provider timeout is
`provider_outcome_unknown` because stopping the local callback cannot prove no
external effect occurred.

## Reading a record's `cleanup`

Across the chain, `cleanup` is `complete` only when independent owner inventory
was observed empty (and, for searches, when both executor counts were observed
as zero). `incomplete`, `partial`, `uncertain`, and `unknown` are distinct and
mean exactly what they say; a quarantined lease is never reported as reclaimed.
A record with any of them can still carry a true domain finding; it cannot
carry a success claim.
