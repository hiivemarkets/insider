# Bisection is offline over declared targets

## Context

`decisions/2026-09-11_offline_proposals_precede_provider_authority.md` left
Git bisection out of scope. The Lab now has a bounded Sentinel search that
narrows a confirmed regression to one adjacent pair of declared targets, and
that search needs a boundary before anyone reads it as repository access. This
record supersedes the earlier exclusion only for the offline bisection
described here; Git bisection in the sense of repository reads, revision
ordering, or checkouts stays out of scope.

## Decision

`Insider.Sentinel.Bisection.run/6` performs a binary search over an ordered
list of two to sixty-four disposable `Sandbox.Target` values that the host
supplies, oldest to newest. Insider never reads a repository, orders revisions,
checks a revision out, mutates source, or contacts a network to obtain that
list; every target is declared input bound by its own provenance, and the
record pins the fixed controls `repository_read=none`, `checkout=none`,
`source_mutation=prohibited`, `git_authority=none`, `network_effect=none`.

Each probed index runs two fresh confirmations through the existing
`Confirmation.run/6`. The oldest target must not reproduce in both and the
newest must reproduce in both before any midpoint runs; otherwise the record is
`inconclusive` with reason `baseline_not_bracketed`. Mixed clean outcomes at
one index stop as `probe_nondeterministic`; infrastructure, evidence, or
binding uncertainty in a probe stops as `probe_inconclusive`; an executor that
reports active or quarantined work after any probe or at final cleanup stops
as `executor_not_clean`, and an executor whose counts cannot be obtained
before the deadline stops as `executor_state_unknown`. A probe counts as clean
only when its requested and observed target fingerprints both equal the
declared target it was dispatched to, and when it binds the source capsule,
manifest, scenario, expected incident, and observer.

A completed record names one adjacent pair on the search path,
`boundary_nonreproduced_index` and `boundary_reproducing_index`, the declared
target identity and fingerprint at the reproducing index, and `proof =
adjacent_boundary_isolated`. The search never probes an index off its
binary-search path, so the pair is the earliest reproducing target only under
the host's assumption that outcomes are monotonic across its list; the record
carries the fixed limitations `outcome_monotonicity_is_a_host_assumption`,
`indices_off_the_search_path_are_not_probed`, and
`target_causality_is_not_claimed`. Exhaustion of the probe or duration bound
returns the best-known `[boundary_nonreproduced_index,
boundary_reproducing_index]` bracket with `proof = not_proven`. No status,
reason, or field claims that a target caused the failure or that it is the
first to reproduce.

The record's `cleanup` reports the executor counts observed when the search
stopped and is `complete` only when both were observed as zero. A protocol
error from a confirmation returns that error, annotated with the final
cleanup observation and the run count, instead of a record; a provider
exception or dead executor returns `operation_failed` with no cleanup count.
Teardown belongs to the sandbox runner; the search reports what it observed
rather than guaranteeing zero counts on every exit.

`validate_with_evidence/6` replays the search path from the recorded trials
against the exact declared target list and rederives every index decision from
the referenced confirmation records. A trial that probes an index the algorithm
would not have selected next, a decision its own records contradict, or a
reordered evidence list is rejected.

## Why

Confirmation already binds a target's five prerequisite fingerprints to the
manifest and refuses a run on anything else. Reusing that path keeps bisection
inside the same disposable, cleanup-required, mutation-prohibited execution
posture as regression and minimization, and it keeps one account of what was
run. Deriving a per-target manifest or relaxing the prerequisite check would
have let bisection run on environments the capsule never described; that was
rejected for this version.

Declaring the list, rather than discovering it, is what keeps the search free
of repository, revision, and checkout authority. The host owns what each
target is and in what order; Insider owns only the bounded search and its
evidence. Two probes per index mirror the regression classifier's two-run rule
so a single lucky or unlucky run cannot move the bracket.

Reporting an adjacent boundary pair on the search path, instead of the first
reproducing target or a cause, is the strongest statement the evidence
supports: the search observes outcomes on the declared environments it
probed, not on the ones it skipped and not what changed between them. A
host whose list may be nonmonotonic owns the decision to probe further.

## Consequences

- `Insider.Sentinel.Bisection` and its record are Lab-only data and
  orchestration; they are not a Git, repository, or provider adapter.
- Because every declared target must satisfy the manifest's five prerequisite
  fingerprints, targets in one list currently share the capsule's provenance
  fingerprint and differ by provider identity. A confirmation record carries
  fingerprints but not a target identity, so the evidence graph binds each
  probe to a declared fingerprint, not to one declared target id, when
  fingerprints coincide. Lifting either limit needs a manifest or confirmation
  record schema change and its own decision.
- The record bounds targets to sixty-four, probes to one hundred twenty-eight,
  and trials to eight; search duration is measured from executor preflight
  through final cleanup, as the minimizer does.
- Revision discovery, repository reads, checkouts, and any ordering performed
  by Insider remain out of scope and would require a separate decision.
