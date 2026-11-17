# Production observation readiness

Status: readiness baseline; production enablement is not approved

This document defines the evidence and decisions required before Insider may
observe a staging or production application. It is not an enablement guide.
The runtime policy must continue to deny non-baseline staging and production
operations. A pre-canary human decision may later authorize only one exact,
time-bounded staging canary; production remains denied until a separate
post-canary decision.

## Boundary

The proposed production component is a low-privilege, read-only collector. It
may normalize explicitly configured BEAM, Logger, Telemetry, and VM signals;
retain them within fixed local bounds; evaluate deterministic detectors; and
freeze a redacted incident capsule. It must have no source tree, coding model,
Git credentials, arbitrary evaluation, fault injection, code loading, repair
logic, or deployment authority.

`Insider.Sentinel`, deliberately faulty fixtures, candidate changes, and all
checkout or PR work belong in an external disposable environment. That
separation is now enforced by the root/Lab artifact boundary and production
artifact gate rather than only by runtime configuration. A future release must
rerun the gate for its exact revision.

Trusted configuration is constructed by the host while its supervision tree
starts. Runtime requests, captured events, and vendor callbacks cannot select
their own environment, authority, redaction policy, limits, or capabilities.
Vendor SDKs, credentials, transport retries, and network policy remain owned by
the host application.

## Proposed data flow

```text
allowlisted local signals
          |
          v
ingress minimization and shaping
          |
          v
bounded collector -> bounded recorder -> deterministic detector
                                             |
                                             v
                                  frozen redacted capsule
                                             |
                                  explicit export policy
                                             v
                              host-owned vendor integration

External Sentinel, source code, candidate changes, and Git are outside this
boundary.
```

## Assets and actors

| Asset | Required protection |
|---|---|
| Customer, tenant, and application data | Never collect by default; minimize before retention and redact before export. |
| Secrets, credentials, tokens, and cookies | Reject or redact at ingress; never use as labels, correlation values, or fingerprints. |
| Application availability and latency | Fixed admission, memory, time, and target bounds; isolation, overload shedding, and a kill switch. |
| BEAM control plane and critical processes | Deny observation that can block, trace, suspend, or materially inspect protected targets. |
| Incident capsules and provenance | Bounded retention, tenant isolation, content identity, export authorization, and explicit authenticity limitations. |
| Runtime policy and release configuration | Host-owned, immutable for a collector session, auditable, and never caller-selected. |

Actors are application operators, developers, coding agents outside production,
the host-owned observability integration, and untrusted application inputs that
may influence logs or telemetry. A compromised application process and a forged
local message are treated as untrusted signal sources; Insider does not claim
VM-authenticated causality from ordinary BEAM messages.

## Required defaults for a future production profile

- Staging and production observation remain denied by the current policy. Any
  later exception is revision-bound, environment-specific, time-bounded, and
  granted only by the applicable human gate below.
- The required, explicit host ingress profile keeps raw Logger payloads and message-derived
  semantic IDs/fingerprints off for staging and production. Those environments
  still deny collector startup; the safe structural contract also removes
  Logger subject, wall time, domain, causality, and all metadata-derived
  identifiers. The safe defaults are tested so a later gate cannot accidentally
  turn a payload, offender ID, reason fingerprint, or correlation ID into a
  second ingress channel.
- Telemetry metadata and measurements require exact configured allowlists.
  Customer identifiers are excluded unless a separately reviewed keyed
  correlation design is approved.
- Continuous message or function tracing is prohibited. Any later triggered
  trace must use an isolated session, exact target and MFA selectors, and an
  automatic cleanup deadline.
- OTP 27 node-global system monitoring is excluded from the first production
  profile. Supporting it requires a separate conflict and restoration decision.
- Critical OTP processes and the Insider control plane are denied targets.
  A host-owned immutable policy resolves a versioned OTP/Elixir runtime
  registry inventory (including the local OTP major and configured names) and
  binds the collector/recorder session before target inspection. Host
  declarations may add targets but adapters cannot remove or replace that
  inventory. Exceptions
  require an exact reviewed allowlist and remain read-only.
- `SystemMonitor` is passive node-global observation rather than explicit
  target inspection. Filtering protected subjects at that ingress is deferred
  to its dedicated production-profile work; it remains excluded from staging
  and production by the existing denial.
- Export is local-first and asynchronous. Vendor failure cannot block capture,
  application work, or collector cleanup.
- Collection failure degrades to visible loss or disabled health. It must not
  restart-loop, grow without bound, or terminate the host application.
- The kill switch disables new collection, detaches handlers or sessions, drains
  owned bounded work, and reports what could not be proven clean.
- Durable rollback disables or removes the production component or dependency,
  redeploys the host, and verifies that no owned handler, session, process, or
  inventory entry remains. The kill switch is emergency containment, not a
  substitute for this rollback.

## Threats, controls, and residual risk

| Threat | Required control | Residual risk to measure or review |
|---|---|---|
| Secrets or tenant data enter logs/telemetry | Minimize at ingress, exact allowlists, fail-closed redaction, adversarial canary corpus | Novel sensitive fields or keys can evade an incomplete policy. |
| Capsules cross tenant boundaries or outlive their purpose | Tenant-bound storage keys, deny-by-default access, fixed retention and deletion receipts, export tenant checks | Host identity or storage-policy defects can still misclassify an artifact. |
| An unauthorized actor reads, replays, or substitutes a capsule | Host-owned authorization, immutable content identity, bounded replay policy, access audit | Content identity detects change but does not authenticate the actor or original source. |
| Log or telemetry flood consumes CPU/memory | Fixed-slot admission, rate limits, byte/event bounds, shedding counters, auto-disable | ERTS may deliver a transient mailbox burst before the receiver runs. |
| Diagnostic work stalls a critical process | Scalar-only reads, protected-target policy, short deadlines, no production arbitrary evaluation | Some synchronous BEAM inspection has an unavoidable observer effect. |
| Forged local events create false causality | Source authority from trusted configuration, provenance and uncertainty, deterministic confirmation outside production | Ordinary process messages are not cryptographically authentic. |
| Collector crash harms the host | Separate supervision, bounded restart policy, circuit breaker, host-survival tests | Repeated VM or allocator pressure may affect both host and collector. |
| Stale Logger handler or trace session survives disablement | Owned session identity, detach/stop receipts, inventory-backed cleanup | Concurrent third-party diagnostics can race global OTP 27 facilities. |
| Vendor outage causes backpressure or duplication | Host-owned async client, bounded queue, idempotency key, circuit breaker, local freeze first | Eventual export can be delayed or lost according to the approved policy. |
| Hostile callback or configuration redirects data or expands collection | No vendor-controlled collection policy; exact endpoint allowlist; authenticated callbacks; outbound-only default; reject redirects and private/unapproved destinations | A compromised host configuration remains inside the host trust domain. |
| Transport or credential failure leaks or misroutes evidence | Host-owned secret retrieval, TLS verification, credential rotation tests, bounded authentication failure, destination audit | Vendor and certificate-authority compromise remain external dependencies. |
| Capsule tampering is mistaken for authenticity | Recompute canonical identity and state plainly that SHA-256 is identity only | Authenticity requires a future signing and key-management decision. |
| Supply-chain or package compromise expands authority | Minimal production artifact, locked dependencies, release audit, no Sentinel/fixtures | A compromised host application already shares the VM trust domain. |
| Coding agent acts on incomplete evidence | Observation/finding/defect/repair states, cleanup and provenance gates, human review | A valid bounded scenario does not prove generalized bug freedom. |

## Readiness evidence matrix

| Gate | Owner | Required artifact | Pass condition | Abort or rollback condition |
|---|---|---|---|---|
| Trust and package boundary | Maintainer + security reviewer | Package inventory and boundary decision | Production artifact excludes Sentinel, fixtures, mutation, Git, and agent code | Unexpected module, dependency, credential path, or mutable capability |
| Ingress privacy | Maintainer + privacy reviewer | Production profile and adversarial corpus report | Raw payloads off; every retained/exported field is allowed and canaries are absent | Secret/PII canary, unknown field, unbounded key, or redaction uncertainty |
| Artifact data lifecycle | Service owner + privacy/security reviewer | Tenant-isolation, access, retention, deletion, and replay test report | Tenant-bound access is deny-by-default; expiry and deletion produce receipts; replay cannot cross tenant or policy scope | Cross-tenant read/write, unauthorized access, stale artifact, unverifiable deletion, or unbounded replay |
| Protected targets | BEAM maintainer | Central policy and audit matrix. The committed [`protected-target-audit-matrix.json`](protected-target-audit-matrix.json) covers the mechanism half: it enumerates every fixed registration name and control-target class per supported OTP major with the denial decision the policy produces, derived from policy data without runtime inspection; application targets and the exception-review owner remain undeclared. | Critical OTP/application/control processes are denied consistently | Unreviewed target exception or diagnostic ownership conflict |
| Performance | Service owner | Revision- and runtime-bound load/soak report | Approved CPU, memory, scheduler, host-tail-latency, drop, and recovery budgets all pass | Any budget breach, leak slope, host error increase, or unaccounted loss |
| Failure isolation | Service owner | Chaos and cleanup receipts | Host survives component crash, stall, overload, disable, and restart; owned inventory empties | Host crash/block, restart loop, stale handler/session, or uncertain cleanup |
| Vendor and network boundary | Service owner + security reviewer | Pure mapping tests, endpoint/transport/credential audit, and host-client contract | Only bounded redacted summaries/IDs cross asynchronously to exact allowlisted destinations with authenticated transport and idempotency | Raw capsule/payload export, redirect or unapproved endpoint, callback authority, credential exposure, blocking network work, or retry growth |
| Operations | On-call owner | Runbook and durable rollback rehearsal | Health, alerts, kill switch, dependency/component disablement, redeploy, retention, outage behavior, escalation, and empty owned inventory are exercised | Operator cannot contain, redeploy without the component, or prove cleanup within the approved window |
| Pre-canary readiness | Maintainer + security/privacy + service/on-call | Signed revision-bound pre-canary dossier | Named humans accept the residual risk and authorize only the exact staging cohort, duration, thresholds, and release configuration | Missing evidence, stale revision, unresolved blocker, absent approval, or broader policy grant |
| Staged canary | Named pre-canary approvers | Time-bounded staging canary report | The authorized cohort completes with every prior gate still passing and durable rollback verified | Any threshold breach, privacy incident, uncertain cleanup, or unexplained host change; revoke the canary grant and roll back |
| Production readiness | Maintainer + security/privacy + service/on-call | Signed post-canary production dossier | Named humans review the canary evidence, accept residual risk, and authorize only the exact production release configuration | Missing or stale canary evidence, unresolved blocker, absent approval, or policy grant beyond the approved release |

Agents may assemble evidence for these gates. They cannot approve either human
decision. Pre-canary approval permits only its exact staging exception;
post-canary approval permits only its exact production configuration.

## Current evidence and gaps

The codebase already has bounded recorders, fail-closed redaction primitives,
component-level failure tests, cleanup receipts, overload accounting, and six
development benchmarks. On 2026-09-11, a clean pre-release revision ran
`mix run bench/composed_collector_pipeline.exs` on Elixir 1.20.3 / OTP 29. The
benchmark retained 5,120 events, shed the declared 1,024-event overload, lost no
recorder events, removed its handler, emptied its inbox, stopped its recorder,
and measured 3,834 events/second through the lossless composed path.

That run is a development baseline only. The benchmark itself reports
`production_capacity: false`; it did not embed its Git revision; and it does not
measure a real host workload, tail latency, CPU, scheduler utilization, garbage
collection, binary memory, mixed-source load, restart behavior, or leak slope.
Those omissions prevent a production claim.

The separate, non-published `tools/insider_load` harness adds reproducible
fixed-seed baseline/instrumented load and soak reports for those synthetic host
measurements. Reports and manifests are revision- and runtime-bound, and CI
retains them even when a structural evidence gate fails. This closes a
measurement-mechanics gap only: synthetic CI traffic does not supply the target
service inputs, approved budgets, production topology, or human approval needed
to pass the performance gate.

The harness records typed availability for every required runtime measurement,
temporarily enables scheduler wall-time accounting only inside its standalone
development/CI VM, and restores the prior setting. A clean synthetic report
also requires zero missed scheduled work, component-level and recorder-level
conservation, overload attributed to the declared interval, a terminal producer
quiescence barrier, fixed cleanup inventory, and a fresh-session restart.

The root artifact also has inert, bounded trigger and outbound-summary
contracts. The outbound projection revalidates a redacted capsule and requires
full capsule-bound rederivation before a host maps or delivers it. These
contracts add no SDK, endpoint, credential, queue, callback execution, or
network authority. Pure Sentry ingestion-event and Datadog Events v2 mappings
now project that same approved summary into frozen provider-shaped mock data.
The canonical wrapper is unconditionally marked `mock: true` and
`delivery_status: not_attempted`, requires host-owned asynchronous handoff
metadata, and must be recomputed against the complete capsule. The host-client
boundary is a behaviour contract with no implementation or invocation. This
closes only the local mapping-shape decision; provider acceptance, schema drift,
live delivery, and staging or production rollout remain unevidenced and denied.

## Decisions still required before pre-canary review

- target service, topology, deployment environment, OTP version, and observed
  source rates;
- CPU, memory, scheduler, host p95/p99 latency, loss, recovery, and cleanup
  budgets derived from an uninstrumented application baseline;
- capsule retention, storage location, access control, and tenant isolation;
- first vendor and data direction; the default recommendation is local-first,
  asynchronous outbound summary and incident ID through a host-owned client;
- exact protected application processes and the exception-review owner;
- named maintainer, security/privacy, service, and on-call approvers;
- canary cohort, duration, alerts, automatic-disable thresholds, and rollback
  deadline.

Until these are decided and evidenced, production remains unsupported rather
than silently best-effort.

## Shipped artifact boundary

The production candidate is now the root `:insider` Mix application only.
`tools/insider_lab` is a separate development project, published as its own
package, and is not a root dependency. Sentinel, fixtures, contract and invariant
execution, scenarios, CLI/Mix/escript entry points, external-process code, and
the restart-capture fixture harness are physically absent from the root source
and release. This preserves the existing staging and production denials; it
does not authorize a collector, publication, provider, credential, or network
integration.

`scripts/verify-production-artifact` fails closed after a fresh production
compile and release build. It rejects Lab source links, forbidden source/module
inventory entries, command/mutation primitives, Lab application contents, and a
release VM that can load any Lab-only module. The gate is run independently of
the Lab suite on every supported CI runtime lane.
