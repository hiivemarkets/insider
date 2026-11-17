# Status and roadmap

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

What works at this revision, and the phases of the roadmap.

## Contents

- [Current status](#current-status)
  - [Core evidence pipeline](#core-evidence-pipeline)
- [Live observation status](#live-observation-status)
- [Lab investigation status](#lab-investigation-status)
- [Roadmap](#roadmap)

## Current status

Each table lists one capability per row. "Core" is the root `:insider`
application. "Lab" is the separate `tools/insider_lab` project, published as `insider_lab`.
Notes under each table hold the limits that a row does not show. The status
continues in [Live observation status](#live-observation-status) and
[Lab investigation status](#lab-investigation-status).

### Core evidence pipeline

| Area | What works today | Where it lives | Section |
|---|---|---|---|
| Build and gates | The Mix application and the quality gate | Core | [Checks and gates](development.md#checks-and-gates) |
| Protocol | The bounded v1 protocol | Core | [Module boundaries](architecture.md#module-boundaries) |
| Runtime policy | Deny-by-default authorization from trusted runtime context, with bounded audit evidence | Core | [Module boundaries](architecture.md#module-boundaries) |
| Fault fixtures | Paired faulty and healthy fixtures that emit raw runtime measurements | Lab | [Repository layout](development.md#repository-layout) |
| Event schema | The normalized event v1 schema | Core | [Module boundaries](architecture.md#module-boundaries) |
| Identity | Explicit same-node identity | Core | [Module boundaries](architecture.md#module-boundaries) |
| Recorder | The bounded priority recorder | Core | [Module boundaries](architecture.md#module-boundaries) |
| Logger ingress | Structured OTP Logger ingress | Core | [Supervised collector sessions](collectors.md#supervised-collector-sessions) |
| Restart recurrence | The first detector | Core | [Restart-recurrence detector](collectors.md#restart-recurrence-detector) |
| Redaction | The fail-closed redaction primitive and its Event-compatible manifest | Core | [Redaction boundary](disclosure-and-safety.md#redaction-boundary) |
| Provenance | Bounded portable provenance | Core | [Portable provenance](incident-capsules-and-provenance.md#portable-provenance) |
| Capsules | Offline-validating, content-addressed incident capsules | Core | [Incident capsules](incident-capsules-and-provenance.md#incident-capsules) |
| Runtime polling | Bounded scalar polling of explicit same-node processes | Core | [Bounded runtime polling](collectors.md#bounded-runtime-polling) |
| Mailbox growth | A conservative bounded detector | Core | [Mailbox-growth detection](collectors.md#mailbox-growth-detection) |
| System events | An opt-in system-event collector | Core | [System-event collector](collectors.md#system-event-collector) |

- The capsule boundary accepts restart-recurrence, mailbox-growth, and
  declared semantic-invariant findings. They arrive through one
  detector-neutral wire envelope. Legacy restart capsules still verify.
- The fixtures emit raw runtime measurements without detector verdicts.
- The policy evaluates requests against trusted runtime context. It ignores
  environment or capability fields that a caller claims.
- The mailbox-growth detector separates sustained growth without reductions
  from bursty recovery and from declared intentional buffering.
- The system-event collector uses isolated OTP 28-29 trace sessions. On OTP 27
  it has an explicit legacy mode that refuses conflicts. It projects hostile
  messages into a closed shape, disables itself on overload, and accounts for
  loss within bounds.
- Generic adopter adapters and additional detectors are future work.

## Live observation status

| Area | What works today | Where it lives | Section |
|---|---|---|---|
| Live session | One leased collector session inside a development, test, or CI node | Core | [Live observation](live/live-api-and-transports.md#live-observation) |
| Reads | Redacted events after a recorder cursor, with eviction and loss gaps | Core | [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps) |
| Subscriptions | Monitored subscriber batches | Core | [Subscriptions](live/live-sessions-and-readers.md#subscriptions) |
| Tidewave | Live through Tidewave `project_eval` | Core | [Tidewave `project_eval`](live/live-api-and-transports.md#tidewave-project_eval) |
| Observer node | `mix insider.live` and `insider-lab live` over Erlang distribution | Lab | [Observer node](live/live-api-and-transports.md#observer-node-erlang-distribution) |
| Welcome | A welcome document generated from the code | Core | [Welcome document](live/live-welcome-and-reports.md#welcome-document) |
| Agent reports | Bounded, deduplicated reports about Insider itself | Core | [Agent reports](live/live-welcome-and-reports.md#agent-reports) |
| Disclosure | Host-chosen rich or strict profile | Core | [Disclosure profiles](disclosure-and-safety.md#disclosure-profiles) |
| Process and ETS | Per-interval rankings of processes, ETS tables, and ports | Core | [Process and ETS evidence](live/live-runtime-evidence.md#process-and-ets-evidence) |
| One-shot inspections | `process`, `bin_leak`, `ports`, `alloc` | Core | [One-shot inspections](live/live-runtime-evidence.md#one-shot-inspections) |
| Call traces | Calls and failures of named functions (OTP 28 and later) | Core | [Call traces](live/live-runtime-evidence.md#call-traces) |
| Telemetry discovery | `discover` lists the Telemetry event names a node can emit | Core | [Telemetry discovery](live/live-runtime-evidence.md#telemetry-discovery) |
| Exemplars and trends | Summary exemplars and `trends` | Core | [Summary trends](live/live-digest-filters-and-trends.md#summary-trends) |
| Logger bursts | Floods counted per message template and call site | Core | [Filters, summaries, and views](live/live-digest-filters-and-trends.md#filters-summaries-and-views) |
| Digest | `digest` over a recent window, anomalies first | Core | [Digest](live/live-digest-filters-and-trends.md#digest) |
| Baseline | Anomalies in a known-normal baseline are hidden | Core | [Known-normal baseline](live/live-digest-filters-and-trends.md#known-normal-baseline) |
| Pairing marks | `mark`, `marks`, and `--since-mark` | Core | [Pairing marks](live/live-sessions-and-readers.md#pairing-marks) |
| Pairing chart | `chart` writes a page of the session for the programmer; `chart --serve` serves it live on 127.0.0.1 | Lab | [Pairing chart](live/live-sessions-and-readers.md#pairing-chart) |
| OpenTelemetry | Spans of the node's SDK, joined into traces (OTP 28 and later) | Core | [OpenTelemetry spans and traces](live/live-otel-traces.md#opentelemetry-spans-and-traces) |
| Frontend traces | A frontend's spans added through the OTLP receiver | Lab | [Frontend traces](live/live-otel-traces.md#frontend-traces-otlp-http-receiver) |
| GraphQL outcome | The outcome on spans and Telemetry events | Core | [GraphQL outcome](live/live-otel-traces.md#graphql-outcome) |
| Query shapes | A trace groups its repeated query shapes | Core | [Repeated query shapes](live/live-otel-traces.md#repeated-query-shapes) |
| Request waits | Each request's wait | Core | [Request waits and bursts](live/live-otel-traces.md#request-waits-and-bursts) |
| Mutation records | A kept record of each GraphQL mutation | Core | [Kept mutation records](live/live-otel-traces.md#kept-mutation-records) |
| Value changes | `changes` names the writer of an in-memory value | Core | [Changes of in-memory values](live/live-runtime-evidence.md#changes-of-in-memory-values) |

- A supervised owner holds the Live session. `Insider.Live` has a
  canonical-JSON facade.
- The observer attaches a hidden, short-lived node to a local development,
  test, or CI target. It loads Insider into the target only with an explicit
  `--load`. `--load` replaces another Insider build only when Insider is not
  started. `--force-load` replaces a started Insider and ends its session.
- The welcome document carries a content hash, and a drift-guard test keeps it
  in step with the code.
- Agent reports reach GitHub only when an operator or the host opts in.
- The rich profile is the default in development and test. It shows Logger
  text and metadata, Telemetry metadata, and all measurements. The strict
  profile applies in ci and wherever live observation is denied. Callers may
  only narrow the profile. Every profile masks credentials.
- The poller component ranks processes by mailbox length, memory, and
  reductions since the previous scan. It ranks ETS tables by memory and size,
  in the style of `recon` but without depending on it. It counts ports by type
  and owner, with each type's growth (`port_top`). It samples named processes.
  It reports Insider's own processes, tables, and ports apart from the
  application's.
- One-shot inspections answer one bounded question about the node now. Their
  results join the session's history.
- The calls component traces in an isolated trace session it owns. It pairs
  each failure with the arguments that failed, rendered and capped in the rich
  profile. It removes the trace at stop, lease expiry, or amend. The receipt
  shows that the functions are no longer traced.
- `discover` reads attached handlers and the literal `:telemetry.execute` and
  `span` names in the debug info of loaded modules. It runs no application
  code. A session can subscribe to a discovered prefix such as `shop.*`.
  `status` reports each subscribed event's seen count, so an accepted but
  silent name reads as not emitted.
- A Telemetry summary names the receipts of its interval's slowest events and
  first error as exemplars. It reports the exemplar candidates it lost.
- `trends` lists each summary series across its windows in fixed units. It
  shows a duration's handler or caller scope only when the session declared
  it.
- Logger bursts keep at most 64 bursts an interval. The rest fold into a
  counted overflow row.
- `digest` reads what the Recorder admitted in the last minute by default.
  `latest-DURATION` selects another span. A cursor or `latest-N` selects
  receipts. The digest says which window it read, when that window starts, and
  how old its newest event is. Each hint names the window it was worked out
  over. The digest gives next-command hints.
- `mark` records the moment before a programmer acts in the app. `digest`,
  `trends`, `events`, and `timeline` then read only what came after it
  (`--since-mark`). `marks` lists the marks.
- `chart` reads with its own reader. `chart --serve` renews no lease, reads the
  window again when the host narrows the profile, and says on the page what it
  could not read.
- Mutation records need the telemetry component. They are kept apart from the
  Recorder.
- `changes` needs `watch_writes`.

## Lab investigation status

| Area | What works today | Where it lives | Section |
|---|---|---|---|
| Sentinel manifest | A content-addressed manifest that binds exact capsule bytes | Lab | [Collector-to-Sentinel handoff](sentinel-and-proof-workflow.md#collector-to-sentinel-handoff) |
| Scenarios | Portable bounded scenarios with deterministic semantic recipes | Lab | [Sentinel and proof workflow](sentinel-and-proof-workflow.md) |
| Sandbox lifecycle | A provider-driven lifecycle with owner-scoped leases | Lab | [Sentinel and proof workflow](sentinel-and-proof-workflow.md) |
| ExUnit candidates | A bounded, deterministic inventory of investigation candidates | Lab | [Agent-requested ExUnit candidates](lab-candidates-and-oracles.md#agent-requested-exunit-candidates) |
| Fixed oracles | Value-free oracles for application env, Telemetry, and OpenTelemetry globals | Lab | [Lab candidates and oracles](lab-candidates-and-oracles.md) |
| Oracle runs | `mix insider.oracle` runs one oracle against a test command | Lab | [Lab candidates and oracles](lab-candidates-and-oracles.md) |
| Actor differential | One operation run as several actors, with a value-free access verdict | Lab | [Lab candidates and oracles](lab-candidates-and-oracles.md) |
| Fault and rerun | A worker run with a declared provider fault and its retry | Lab | [Lab candidates and oracles](lab-candidates-and-oracles.md) |
| Privacy corpus | Synthetic Logger and Telemetry items through the real ingress code | Lab | [Privacy corpus runner](lab-cli.md#privacy-corpus-runner) |
| Draft repair | Phase 6 offline draft repair orchestration as inert artifacts | Lab | [Proof workflow](sentinel-and-proof-workflow.md#proof-workflow) |

- The Sentinel manifest reports external confirmation prerequisites. It
  conveys no execution authority.
- Scenarios define cleanup-reserved disposable execution. They do not claim
  deterministic BEAM replay.
- The sandbox lifecycle binds exact observed provenance to its leases. It
  reports cleanup complete only after an empty independent inventory. It
  quarantines any reclamation it cannot prove.
- Candidates have static application-env, Telemetry handler, and Telemetry
  event targets. Each carries oracle input hints.
- The fixed oracles cover up to sixteen application-env keys, dead
  `:telemetry_test` destinations on one exact event, and identity-only change
  detection of the OpenTelemetry default tracer and text-map
  injector/extractor globals.
- `mix insider.oracle` does not edit the target. It saves a versioned run
  record.
- An agent's probe test calls the actor differential. It runs the operation
  behind healthy controls.
- The fault-and-rerun oracle runs behind a healthy control. It reports
  orphaned or repeated effects.
- The privacy corpus runner takes caller-supplied items. It reports retained
  field names and canary coordinates without values. The application corpus
  and the field review stay human work.
- Broader target-local operations stay separate slices, each gated on
  evidence.
- Draft repair artifacts: a bounded coding-agent handoff built from a
  confirmed regression plus two fresh failed confirmations, a candidate
  submission bound to that exact handoff, a recomputed repair report, and an
  offline draft proposal that carries no disclosure approval.
- More draft repair artifacts: a source-ownership routing companion, a
  bounded in-memory dedup ledger, a whole-step scenario minimizer, and an
  offline bisection. The bisection runs over a host-declared ordered target
  list and isolates one adjacent nonreproduced/reproduced boundary.
- The candidate submission and the ownership routing are declared but not
  verified: Insider records what the submitter declares and does not check
  it.
- The draft-creation gate is disabled by default. Its only providers are test
  fixtures.
- One Lab integration test runs this chain end to end on a live sandbox
  executor. It checks that the same candidate identity threads through
  submission, verification, proposal, ownership, and the executor request.
- Before any provider authority, three items remain: a candidate-disclosure
  attestation, a real draft provider, and dedup persistence. Human review
  stays required.

## Roadmap

1. **Protocol and fixtures** (done): establish typed operations, environment
   policies, schemas, and deliberately faulty applications.
2. **Evidence pipeline** (done): normalize signals and produce a valid bounded
   capsule while a healthy control stays quiet.
3. **Reproduction loop** (done): reproduce on a clean target, persist a
   failing regression, and prove before/after repair evidence.
4. **Semantic and ecosystem expansion** (in progress): deepen contracts and
   add optional observer_cli, recon, Tidewave/MCP, property-testing, and Mob
   adapters. Mob is a mobile app framework on the BEAM.
5. **Production observation readiness** (in progress): threat-model and
   load-test a read-only collector, audit redaction, and design Sentry/Datadog
   integration. Production stays policy-denied. A bounded staging canary and a
   later production release each need a separate, revision-bound human
   decision.
6. **Offline draft repair orchestration** (in progress): add declared but
   unverified ownership routing, deduplication, bounded coding-agent handoffs,
   bisection, and evidence-gated draft proposals. Do this before granting any
   Git or PR provider authority. Human review stays required.
7. **Agent-directed investigation** (in progress): expose bounded candidate
   inventories and target-local evidence operations one proven slice at a
   time. Agents choose candidates and investigation steps. Insider supplies
   structured signals. It never treats a source heuristic as a confirmed
   defect.
