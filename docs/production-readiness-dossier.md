# Production-readiness dossier

Status: **decision required; staging and production denied**

This dossier assembles the evidence available for Insider's read-only runtime
collector. It is an assessment, not an authorization or deployment guide. No
staging candidate has been submitted because the service-specific evidence and
human approvals listed below do not yet exist.

## Scope and identity

- Candidate component: the root `:insider` Mix application only.
- Excluded component: `tools/insider_lab`, including Sentinel, deliberate fault
  fixtures, candidate repair, coding-agent, Git, and draft-provider machinery.
- Evidence revisions, all from the pre-release snapshot that preceded this
  repository:
  - `phase-5.5`: synthetic load baseline.
  - `phase-5.6`: mock-mapping load evidence.
  - `phase-5-6-7`: slice integration with missed-operation localization (two
    complete OTP 27/28/29 lane sets).
- Proposed canary revision and configuration fingerprint: **none**.
- Current authorization: **none**. The runtime continues to reject staging and
  production collector startup.

A future approval must name the exact merged revision and immutable host
configuration. Evidence from another revision is supporting history, not proof
for that candidate.

## What the evidence supports

| Gate | Current evidence | Assessment |
| --- | --- | --- |
| Package boundary | A production release gate rejects Lab modules, mutation/Git primitives, forbidden imports, and source links; it passes on the supported local runtime matrix. | Supported for the tested artifacts. |
| Ingress minimization | Staging/production profiles keep Logger payload and message semantics off, require structural Logger projection and exact Telemetry allowlists, and remain startup-denied. | Safe default is tested; no service privacy corpus has been reviewed. |
| Protected targets | Host-owned policy combines immutable OTP/Elixir inventory with additive application declarations. Callers cannot subtract protected targets. The committed [`protected-target-audit-matrix.json`](protected-target-audit-matrix.json) is a test-pinned, canonical derivation of that fixed inventory per supported OTP major, with the denial decision each fixed name and control-target class produces. | Mechanism supported; service targets and the exception-review owner are undeclared. |
| Lifecycle and containment | Supervised sessions expose health, stop, kill, bounded evidence flush, and inventory-backed cleanup. Component failures and hostile messages are isolated in tests. | Mechanism supported in development/CI only. |
| Synthetic performance | Revision/runtime-bound baseline and instrumented reports retain latency, memory, scheduler, loss, recovery, conservation, and cleanup measurements. | Measurement mechanics supported; no production budget is approved. |
| Provider mapping | Capsule-bound Sentry and Datadog mock bodies are deterministic, redacted, bounded, and fixed to `delivery_status: not_attempted`. | Local shape only; no client, transport, credential, endpoint, or provider acceptance. |
| Rollback | Kill/stop cleanup is tested and dependency removal is the durable design. | No adopting-service redeploy rehearsal exists. |

## Exact evidence retained

The machine-readable
[`production-readiness-evidence-index.json`](production-readiness-evidence-index.json)
records report identities and file hashes. The source evidence is retained on
one workstation outside the publishable library repository. It is untracked and
has no immutable portable URI, so another reviewer cannot independently fetch
it yet. This is a blocker, not durable publication.

For the Phase 5.6 tree, the local quality workflow passed on Elixir/OTP
1.17/27, 1.19/28, and 1.20/29. The current-toolchain deep gate passed strict
Credo, ex_dna, and Dialyzer; dependency audits were clean. GitHub-hosted jobs
did not run for this tree, so this is macOS/arm64 evidence and does not
establish Linux behavior or green GitHub Actions.

For the Phase 5.6 tree, the clean synthetic load report passed on OTP 27 and
OTP 29. The OTP 28 report failed because its instrumented phase missed 10
scheduled operations. Baseline, overload observation, cleanup, recovery, and
conservation passed. The failure was preserved without retry and remains
open. All reports state `production_capacity: false` and
`budget_evaluation: not_approved`.

Reports embed the revision of the pre-release snapshot they ran on. That
history is not part of this repository, so the index names each revision by
its label.

For revision `phase-5-6-7`, load reports carry the `scheduling` section that
localizes missed operations by segment and cause. Two consecutive complete lane
sets ran serially on one otherwise idle macOS arm64 workstation. Set one: OTP
27 failed (baseline missed 950 operations with a 90.7 ms maximum tick lag and
the instrumented phase missed 10 with 11.0 ms lag), OTP 28 passed, OTP 29
failed (baseline missed 40, 39.8 ms lag). Set two: OTP 27 passed, OTP 28
passed, OTP 29 failed (baseline missed 10, 12.0 ms lag). Every missed
operation in both sets is attributed to `skipped_tick` in the `steady`
segment; `segment_end_remainder` is zero everywhere. Four of the five failed
phases are uninstrumented baselines, so these misses measure host scheduler
stalls on the development workstation rather than collector overhead. The one
instrumented miss (OTP 27, set one) has the same 10-operation, one-tick
signature as the Phase 5.6 OTP 28 failure. No run was retried or discarded;
all six reports are indexed. This evidence does not resolve that failure and
does not establish behavior on a quiet Linux host or the target runtime. A
canary still requires fresh evidence bound to its exact candidate revision and
configuration.

## Blocking gaps

The following are required before a pre-canary approval can be considered:

1. Name the adopting service, staging topology, deployment mechanism, OTP
   version, collector sources, and representative event rates.
2. Measure an uninstrumented service baseline and approve CPU, memory,
   scheduler, host p95/p99 latency, loss, recovery, cleanup, and rollback
   budgets.
3. Resolve or explicitly understand the Phase 5.6 OTP 28 missed-operation
   failure and run the candidate on its actual target runtime.
4. Define capsule storage, tenant isolation, access control, retention,
   deletion receipts, and replay authorization. Local in-memory capture alone
   is not a durable data-lifecycle policy.
5. Run an application-specific privacy corpus through the exact Logger and
   Telemetry ingress allowlists and review every retained/exported field.
6. Declare protected application processes and the owner of exception review.
   OTP 27 node-global system monitoring remains excluded.
7. Rehearse durable rollback by disabling/removing the dependency, redeploying,
   and independently proving Insider-owned inventory empty.
8. Choose alerts, automatic-disable thresholds, cohort, duration, rollback
   deadline, evidence retention, and named maintainer, security/privacy,
   service, and on-call approvers.
9. Publish or otherwise grant reviewers immutable access to the exact evidence
   bundle whose hashes appear in the evidence index.

## Current decision request

The only evidence-supported decision today is:

> Continue development/CI evaluation. Do not authorize a staging canary or
> production observation. Fill the gaps above, bind an exact candidate revision
> and configuration, and return for human security, privacy, service, and
> operations review.

Agents may assemble or verify evidence. They cannot name approvers, accept
residual risk, broaden the candidate, or turn the non-authoritative worksheet
into an approval.
Production requires a separate post-canary dossier and decision even if a
future staging canary succeeds.

## Integrity and uncertainty

SHA-256 identifies content; it does not authenticate its author or source.
Passing a bounded synthetic scenario does not prove generalized bug freedom,
production capacity, provider acceptance, or safety under an unmeasured
application workload. Any changed revision, configuration, cohort, duration,
destination, privacy policy, or threshold requires a new decision.
