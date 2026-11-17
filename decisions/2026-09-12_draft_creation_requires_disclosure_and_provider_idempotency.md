# Draft creation requires disclosure approval and provider idempotency

## Decision

This step introduces a Lab-only, disabled-by-default draft-creation boundary.
Provider and disclosure-authority modules are configured by the host and
selected only through exact allowlisted identities; portable input cannot name
or resolve executable modules. A provider identity includes a destination
fingerprint, and the trusted authority must approve the canonical
provider-visible payload for that exact destination before the provider is
called.

The executor first recomputes the exact verified draft proposal and validates
its capsule, manifest, verification, repair report, coding-agent handoff, and
candidate submission as one consistent graph. The resulting canonical request
is draft-only, requires human review, carries no credentials, and prohibits
merge and deployment. The provider response is retained as a canonical receipt.

Pending evidence admission is bounded. Calls are serialized and exact retries
use a bounded in-memory receipt cache. A different disclosure authority for the
same intent conflicts instead of inheriting the earlier authority's decision.
Providers must also implement the supplied idempotency key natively. The local
cache does not support a claim of crash-safe exactly-once execution.

## Why

A verified repair is not permission to disclose its evidence or mutate a remote
repository. Draft creation crosses both boundaries, so evidence eligibility,
destination-specific disclosure authority, and provider authority must remain
separate and independently checkable. Host allowlists prevent untrusted wire
data from selecting code, while canonical requests and receipts preserve the
exact decision and outcome for later review.

Local serialization handles duplicate calls within one executor lifetime, but
it cannot determine whether an external provider completed an operation after a
timeout or process crash. Provider-native idempotency is therefore required to
make a retry safe across that uncertainty.

## Consequences

- Effects remain disabled by default, and this phase ships no GitHub or other
  real network provider.
- Created and existing outcomes mean only that the configured provider reported
  them; the remote state is not independently verified.
- A provider timeout is recorded as an unknown external outcome and exact local
  retries return that receipt instead of issuing another attempt.
- Receipt capacity is fixed and bounded; no eviction silently permits a repeat
  effect.
- Credentials do not cross this artifact boundary, and merge and deploy are not
  part of the provider behaviour.
- Staging or production use requires a separate, revision-bound human security,
  privacy, and operations decision.
