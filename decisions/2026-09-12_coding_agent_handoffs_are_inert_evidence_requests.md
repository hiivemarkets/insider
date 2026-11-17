# Coding-agent handoffs are inert evidence requests

## Decision

The repair loop adds two Lab-only canonical artifacts. A coding-agent handoff is a
self-contained bundle of the exact capsule, ready Sentinel manifest, eligible
regression, and exactly two fresh confirmation records that independently
classify as the same failed regression. It contains a fixed request for an
existing `insider.verification-candidate/v1`; callers cannot add instructions,
causal prose, success claims, provider identity, or execution authority.

A candidate submission binds one existing bounded `Verification.Candidate` to
the exact handoff. It is permanently labelled `declared_unverified`, makes no
repair claim, and remains ineligible for draft creation or publication.

Both artifacts have fixed controls prohibiting model invocation inside Insider,
credentials, commands, candidate application, repository mutation, network or
provider effects, PR creation, merge, and deployment. SHA-256 supplies content
identity and integrity, not authenticity or authorization.

## Why

The missing repair-loop boundary is between proof that the unchanged defect
still fails and permission to evaluate a proposed candidate. A self-contained
handoff gives an agent the bounded redacted evidence it needs without an
ambiguous sidecar protocol. Reusing `Verification.Candidate` avoids a competing
candidate format.

The handoff's two failure records are not reused as verification evidence. The
existing verifier must run fresh before and after attempts in a disposable
target, preventing stale handoff evidence or a candidate declaration from
becoming a repair verdict.

## Consequences

- The runtime chain is confirmed source plus two fresh failures → handoff →
  inert submission → fresh verification → report → offline draft proposal.
- Standalone artifact validation checks the embedded graph and content identity;
  validation against external evidence recomputes the entire artifact.
- Candidate interpretation and application remain the responsibility of an
  independently allowlisted disposable verification body.
- No provider or Git authority is introduced. A later draft provider must bind
  the exact submission candidate to the independently verified proposal and
  enforce the separate disclosure decision.
