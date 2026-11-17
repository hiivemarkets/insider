# Application-env oracle is a fixed value-free Lab artifact

## Decision

Package the proven application-environment before/after observation as one
fixed ExUnit script under Insider Lab. The calling agent supplies bounded
application and key names, explicitly loads the artifact from the target's
`test_helper.exs`, invokes one selected test command, and owns the command
deadline. Insider does not spawn Mix, select a test, generate source, or
evaluate caller code in this slice.

The `test_helper.exs` hook is temporary. The agent must record the pre-run target
state, remove the hook immediately after the selected command, and verify the
target worktree is restored before treating cleanup as complete.

The artifact finds only already-loaded application and key atoms by string
comparison. It records presence and, for values no larger than 1 MiB in external
term form, HMAC-SHA-256 fingerprints made with one random unexported key per
run. It emits neither the value nor the HMAC key. Oversized or unobservable
values are inconclusive rather than compared with weaker evidence.

## Evidence

Most early findings confirmed against a real application used this shape.
A standalone prototype and then the checked-in artifact both distinguished the
same real boundaries at one pinned application revision: a passing OpenTelemetry
test changed its selected application-env entry, while a passing
production-guard test restored a separate selected entry exactly. The same
artifact reported `changed` and `unchanged`, respectively.

Isolated child-BEAM tests also establish changed, restored, absent, oversized,
malformed-input, missing-application, atom-safety, sensitive-value exclusion,
and failing-suite behavior without mutating the test host.

## Consequences

- An agent can confirm the most common current candidate class without writing
  a bespoke probe, while source ranking and runtime observation stay distinct.
- Fingerprints prove equality only within one run; they cannot correlate or
  authenticate values across runs.
- The result declares that it is not revision- or test-bound and does not prove
  causality; reusable cross-run receipts remain a later boundary.
- Compile or test-file load failure can prevent the after-suite callback; absent
  output is infrastructure failure rather than evidence of unchanged state.
- The oracle performs two application-environment scans and at most two bounded
  serializations and HMAC calculations.
- The fixed artifact is development/CI-only and excluded from the root runtime
  package.
- Command orchestration, other target kinds, reusable cross-run receipts, and
  automatic defect promotion remain later evidence-gated work.
