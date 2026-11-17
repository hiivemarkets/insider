# How a session works

This page follows one failure from the first signal to an inert repair
proposal. Each box below exists in the code at the current revision; the
arrows are data handoffs, and every handoff is a validated, content-addressed
document rather than shared state.

```text
 host application (development, test, or CI only)
 ┌──────────────────────────────────────────────────────────────┐
 │  Logger reports ─┐                                           │
 │  Telemetry  ─────┼─► Collector.Session ─► Recorder (bounded) │
 │  Poller samples ─┘        │                   │              │
 │                     detectors              freeze on finding │
 └───────────────────────────┼───────────────────┼──────────────┘
                             ▼                   ▼
                    Finding (v1 envelope)  sealed snapshot
                             └────────┬──────────┘
                                      ▼
                     Incident.Capsule  (redacted, ≤ 1 MiB, SHA-256 id)
                                      │
                                      ▼
                     Sentinel.Manifest (binds exact capsule bytes;
                                       confirmation only, no mutation)
                                      │
   disposable sandbox target(s) ──────▼─────────────────────────────
   Confirmation.run ─► Regression (2 fresh matching failures)
          │                 │
          │                 ├─► Minimizer   (delete whole steps)
          │                 ├─► Bisection   (adjacent boundary over
          │                 │                a host-declared list)
          │                 └─► CodingAgent.Handoff
          │                              │  (agent proposes bytes)
          │                              ▼
          │                 CandidateSubmission (declared unverified)
          │                              │
          └──────────────► Verification.run (2 before, 2 after)
                                         │
                                         ▼
                           RepairReport ─► DraftProposal ─► SourceOwnership
                                         │                      Dedup
                                         ▼
                           DraftCreation gate (disabled by default;
                                              test providers only)
```

## 1. Collect bounded evidence

A trusted host starts `Insider.Collector.Session` with an explicit environment,
authority string, clocks, a recorder classification, and the components it
wants: `:logger`, `:telemetry`, `:poller`. The session API rejects `:staging`
and `:production` before it creates any process, filter, handler, timer, or
monitor.

- The Logger collector installs a first-position primary filter so it sees
  crash and supervisor reports before they are turned into text. Logger callers
  do only bounded structural shaping and one fixed-slot ETS insertion; a
  separate process drains into the recorder.
- The Telemetry collector accepts only events named in a pure-data
  `Insider.Collector.Telemetry.Policy` allowlist, and only the scalar
  measurement and metadata fields that policy names.
- The Poller records scalar samples (queue length, memory, reductions, status,
  registered name, current function) for at most 32 explicit local processes.
  It never copies mailbox contents, process dictionaries, links, monitors, or
  stack traces. When asked (Insider Live asks by default), it also ranks every
  local process by mailbox length, memory, and reductions since the last
  sample, and every ETS table by memory and size, reading only scalar
  counters and names, and reports Insider's own processes and tables apart.

Everything lands in `Insider.Recorder`, a fixed-size pre/post-trigger store.
Admission is direct and bounded: `record/2` returns `{:dropped, reason}` under
pressure, rate limits, or classification failure rather than queueing, and the
snapshot keeps those gaps visible.

## 2. Detect and freeze

Detectors are pure reducers over normalized events:
`Insider.Detectors.RestartRecurrence` (three abnormal terminations of distinct
child incarnations under one logical supervisor/child identity, by default)
and `Insider.Detectors.MailboxGrowth` (a configured run of strictly increasing
queue samples with an unchanged reductions counter and no sampling gap). A
collector session does not run detectors by itself. The host, or a Lab
capture workflow such as `Insider.Incident.RestartCapture`, feeds normalized
events into a detector and freezes the recorder when it emits a finding,
which seals the window around the trigger.

## 3. Seal a capsule

`Insider.Incident.Capsule` assembles the sealed snapshot, the normalized
finding, provenance (code, configuration, dependencies, runtime, and target,
each independently fingerprinted or explicitly unavailable), audit authority,
and digest-only artifact references into one deterministic, redacted document.
The redaction gate runs on every export root with a trusted
`Insider.Redaction.Policy`; undeclared secret data drops by default and any
failure yields no partial output. The POC capsule accepts at most 64 events,
32 artifact references, and 1 MiB of canonical JSON, and rejects larger
snapshots instead of truncating them silently. Its canonical decoder validates
corruption and alternate encodings offline, with no live node.

## 4. Hand off to Sentinel

`Insider.Sentinel.Manifest` (Lab-only) binds the exact capsule id, byte size,
and full-byte digest, lists which prerequisites are available, unavailable, or
redacted, and carries a fixed execution policy: purpose `confirmation`, source
mutation `prohibited`, target class `disposable`. The manifest is a reference,
not a second copy of the evidence, and it conveys no execution authority.

## 5. Reproduce, regress, shrink, bisect

Everything from here runs in the separate `tools/insider_lab` project against
disposable sandbox targets supplied by a trusted provider allowlist. The core
never invokes a shell, filesystem, network, node, container, or cloud API.

- `Insider.Sentinel.Confirmation.run/6` validates manifest, capsule, scenario,
  and target provenance together, then runs the portable scenario on a leased
  target and records one of five outcomes: `matching_failure`,
  `nonreproduced`, `repaired`, `unrelated_failure`, or
  `infrastructure_failure`.
- `Insider.Sentinel.Regression` turns one eligible confirmation plus its
  scenario into a data-only regression recipe. `Regression.classify/2` reports
  `failed` only when two fresh, distinct confirmation runs both reproduce the
  same incident on the same baseline target with complete evidence and cleanup.
- `Insider.Sentinel.Minimizer.run/6` tries deleting whole scenario steps, three
  fresh confirmations per candidate, and stops when no single remaining step
  can be removed. It does not claim a globally smallest reproducer.
- `Insider.Sentinel.Bisection.run/6` binary-searches a host-declared ordered
  list of 2 to 64 targets, proving both endpoints first, and isolates one
  adjacent nonreproduced/reproducing pair. Insider never reads a repository or
  orders revisions; the host supplies the list and owns the assumption that
  outcomes are monotonic across it.

## 6. Propose and verify a repair

- `Insider.Sentinel.CodingAgent.Handoff` packages the capsule, manifest,
  regression, and two fresh failed confirmations into one bounded request with
  a fixed objective: propose a candidate in the
  `insider.verification-candidate/v1` format. It accepts no caller-authored
  instructions or causal claims.
- A coding agent answers with opaque bytes (at most 16 KiB, format `opaque/v1`
  or `unified-diff/v1`). `CandidateSubmission` binds those bytes to the exact
  handoff and labels them `declared_unverified`.
- `Insider.Sentinel.Verification.run/7` runs two fresh live confirmations
  against the regression baseline (they must fail), then two independent
  post-repair sandbox runs through a host-allowlisted body module. The record
  is `verified` only when both after-runs observe no failure, agree on changed
  code and unchanged configuration/dependencies/runtime/target provenance,
  carry distinct positive oracle receipts, clean up completely, and leave the
  executor with zero active and zero quarantined leases. Otherwise it is
  `invalid` with sorted machine-readable reasons.

## 7. Produce inert review artifacts

`Insider.Sentinel.RepairReport.Manifest` recomputes a canonical report from the
capsule, manifest, and verification record and renders deterministic Markdown
with no caller-authored success prose. `Insider.Sentinel.DraftProposal` rechecks
the full five-run matrix and records `network_effect=none` and
`repository_mutation=none`. `SourceOwnership` derives routing hints from the
diff paths and a small declaration syntax; `Dedup` groups capsules and proposals
by finding fingerprint in a bounded in-memory ledger.

The last gate, `Insider.Sentinel.DraftCreation.Executor`, is disabled by
default and, in this phase, has only test-fixture providers. Every request it
would make is draft-only, requires human review, carries no credentials, and
exposes neither merge nor deploy. There is no real GitHub or network provider.

## What a complete proof means

[The proof workflow](../../docs/sentinel-and-proof-workflow.md#proof-workflow)
states it exactly: the same bounded causal fingerprint appears
before the repair, a regression fails before and passes afterward, the healthy
control remains quiet, resources are cleaned up, overhead is measured, and an
independent reviewer validates the evidence. Anything short of that is
reported as `inconclusive`, `invalid`, `not_proven`, or `nonreproduced`, never
rounded up to success.
