# Production readiness precedes enablement

## Decision

Treat production readiness as a separate evidence phase. Insider will continue
to deny non-baseline staging and production operations until an explicit human
review accepts a revision-bound readiness dossier and exact release
configuration. Readiness has two human gates: a pre-canary decision may permit
only one exact, time-bounded staging canary, and a post-canary decision may
permit only the exact production release reviewed with the canary evidence.

The eventual production artifact must physically exclude Sentinel, deliberate
fault fixtures, coding-agent integration, Git/PR functionality, arbitrary
evaluation, fault injection, and code mutation. Runtime flags alone do not form
that trust boundary. The packaging mechanism will be selected and verified in a
separate work item before any production-observation staging canary.

Trusted observation configuration belongs to the adopting host at supervision
startup. Captured data and external requests cannot select environment,
authority, limits, redaction, target exceptions, vendor credentials, or network
behavior. Vendor clients and secrets remain host-owned.

## Why

The current implementation has strong bounded primitives and development
measurements, but no production workload, approved performance budget, ingress
privacy profile, combined collector supervisor, operational runbook, or staged
rollback proof. Its composed benchmark explicitly disclaims production
capacity, Logger can currently retain payloads when configured to do so, and
OTP 27 system monitoring uses a node-global facility.

Enabling production while those questions are unresolved would turn missing
evidence into an implicit risk acceptance. A separate readiness phase keeps the
existing fail-closed policy meaningful and makes the eventual human decision
reviewable.

## Consequences

- Production-readiness work may add policy, packaging, measurement, redaction,
  lifecycle, vendor-mapping, and operational evidence without enabling
  production.
- OTP 27 node-global system monitoring is excluded from the first production
  profile unless separately approved.
- Raw Logger payloads and unclassified Telemetry values are not production
  defaults.
- An agent may report a readiness gate as passed or blocked from evidence, but
  cannot approve staging or production use.
- A staging policy exception requires an explicit pre-canary dossier and human
  authorization. It is limited to the reviewed revision, cohort, duration, and
  thresholds, and is revoked after the run or on any abort condition.
- Production deployment requires a separate post-canary dossier and human
  authorization that includes the resulting canary evidence.
- Durable rollback means disabling or removing the component or dependency,
  redeploying, and proving its owned runtime inventory is empty; the runtime
  kill switch is only emergency containment.
