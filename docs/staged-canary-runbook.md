# Read-only staged-canary runbook

Status: **planning artifact only; execution is not authorized**

This runbook describes the operator sequence for a possible future staging
canary. It intentionally contains no deploy command, credential, endpoint, or
policy bypass. Until a completed pre-canary decision authorizes one exact
candidate, stop at the preparation gate.

## Roles

- Maintainer: owns the exact Insider revision and configuration fingerprint.
- Service owner: owns workload representativeness and application health.
- Security/privacy reviewer: approves ingress, retention, access, and outbound
  disclosure for the exact payload and destination.
- On-call operator: owns abort, containment, durable rollback, and escalation.

One person may hold more than one role only if company policy permits it. The
decision record must still name an accountable human for every role.

## Preparation gate

Do not proceed unless all of the following are present and mutually consistent:

1. A clean merged Git revision and production artifact inventory.
2. An immutable host configuration fingerprint covering environment, enabled
   sources, exact Telemetry allowlists, Logger structural profile, bounds,
   protected application targets, redaction/export policy, and destinations.
3. Representative baseline measurements and approved budgets.
4. A reviewed privacy corpus, retention/deletion policy, tenant boundary, and
   access-control owner.
5. A staging cohort, start/end time, alerts, automatic-disable conditions,
   rollback deadline, and evidence location.
6. A successfully rehearsed dependency-disable/redeploy rollback with empty
   owned inventory.
7. A separate authenticated human decision record that binds all exact values
   in `pre-canary-decision-worksheet.json` and explicitly authorizes only that
   canary. The worksheet itself has no authority and cannot be signed into one.

Absent or stale evidence means stop. Never infer approval from silence, a
passing test, a prior revision, or an agent recommendation.

## Required safe configuration

- Environment is staging and scoped to the approved cohort only.
- Raw Logger payloads and message-derived semantic identifiers are off.
- Telemetry metadata and measurements use exact reviewed allowlists.
- `SystemMonitor` and all tracing are off for the first canary.
- OTP 27 node-global monitoring is off unless separately approved.
- Protected OTP, Insider control-plane, and declared application targets cannot
  be removed by runtime input.
- Every duration, event, byte, target, rate, mailbox, and cleanup bound equals
  the approved configuration.
- Provider delivery is off. The current Sentry/Datadog mappings are mocks with
  `delivery_status: not_attempted`; they are not a transport.
- Sentinel, coding-agent, candidate repair, Git, merge, deploy, arbitrary
  evaluation, and fault injection are absent from the artifact.

## Start and observe

The current implementation cannot start this canary:
`IngressProfile.new(:staging)` sets `observation_enabled` to `false`, and
`Session.start/2` returns `:environment_denied` before collector side effects.
There is no exception mechanism. A completed decision worksheet does not change
that behavior. The remaining steps apply only to a later, separately reviewed
implementation and exact revision that introduces a bounded authorization
path.

The adopting application must own collector startup in its supervision tree.
Immediately after the authorized deployment:

1. Confirm the deployed revision and recompute the configuration fingerprint.
2. Confirm the cohort and wall-clock authorization window.
3. Read session health and verify the requested components, bounds, profile,
   protected-policy fingerprint, and empty initial loss counters.
4. Confirm host health and baseline alert state before treating the canary as
   started.
5. Record bounded health and evidence snapshots at the approved cadence. Do
   not scrape raw state or expand collection to diagnose the collector.

## Abort conditions

Contain immediately on any approved threshold breach and always on:

- customer/tenant/secret content in retained or exported evidence;
- host errors, restart loop, blocked application work, or unexplained latency;
- unaccounted loss, unavailable required measurement, or queue/resource growth;
- protected-target access, diagnostic ownership conflict, or stale handler,
  trace session, process, ETS table, timer, or monitor;
- configuration/revision/cohort drift;
- provider/network activity from Insider;
- missing approver coverage or expiration of the authorization window.

## Containment and cleanup

1. Invoke the host-owned kill switch to deny new admission and detach owned
   collectors.
2. Capture the terminal bounded receipt. A timeout or uncertain field is a
   failed cleanup claim, not success.
3. Independently inventory owned handlers, processes, monitors, timers, tables,
   trace sessions, and node-global diagnostic settings.
4. Escalate if inventory is not empty within the approved cleanup deadline.

The kill switch is containment. It cannot undo data already observed or an
external effect and is not durable rollback.

## Durable rollback

1. Disable or remove the Insider component/dependency through the adopting
   service's reviewed configuration or code path.
2. Redeploy using the service's normal rollback process.
3. Verify application health without Insider.
4. Independently prove Insider-owned runtime inventory empty.
5. Preserve the exact receipts, measurements, incident timeline, and residual
   uncertainty under the approved retention/access policy.

No automatic retry, threshold relaxation, broader serialization, or test
exclusion may turn a failed canary into a pass.

## Completion

At the authorized end time, stop the session and perform the same cleanup and
inventory checks even if no alert fired. A canary report must bind the exact
decision, revision, configuration, runtime, cohort, interval, measurements,
loss, cleanup, rollback evidence, and all deviations.

A successful staging canary does not authorize production. Production remains
denied until a separate post-canary human decision reviews that exact evidence
and exact proposed production configuration.
