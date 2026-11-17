# A readiness dossier cannot self-authorize

## Decision

The readiness work ships an evidence assessment, a planning-only runbook, and a
non-authoritative pre-canary worksheet. None is executable authority. Missing
service budgets, privacy/data-lifecycle review, rollback rehearsal, candidate
identity, or named human approval keeps staging and production denied.

A later pre-canary approval must bind one exact merged revision, immutable host
configuration fingerprint, staging cohort, duration, thresholds, rollback, and
named technical, security/privacy, service, and on-call approvers. Production
still requires a separate post-canary decision based on the resulting canary
evidence.

## Why

Insider can prove bounded mechanics and retain synthetic evidence, but an agent
cannot choose organizational risk tolerance or demonstrate an unmeasured
service workload. Treating a complete-looking document as authorization would
collapse evidence and human risk acceptance into the same artifact.

## Consequences

- The current dossier outcome is `decision_required`; it recommends continued
  development/CI use and no canary.
- The runbook contains no deploy command, credential, endpoint, or bypass.
- Local macOS evidence and the OTP 28 load failure remain visible.
- Evidence from an earlier revision cannot approve a changed candidate.
- Agents may assemble and verify evidence but cannot turn the worksheet into an
  authenticated human approval.
