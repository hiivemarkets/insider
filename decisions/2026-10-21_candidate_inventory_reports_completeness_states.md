# Candidate inventory reports completeness states

## Context

`mix insider.candidates` reported `status` `clean` and exited `0` whenever it
kept no candidates. That included scans with no eligible `_test.exs` file and
scans where a file could not be analyzed: on a real adopter checkout,
`--path test/support` (helpers only) looked identical to a clean test tree, and
a file with invalid syntax was listed under `unsupported` but still produced a
clean exit. An agent that branches on the exit code or `status` could record
"no isolation risk" for evidence the scan never examined.

## Decision

The inventory moves to `insider.exunit-candidate-inventory/v2` and carries a
`completeness` state, one of `complete`, `empty_selection`,
`unsupported_source`, or `truncated`, chosen by fixed precedence: any hit bound
(`truncated`), then any unsupported file (`unsupported_source`), then zero
eligible files (`empty_selection`), otherwise `complete`. `status` is `clean`
or `candidates` only when the scan is `complete`; otherwise it equals the
completeness state. Candidates found in an incomplete scan are still reported.

Exit codes: `0` clean, `2` candidates, `3` `empty_selection`, `4`
`unsupported_source`, `5` `truncated`, `64` invalid input, `70` scan failure.
Exit `1` stays unused because Mix exits `1` on an uncaught crash. The error
document keeps `insider.exunit-candidate-inventory-error/v1` and adds
`completeness: infrastructure_failure` to `failed` documents, an additive field
that does not change the meaning of any existing field. `invalid_input` documents
carry no completeness, because no scan started.

These names are the shared Insider completeness vocabulary: `complete`,
`empty_selection`, `unsupported_source`, `truncated`, and
`infrastructure_failure`.

## Why

Before this change, `clean` meant "no candidates kept". It now means "every
selected eligible file was analyzed within bounds and none was a candidate".
That is a change of meaning for an existing field, so the schema version
changes rather than staying v1 with an additive field, unlike the oracle-report
decision of 2026-10-01, which kept the existing status vocabulary. A v1
consumer that matched `clean` would otherwise keep treating an empty or partial
scan as a negative result.

A single state with documented precedence keeps one switchable value per scan.
The lower-precedence conditions are not lost: `truncation_reasons`,
`unsupported`, and `eligible_file_count` still show each of them. Truncation
ranks first because the scan knowingly stopped early. An unsupported file ranks
above an empty selection because a skipped symlink or unreadable directory may
hold the test files the selection appears to lack.

Rejected alternatives: keeping v1 and adding only `completeness`, which leaves
`clean` true for empty and partial scans; a list of every incomplete condition
as the primary signal, which every consumer would have to reduce to a decision
in its own way; and reusing exit `2` for incomplete scans with candidates,
which would hide incompleteness whenever any candidate was found.

## Consequences

- Consumers must accept the v2 schema. The candidate entries, fingerprints,
  `scanner_revision`, and all other v1 fields are unchanged, so candidate `id`
  values stay comparable across the version change.
- A scan whose selection includes any symlink, unreadable path, or invalid
  source never exits `0` or `2`, even when every other file is analyzed.
  Callers that want a complete scan must narrow the selection or fix the
  source.
- Exits `3` to `5` are not failures of the tool; they are evidence states. Only
  `70` means the scan itself could not run.
