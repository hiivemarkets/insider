# Declared source ownership is offline routing only

## Decision

`Insider.Sentinel.SourceOwnership` is a Lab-only canonical companion artifact
for `Insider.Sentinel.DraftProposal` v1. It receives the proposal and
declaration bytes directly, validates the proposal's exact canonical candidate,
and derives changed paths only from a tightly bounded simple
`unified-diff/v1` grammar. It never reads a repository, Git metadata, a
working tree, credentials, or configuration outside those inputs.

The declaration grammar is intentionally smaller than any provider's
CODEOWNERS implementation: bounded UTF-8 lines, comments, path segments with
`*`, optional root anchoring, and recursive directory suffixes. It rejects
provider-shaped owner names, negation, escapes, character classes, ambiguous
paths, inline comments, duplicate owners, and oversized input. Last matching
rule wins; paths with no match are emitted with an empty owner list.

Owner strings are opaque caller-declared labels. They are not identities,
provider accounts, reviewers, assignees, permissions, or authorization. The
artifact has no provider, repository locator, branch, operation, merge, or
deployment field and records assignment and authorization as prohibited.

## Why

The exact candidate can help route a local review without making an offline
repair proposal a claim about repository state or a permission to contact,
assign, or authorize anyone. Failing closed on input that cannot be interpreted
without broader source or provider semantics avoids silently inventing such
authority.

## Consequences

- Standalone decoding proves the companion's canonical structure and content
  identity only. `validate_with_proposal/3` recomputes it from the exact
  proposal and exact declaration bytes.
- A valid but readdressed companion can still be parsed as data, but cannot
  validate against the claimed proposal or declaration.
- Binary, rename/copy, unsafe, duplicate, malformed, or bounded-out diffs
  produce no ownership artifact.
- Any provider lookup, identity verification, assignment, notification,
  authorization, Git/repository access, mutation, pull-request creation,
  merge, or deployment needs a separate future decision and schema.
