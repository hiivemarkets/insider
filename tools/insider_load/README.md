# Insider synthetic load harness

This separate, non-published Mix project produces bounded synthetic load and
soak evidence for the production-readiness collector session. It compares the same
fixed-profile, fixed-seed host workload without and with collection, then writes
canonical evidence bound to the checked-out revision and runtime.

It is a development and CI measurement tool. A successful run does not approve
a production budget, establish production capacity, or enable staging or
production observation. Every report records `production_capacity` as `false`
and `budget_evaluation` as `not_approved`.

## Run it

From the repository root:

```sh
cd tools/insider_load
mix deps.get --check-locked
mix insider.load --profile config/load.json \
  --output ../../_build/insider_load/evidence/load
```

For the longer soak profile, replace `config/load.json` with
`config/soak.json`. Use a new output path that does not already exist for each
run so artifacts from different revisions, runtimes, or profiles cannot be
mistaken for one evidence set.

The checked-in profiles define the seed, workload phases, rates, collector
bounds, sampling interval, and artifact limits. Change them only as reviewed
configuration: the report binds the selected profile rather than treating a
locally modified profile as equivalent evidence.

## Evidence and failure behavior

The output directory contains the canonical report with bounded measurement
samples and a content manifest for the complete evidence set. A typed failure
before report construction emits a canonical `failure.json` and manifest
instead. Report and failure bytes are verified through bounded reads of owned
regular file descriptors in private, restricted sibling staging directories
before publication. The public output directory is exclusively reserved and
its files are created exclusively; neither a partial public artifact nor a
competing entry is removed on failure. A verified failure-only artifact is
published if the output remains empty; otherwise publication failure is
explicit. Normal staging directories are removed after verification; one is
retained only when a substituted path or foreign content makes cleanup unsafe.

The report binds the repository revision and tree state, dependency-lock and
profile hashes, runtime and operating-system identity, scheduler configuration,
workload seed, and sample interval.

The harness fails closed when its structural evidence gates fail, including
host-workload errors or missed scheduled operations, unaccounted loss at any
collector ingress, missing pressure during the exact declared overload interval,
unavailable required runtime measurements, failure to empty bounded queues after
emitters stop, incomplete cleanup, or failure to start and stop a fresh session.
A nonzero exit normally leaves bounded output that explains the result. If
filesystem publication fails, the error is explicit and no complete artifact
is claimed. CI uploads output when present before it fails the job.

Measured latency, throughput, CPU, scheduler, memory, garbage collection,
resource counts, recovery, and leak slope are evidence, not universal pass
thresholds. Interpreting them requires a target service topology, representative
traffic, approved overhead and recovery budgets, retention requirements,
protected-target declarations, canary design, and named human approvers.

The workload is synthetic and local to the development or CI host. It uses no
network or vendor integration, credentials, source mutation, arbitrary
evaluation, or production authority. It excludes `SystemMonitor` and does not
retain raw Logger payloads, Telemetry values, event bodies, process identifiers,
or recorder handles in the report.

The standalone harness temporarily enables scheduler wall-time accounting for
the paired measurement and restores the exact prior VM setting afterward. A
required metric that remains unavailable is represented by typed availability
and fails the evidence gate; a numeric zero never substitutes for availability.

## Missed-operation localization

Each phase summary carries a `scheduling` section next to `host` so a nonzero
`missed_operations` count can be placed in time and attributed to a mechanism:

- `missed_by_segment` counts misses in `warmup`, `steady`, `overload`, and
  `recovery`. Warmup precedes the measured interval, so its count is reported
  but is not part of `host.missed_operations`; the other three sum to it, and
  `overload` equals `overload.missed_operations`.
- `missed_by_cause` separates `skipped_tick` (a 10 ms tick deadline was
  overshot by at least one whole tick, so that tick's scheduled work was never
  started) from `segment_end_remainder` (work still scheduled when the segment
  deadline passed, including a batch halted at that deadline). The two sum to
  `host.missed_operations`.
- `max_tick_lag_us` is the largest observed overshoot of any tick or segment
  deadline during the measured interval. A deadline is observed when the
  workload loop regains control, so a stall that ends after the segment
  deadline is measured against that deadline. Sub-millisecond lag is ordinary
  timer granularity.

A report whose sums do not reconcile is invalid. These counters do not change
any pass/fail gate; any nonzero `missed_operations` still fails the phase. The
per-sample series keeps only the cumulative `missed_operations` total; cause
attribution is summary-only. A phase that fails before its workload completes
(a workload fault, a collector session that cannot start, or a failed
instrumented measurement) reports every operation the profile scheduled in
`steady` and `overload` as `segment_end_remainder` misses, matching the
declared overload accounting, so the report stays valid and keeps the original
failure reason and cleanup evidence.

## Verify an evidence directory offline

`scripts/verify-load-evidence <dir> [<dir>...]` (repository root) re-derives
the integrity of emitted evidence without running the harness. For each
directory it recomputes the sha256 of `report.json`, `profile.json`, and
`manifest.json`, compares the report and profile against the manifest's
artifact digests and byte sizes, checks `report.inputs.profile_sha256` against
the profile bytes, and checks that each `id` equals its `integrity`
content digest. No mix task or escript recomputes artifact identities, so the
script re-encodes the parsed documents with the OTP `json` module (OTP 27 or
later) in canonical form (keys sorted, compact, no trailing newline). A
`manifest.json` or `report.json` whose bytes differ from that encoding is
reported as `manifest_not_canonical` or `report_not_canonical` and fails the
directory, because an identity cannot be recomputed for bytes the writer did
not produce; otherwise `manifest.id` and `report.id` are recomputed from the
canonical body with `id` and `integrity` removed. It prints one JSON line per
directory (`directory`, `git_sha`, `otp`, `elixir`, `outcome`, `report_id`,
`report_sha256`, `manifest_sha256`, `profile_sha256`, `id_recomputed`,
`mismatches`, `ok`) and exits nonzero if any directory fails. `id_recomputed`
is true when both documents were canonical, so it is always true when `ok`
is. The script verifies integrity and internal consistency only; it does not
validate the report against the current schema or interpret the measurements.

## CI

Pull requests run `config/load.json` on every supported Elixir/OTP pair. The
weekly schedule runs `config/soak.json`; a manual workflow dispatch can select
either profile. CI artifact names include the full Git revision and runtime
pair. Artifacts are retained for 90 days and uploaded before the recorded
harness exit status is enforced.
