# The protected-target audit matrix is derived policy data, not runtime state

## Decision

`Insider.Policy.ProtectedTargets.audit_matrix/1` is a pure, read-only export in
the production artifact. It derives an `insider.protected-target-audit-matrix/v1`
map from the fixed registry inventory and the control-target classes that
`bind_collector/2` and `bind_session/4` bind, enumerated per supported OTP
major (27, 28, 29 by default; a bounded, validated `otp_majors` option selects
others). Each row carries the denial decision and reason `classify/2` produces;
each inventory carries the base policy fingerprint an unbound, declaration-free
policy has on that major.

The export resolves no registered name, reads no file, and embeds no PID,
timestamp, node, or host value, so identical options produce identical bytes on
every toolchain. The committed `docs/protected-target-audit-matrix.json` is
that output, canonical and newline-terminated, and
`test/protected_target_audit_matrix_test.exs` pins it byte-for-byte while also
asserting that every registered matrix name is denied by the live policy.

Regeneration is a documented `mix run --no-start -e` one-liner. The production
artifact gains no Mix task, writer, or CLI.

## Why

The readiness threat model names a "central policy and audit matrix" for the
protected-targets gate. The policy already existed; the reviewable enumeration
of what it denies did not, and it could only be recovered by reading source.
A committed derivation gives reviewers one document to diff when the inventory
changes and lets the test suite catch a silent drift between the artifact and
the policy.

Rejected alternatives:

- Resolving names at generation time and recording which were registered. That
  would bind the artifact to the generating host and toolchain, make the bytes
  non-reproducible, and misrepresent policy data as host state.
- A `mix insider.audit_matrix` task in the root project. The core contains no
  Mix tasks or file writers; `scripts/verify-production-artifact` rejects them.
- A Lab-only task. It would add a second project surface and a Lab test for a
  one-line regeneration command that the README already documents.
- Declaring application targets or an exception-review owner in the matrix.
  Both are human-gated decisions; the matrix records them as `undeclared`.

## Consequences

- The matrix is mechanism evidence only. It does not prove that any name is
  registered on a given runtime, that an adopting service's targets are
  protected, or that the gate passes; the dossier assessment is unchanged.
- An inventory or control-class change must regenerate the artifact in the same
  commit or the pinning test fails.
- `inventory_is_release_independent_so_rows_repeat_across_majors` is stated in
  the artifact: rows differ between majors only by `otp_major` and base
  fingerprint until the inventory itself becomes release-specific.
- Application targets, an exception mechanism, and a review owner remain for a
  later human decision; this record provides none of them.
