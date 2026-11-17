# Bounded offline incident and proposal deduplication

## Decision

Add `Insider.Sentinel.Dedup` as a Lab-only, in-memory, offline ledger. It
accepts a canonical incident capsule before any repair proposal exists. It
accepts a canonical draft proposal only after recomputing it with its exact
capsule, Sentinel manifest, verification record, and repair report. The exact
capsule must already be retained and the recomputed proposal finding must map to
the same group identifier.

The group identifier is SHA-256 over the v1 group schema and the capsule
finding fingerprint. The raw fingerprint is not retained in a receipt. A
canonical artifact's byte digest is its exact identity. Repeating that identity
is an idempotent duplicate; a different canonical identity in the same group is
retained as new evidence. A different group remains distinct.

The ledger has explicit host-local limits: groups (default 32, hard maximum
128), total capsule-plus-proposal artifacts per group (8, maximum 32), a single
full-evidence-graph input (2,097,152 bytes), retained canonical evidence bytes
(2,097,152 bytes by default, maximum 16,777,216), and retained-artifact receipt
slots (256, maximum 4,096). It never evicts. A valid new artifact at any capacity limit receives a
canonical `capacity_refused` receipt and the state is unchanged. The bounded
receipt counter means accepted unique artifacts; duplicate and refusal receipts
are deterministic projections and consume no retained state. Invalid,
noncanonical, oversized, wrong-schema, integrity-forged, graph-unverified, or unbound input returns an
error before any state mutation.

Receipts are canonical `insider.dedup-receipt/v1` values. They include only a
hashed group identifier, capsule/proposal content references (schema, ID,
canonical digest, and byte size), the outcome, capacity class, a bounded
`evidence_bytes` admission total, and bounded counts. The total is exactly the
canonical input evaluated for the artifact: the capsule alone, or the capsule
and the proposal, Sentinel manifest, verification record, and repair report.
For a proposal it is constrained to the capsule and proposal byte sizes plus
3..589,824 bytes for the three nonempty graph records (65,536-byte manifest,
262,144-byte verification record, and 262,144-byte repair report), and remains
within the 2,097,152-byte graph-input maximum.
It is numeric only: it permits capacity relations without exposing the three
extra graph references or their contents. A duplicate or refusal carries the
same retained or prospective total, respectively, while its counters remain a
projection of unchanged state. Receipts include no full artifact, candidate
diff, finding payload, secret, repository locator, provider, Git, network,
identity, assignment, authorization, mutation, merge, or deployment field.

The caller-owned Lab ledger stores the canonical bytes necessary to recompute
every retained capsule/proposal graph. Every retained binary is copied before
storage and revalidation rejects a binary that still references a larger parent,
so the byte limit also bounds physical retained binary backing memory. That
state is internal sensitive evidence and is bounded by `max_retained_bytes`; it
is not a receipt and must not be exported as one.

## Why

Restart storms and repeated collectors need suppression before a later repair
workflow has constructed a proposal. Pair-only deduplication would lose that
early boundary. Separating capsule admission from proposal admission preserves
the incident-first path while making a proposal's relation to an exact retained
capsule explicit.

Failing closed on ingress and refusing capacity without eviction prevents a
ledger from silently replacing evidence. Hashes give deterministic identity,
not authenticity. Standalone proposal decoding remains structural; full
evidence-graph recomputation is still required at any eligibility-bearing
handoff.

## Consequences

- This is a Lab-only data contract, not a provider, repository, coding-agent,
  Git, network, notification, assignment, authorization, mutation, draft-PR,
  merge, or deployment API.
- The ledger is caller-owned in-memory state. Persistence, cross-process
  coordination, expiration, and a global suppression policy require a separate
  authority and retention decision.
- A content-addressed collision is treated according to SHA-256 identity; no
  additional authenticity or secret-disclosure claim is made.
