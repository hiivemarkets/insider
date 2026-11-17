# Offline proposals precede provider authority

## Decision

Phase 6 begins with a canonical, content-addressed draft-proposal artifact that
is derived only from the exact capsule, Sentinel manifest, verification record,
and recomputed repair-report manifest. It has no repository locator, provider,
network, branch, merge, deployment, or coding-model operation.

The proposal records `draft=true`, `review_required=true`,
`merge_prohibited=true`, `network_effect=none`, and
`repository_mutation=none`. It independently requires verified repeated
before/after evidence, complete cleanup, passed gates, and matching provenance.

Candidate and verification bytes do not yet have a reviewed disclosure
attestation. The proposal therefore records evidence as eligible while keeping
publication and provider creation blocked. A later disclosure design may
replace that fixed missing state only through a separately reviewed schema and
decision.

## Why

A local proposal proves the orchestration boundary without granting external
authority. It gives agents one deterministic handoff artifact while preventing
the existence of a report—or caller-authored success text—from becoming
permission to publish, mutate a repository, or create a pull request.

Reusing the existing five-row verification matrix avoids a competing account of
what was run. Recomputing all source identities prevents a structurally valid
but readdressed report from acquiring proposal eligibility.

## Consequences

- `Insider.Sentinel.DraftProposal` is an offline data type, not a GitHub or Git
  adapter.
- Missing disclosure is explicit and fail-closed; it is never inferred from a
  verified repair verdict.
- A separately canonical Lab-only companion may derive declared-unverified,
  provider-neutral ownership routing labels from exact proposal candidate bytes
  and direct declaration bytes. It remains outside provider, identity,
  assignment, authorization, Git, repository-read, pull-request, merge, and
  deployment authority; deduplication, coding-agent execution, Git bisection,
  provider integration, pull-request creation, merge, and deployment remain
  out of scope.
- Standalone decoding proves canonical structure and content identity. Only
  validation with the exact evidence graph proves that a proposal is derived
  from the claimed repair.
