# Insider documentation

This is the index of Insider's reference documentation. The
[README](https://github.com/hiivemarkets/insider/blob/main/README.md) is the
short synopsis. The [cheat sheet](cheat-sheet.md) has the commands you use
most, and the [glossary](glossary.md) defines the terms.

## Contents

- [How to use this index](#how-to-use-this-index)
- [Use Insider Live](#use-insider-live)
- [Lab and research](#lab-and-research)
- [Production readiness and development](#production-readiness-and-development)
- [Files](#files)
- [Other documents](#other-documents)

## How to use this index

- Find your task in one of the three tables below. Read only the section it
  names. A section runs from its heading to the next heading of the same or a
  higher level.
- Use the anchors as stable references. Line numbers change with every edit,
  so this index does not give them.
- The sizes are approximate line counts of the section, including its
  subsections. No linked section is longer than 150 lines. A test checks both.
- Each topic file starts with links back to this index, the glossary and the
  cheat sheet, then its own contents list.
- On a running node, the welcome document is the authority for the Insider
  that is loaded. Where it and these files differ, trust the welcome and file
  a `doc_mismatch` report.

## Use Insider Live

Live observation of a running development, test or ci node. This is what the
README describes.

| If you need to … | Read | Size |
|---|---|---|
| Run the commands you use most | [Cheat sheet](cheat-sheet.md) | ~115 lines |
| Look up a term | [Glossary](glossary.md) | ~265 lines |
| Install the CLI from Hex, or add Insider to your app | [Install the CLI](getting-started.md#1-install-the-cli), [Add Insider to your app](getting-started.md#add-insider-to-your-app) | ~16 + ~22 lines |
| Make first contact with a node you start | [Observe a running node in five minutes](getting-started.md#observe-a-running-node-in-five-minutes) | ~112 lines |
| Make first contact with a node you did not start | [Attach to a node you did not start](getting-started.md#attach-to-a-node-you-did-not-start), then [Load Insider into the target](live/live-api-and-transports.md#load-insider-into-the-target) | ~18 + ~29 lines |
| Know what the welcome document gives an agent | [Welcome document](live/live-welcome-and-reports.md#welcome-document) | ~67 lines |
| Find the commands for a symptom | [Welcome recipes](live/live-welcome-and-reports.md#welcome-recipes) | ~62 lines |
| Get the short operating contract for live observation | [Live observation guide](../guides/agents/live-observation.md) | ~190 lines |
| Choose an `Insider.Live` function or start option | [Live observation](live/live-api-and-transports.md#live-observation) | ~109 lines |
| Know who may observe a node, and for how long | [Environment and ownership](live/live-api-and-transports.md#environment-and-ownership), [Lease](live/live-api-and-transports.md#lease) | ~17 + ~17 lines |
| Look up an observer flag | [Observer flag reference](live/live-api-and-transports.md#observer-flag-reference), [Recording flags](live/live-api-and-transports.md#recording-flags-for-start-and-amend), [Read flags](live/live-api-and-transports.md#read-flags) | ~48 + ~27 + ~33 lines |
| Read without passing `--session` | [Default session](live/live-api-and-transports.md#default-session) | ~13 lines |
| Understand an exit status or observer error | [Exit statuses and error codes](live/live-api-and-transports.md#exit-statuses-and-error-codes) | ~46 lines |
| Run several agents at once | [Several agents at once: the escript](live/live-api-and-transports.md#several-agents-at-once-the-escript), then [Several agents on one session](live/live-sessions-and-readers.md#several-agents-on-one-session) | ~14 + ~115 lines |
| Observe through Tidewave `project_eval` | [Tidewave `project_eval`](live/live-api-and-transports.md#tidewave-project_eval) | ~31 lines |
| Stop a session and check what was cleaned up | [Stop and check the cleanup receipt](live/live-api-and-transports.md#stop-and-check-the-cleanup-receipt) | ~37 lines |
| Pair with a programmer who acts in the app | [Pairing marks](live/live-sessions-and-readers.md#pairing-marks), then [Digest](live/live-digest-filters-and-trends.md#digest) | ~41 + ~136 lines |
| Show the programmer you pair with a chart of the session | [Pairing chart](live/live-sessions-and-readers.md#pairing-chart) | ~46 lines |
| See what is wrong on the node right now | [Digest](live/live-digest-filters-and-trends.md#digest) | ~136 lines |
| Follow a digest hint | [Digest hints and text](live/live-digest-filters-and-trends.md#digest-hints-and-text) | ~71 lines |
| Hide anomalies you already know about | [Known-normal baseline](live/live-digest-filters-and-trends.md#known-normal-baseline) | ~33 lines |
| See how a series moved over time | [Summary trends](live/live-digest-filters-and-trends.md#summary-trends) | ~76 lines |
| Pages hang, but each request looks fast | [Request waits and bursts](live/live-otel-traces.md#request-waits-and-bursts), then [One-shot inspections](live/live-runtime-evidence.md#one-shot-inspections) | ~46 + ~136 lines |
| Investigate a stuck process or a growing mailbox | [One-shot inspections](live/live-runtime-evidence.md#one-shot-inspections), [Process and ETS evidence](live/live-runtime-evidence.md#process-and-ets-evidence) | ~136 + ~116 lines |
| Read one request as a trace | [Read one request as a trace](live/live-otel-traces.md#read-one-request-as-a-trace) | ~80 lines |
| Keep a trace past eviction | [Pin a trace](live/live-otel-traces.md#pin-a-trace) | ~52 lines |
| See the values a GraphQL response returned | [Response values](live/live-otel-traces.md#response-values) | ~42 lines |
| Find an N+1 or a repeated query | [Repeated query shapes](live/live-otel-traces.md#repeated-query-shapes) | ~49 lines |
| Follow an Oban job | [Oban jobs](live/live-otel-traces.md#oban-jobs) | ~17 lines |
| See everything one process or request did | [Timeline of a process or request](live/live-otel-traces.md#timeline-of-a-process-or-request) | ~19 lines |
| Find who sent a GraphQL request or mutation | [GraphQL outcome](live/live-otel-traces.md#graphql-outcome), [Kept mutation records](live/live-otel-traces.md#kept-mutation-records) | ~64 + ~37 lines |
| Find who changed an in-memory value | [Changes of in-memory values](live/live-runtime-evidence.md#changes-of-in-memory-values) | ~71 lines |
| See the arguments of calls to one function | [Call traces](live/live-runtime-evidence.md#call-traces) | ~132 lines |
| Join a frontend's spans to the backend's | [Frontend traces](live/live-otel-traces.md#frontend-traces-otlp-http-receiver) | ~56 lines |
| Record the node's OpenTelemetry spans | [OpenTelemetry spans and traces](live/live-otel-traces.md#opentelemetry-spans-and-traces) | ~90 lines |
| Find which Telemetry events a node emits | [Telemetry discovery](live/live-runtime-evidence.md#telemetry-discovery) | ~88 lines |
| Read events without missing any | [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps) | ~111 lines |
| Understand a gap or an empty read | [Gaps](live/live-sessions-and-readers.md#gaps), [Filtered counts](live/live-digest-filters-and-trends.md#filtered-counts), [Per-reader views](live/live-sessions-and-readers.md#per-reader-views) | ~47 + ~20 + ~12 lines |
| Change what a running session records | [Live amendment](live/live-sessions-and-readers.md#live-amendment) | ~24 lines |
| Quiet a noisy development server | [Filters, summaries, and views](live/live-digest-filters-and-trends.md#filters-summaries-and-views) | ~108 lines |
| Know what each disclosure profile shows and withholds | [What each profile shows and withholds](disclosure-and-safety.md#what-each-profile-shows-and-withholds) | ~89 lines |
| Know how credentials are masked | [Credential masking](disclosure-and-safety.md#credential-masking) | ~82 lines |
| Know why something was refused | [Error codes](live/live-welcome-and-reports.md#error-codes), then the [refusals guide](../guides/agents/refusals.md) | ~89 lines |
| Report a bug in Insider | [Agent reports](live/live-welcome-and-reports.md#agent-reports) | ~118 lines |
| Explain the safety model to a person | [The safety model guide](../guides/people/safety-model.md) | ~114 lines |
| Know where production stops | [Production boundary](disclosure-and-safety.md#production-boundary) | ~21 lines |

## Lab and research

The Lab is a separate Mix project, published to Hex as `insider_lab`. Its
tools and the Sentinel chain run only in development and disposable
environments.

| If you need to … | Read | Size |
|---|---|---|
| Chase a flaky test, or run one repeatedly | [Flaky tests: what Insider offers](lab-candidates-and-oracles.md#flaky-tests-what-insider-offers) | ~32 lines |
| Find test-isolation candidates | [Agent-requested ExUnit candidates](lab-candidates-and-oracles.md#agent-requested-exunit-candidates) | ~120 lines |
| Confirm a candidate with an oracle | [Application-env oracle](lab-candidates-and-oracles.md#application-env-oracle), [Handler and global-state oracles](lab-candidates-and-oracles.md#handler-and-global-state-oracles), [Oracle runner](lab-candidates-and-oracles.md#oracle-runner) | ~93 + ~122 + ~78 lines |
| Check who may perform an operation, or a retry after a fault | [Probe-library oracles](lab-candidates-and-oracles.md#probe-library-oracles) | ~72 lines |
| Drive `mix insider` or the Lab escript | [Lab CLI transport](lab-cli.md#lab-cli-transport) | ~84 lines |
| Check that a privacy corpus leaks nothing | [Privacy corpus runner](lab-cli.md#privacy-corpus-runner) | ~56 lines |
| Understand clean-target reproduction | [Collector-to-Sentinel handoff](sentinel-and-proof-workflow.md#collector-to-sentinel-handoff), [Confirmation and verification](sentinel-and-proof-workflow.md#confirmation-and-verification) | ~81 + ~94 lines |
| Shrink or bisect a reproduction | [Regression and minimization](sentinel-and-proof-workflow.md#regression-and-minimization), [Bisection](sentinel-and-proof-workflow.md#bisection) | ~63 + ~69 lines |
| Follow the offline repair chain | [Proof workflow](sentinel-and-proof-workflow.md#proof-workflow) | ~127 lines |
| Check an incident capsule or its provenance | [Incident capsules](incident-capsules-and-provenance.md#incident-capsules), [Portable provenance](incident-capsules-and-provenance.md#portable-provenance) | ~34 + ~14 lines |
| Run a supervised collector session in a host app | [Supervised collector sessions](collectors.md#supervised-collector-sessions) | ~111 lines |
| Know which detectors exist today | [Detection goals](collectors.md#detection-goals) | ~21 lines |

## Production readiness and development

Production readiness work grants no authority: staging and production
observation stay denied.

| If you need to … | Read | Size |
|---|---|---|
| Understand how the parts fit | [Architecture](architecture.md) | ~140 lines |
| Know what is implemented today | [Current status](status-and-roadmap.md#current-status), [Live observation status](status-and-roadmap.md#live-observation-status), [Lab investigation status](status-and-roadmap.md#lab-investigation-status) | ~42 + ~78 + ~59 lines |
| Know what the roadmap plans | [Roadmap](status-and-roadmap.md#roadmap) | ~26 lines |
| Contribute code | [Checks and gates](development.md#checks-and-gates) and [Repository layout](development.md#repository-layout), after [`AGENTS.md`](../AGENTS.md) | ~49 + ~27 lines |
| Find load and soak evidence | [Synthetic load and soak evidence](development.md#synthetic-load-and-soak-evidence) | ~22 lines |
| Release a version to Hex | [Releasing](development.md#releasing) | ~98 lines |

## Files

| File | What it holds | Size |
|---|---|---|
| [Getting started](getting-started.md) | Installing the CLI, the five-minute quick start, a node you did not start, the Tidewave variant, adding Insider to your app, repository setup, and a host `AGENTS.md` snippet. | ~207 lines |
| [Cheat sheet](cheat-sheet.md) | The most-used observer commands, by task. | ~115 lines |
| [Glossary](glossary.md) | Terms, and the ones that mean different things in Live, the Lab and the load harness. | ~265 lines |
| [Insider Live: API and transports](live/live-api-and-transports.md) | Functions and start options, environment, lease, cleanup receipt, Tidewave, and the observer node and its flags. | ~580 lines |
| [Insider Live: sessions, readers and marks](live/live-sessions-and-readers.md) | Cursors and gaps, Recorder shares, subscriptions, several readers, amendment, handoff, marks, the pairing chart, and event time. | ~483 lines |
| [Insider Live: digest, filters and trends](live/live-digest-filters-and-trends.md) | The digest, its hints and baseline, summary trends, filters, summaries, views, and severity. | ~580 lines |
| [Insider Live: processes, calls and Telemetry](live/live-runtime-evidence.md) | Process and ETS rankings, one-shot inspections, call traces, changes of in-memory values, and Telemetry discovery. | ~585 lines |
| [Insider Live: OpenTelemetry traces and GraphQL](live/live-otel-traces.md) | Spans, traces, query shapes, Oban jobs, pinned traces, response values, mutation records, timelines, request waits, the GraphQL outcome, and the OTLP receiver. | ~585 lines |
| [Insider Live: welcome, reports and error codes](live/live-welcome-and-reports.md) | The welcome document and its recipes, agent reports, and the error-code vocabulary. | ~435 lines |
| [Disclosure and safety](disclosure-and-safety.md) | The production boundary, profiles and what each withholds, rich rendering, credential masking, redaction, and non-goals. | ~390 lines |
| [Collectors and detectors](collectors.md) | The signals Insider reads, supervised collector sessions, the system-event collector, detectors, contracts, polling, and the same-node diagnostic API. | ~450 lines |
| [Lab: ExUnit candidates and oracles](lab-candidates-and-oracles.md) | The candidate inventory, the value-free oracles, the oracle runner, probe-library oracles, and flaky tests. | ~545 lines |
| [Lab: CLI transport and privacy corpus](lab-cli.md) | `mix insider`, the escript, acceptance hosts, the Recorder, collectors, ingress profiles, and the privacy corpus runner. | ~500 lines |
| [Sentinel and the proof workflow](sentinel-and-proof-workflow.md) | Confirmation, verification, regression, minimization, bisection, the offline repair chain, and deduplication. | ~600 lines |
| [Incident capsules and provenance](incident-capsules-and-provenance.md) | Capsules, provenance, and the inert observability trigger and export. | ~115 lines |
| [Architecture](architecture.md) | Purpose and the intended loop, the trust boundary, module boundaries, and the production artifact boundary. | ~140 lines |
| [Development](development.md) | Repository layout, checks and gates, load and soak evidence, documentation tooling, and releasing to Hex. | ~276 lines |
| [Status and roadmap](status-and-roadmap.md) | What is implemented, as tables, and the roadmap phases. | ~220 lines |

## Other documents

- Guides: short curated entry points for people (`guides/people/`) and agents
  (`guides/agents/`). Start with the
  [overview](../guides/people/overview.md) or the
  [live observation guide](../guides/agents/live-observation.md).
- [`usage-rules.md`](../usage-rules.md): the short rules for agents in a host
  app.
- Production readiness, which grants no authority: the
  [threat model](production-observation-threat-model.md), the
  [readiness dossier](production-readiness-dossier.md), and the
  [staged-canary runbook](staged-canary-runbook.md).
- [`AGENTS.md`](../AGENTS.md): rules for contributors and coding agents.
- [`CHANGELOG.md`](../CHANGELOG.md): release-facing changes.
- [Decision log](https://github.com/hiivemarkets/insider/blob/main/decisions/README.md):
  append-only records of trust, packaging, authority and protocol decisions.
- [Lab README](https://github.com/hiivemarkets/insider/blob/main/tools/insider_lab/README.md)
  and
  [Load README](https://github.com/hiivemarkets/insider/blob/main/tools/insider_load/README.md):
  the Lab, published to Hex, and the Load project, which is not.
