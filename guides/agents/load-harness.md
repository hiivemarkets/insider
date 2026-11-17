# The load harness and `scripts/verify-load-evidence`

`tools/insider_load` is a separate, non-published Mix project that measures a
fixed-seed synthetic host workload without and then with a production-readiness
`Insider.Collector.Session`, and writes canonical evidence bound to the exact
revision, tree state, runtime, and profile. It is development and CI
measurement, not a budget. The authoritative description is the
[Load README](https://github.com/hiivemarkets/insider/blob/main/tools/insider_load/README.md);
this page is the operating contract.

## Run

```sh
cd tools/insider_load
mix deps.get --check-locked
mix insider.load --profile config/load.json --output ../../_build/insider_load/evidence/load
```

- Both `--profile PATH` and `--output NEW_DIRECTORY` are required; any other
  argument shape raises `usage: mix insider.load --profile PATH --output
  NEW_DIRECTORY`.
- The output directory must not already exist. Use a fresh path per run so
  evidence from different revisions, runtimes, or profiles is never mixed.
- Profiles are `config/load.json` and `config/soak.json`. They define the
  seed, workload phases, rates, collector bounds, sampling interval, and
  artifact limits. The report binds the selected profile's hash; a locally
  edited profile is not equivalent evidence.
- On success the task prints one JSON summary line with `artifact_directory`,
  `report_id`, `outcome`, `production_capacity`, and `budget_evaluation`, and
  exits 0 only when `outcome` is `passed`. A failed gate raises after writing
  the report; a harness failure before report construction raises with the
  typed reason and leaves a canonical `failure.json` and manifest when
  publication succeeded.

Every report records `production_capacity=false` and
`budget_evaluation=not_approved`.

## What fails the gates

Host-workload errors or any missed scheduled operation; unaccounted loss at any
collector ingress; missing pressure during the exact declared overload
interval; a required runtime measurement that is unavailable (a numeric zero
never substitutes for availability); queues that do not drain after emitters
stop; incomplete cleanup; failure to start and stop a fresh session.

## Reading `scheduling`

Each phase summary carries a `scheduling` section next to `host`:

- `missed_by_segment`: counts for `warmup`, `steady`, `overload`, `recovery`.
  Warmup precedes the measured interval and is reported but excluded from
  `host.missed_operations`; the other three sum to it, and `overload` equals
  `overload.missed_operations`.
- `missed_by_cause`: `skipped_tick` (a 10 ms tick deadline was overshot by at
  least one whole tick, so that tick's work never started) and
  `segment_end_remainder` (work still scheduled when the segment deadline
  passed, including a batch halted at that deadline). The two sum to
  `host.missed_operations`.
- `max_tick_lag_us`: the largest observed overshoot of any tick or segment
  deadline during the measured interval. Sub-millisecond lag is timer
  granularity.

A report whose sums do not reconcile is invalid. A phase that fails before its
workload completes reports every scheduled `steady` and `overload` operation
as `segment_end_remainder` so the failed report remains valid and keeps its
original failure reason. Cause attribution is summary-only; the per-sample
series keeps the cumulative `missed_operations` total.

## Verify an evidence directory offline

```sh
bash scripts/verify-load-evidence <dir> [<dir>...]
```

Requires `elixir` (OTP 27 or later) on `PATH` for the OTP `json` module. Exits
`2` on usage or missing `elixir`, `1` if any directory fails, `0` otherwise.
For each directory it prints one JSON line with `directory`, `git_sha`, `otp`,
`elixir`, `outcome`, `report_id`, `report_sha256`, `manifest_sha256`,
`profile_sha256`, `id_recomputed`, `mismatches`, and `ok`.

Checks, with the mismatch label each produces:

| Check | Labels |
|---|---|
| `manifest.json`, `report.json`, `profile.json` exist and parse | `missing_<stem>`, `unparsed_<stem>` |
| schemas are `insider.load-manifest/v1` and `insider.load-report/v1` | `manifest_schema`, `report_schema` |
| manifest lists both other files; every listed artifact's `sha256` and `byte_size` match disk | `manifest_artifacts`, `manifest_omits_<stem>`, `artifact_unreadable_<stem>`, `artifact_sha256_<stem>`, `artifact_byte_size_<stem>` |
| `id` equals `"sha256:" <> integrity.content_digest` | `manifest_id_integrity`, `report_id_integrity` |
| `report.inputs.profile_sha256` equals the sha256 of `profile.json` | `report_profile_binding` |
| manifest and report bytes equal their canonical encoding (keys sorted, compact, no trailing newline) | `manifest_not_canonical`, `report_not_canonical` |
| `id` equals the sha256 of the canonical body with `id` and `integrity` removed | `manifest_id_recomputation`, `report_id_recomputation` |

A non-canonical document fails because an identity cannot be recomputed for
bytes the writer did not produce. `id_recomputed` is true when both documents
were canonical, so it is always true when `ok` is. The script verifies
integrity and internal consistency only; it does not validate against the
current report schema or interpret the measurements.

## What the evidence is not

The workload is synthetic and local to the host it ran on. Reports retain no
raw Logger payloads, Telemetry values, event bodies, process identifiers, or
recorder handles, and `SystemMonitor` is excluded. Latency, throughput, CPU,
scheduler, memory, GC, resource counts, recovery, and leak slope are evidence
for a reviewer who also has a target topology, representative traffic,
approved budgets, retention requirements, protected-target declarations, a
canary design, and named approvers. None of those are in the repository.
