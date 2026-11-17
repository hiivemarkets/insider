# What exists today

This page separates landed, tested code from deliberate gaps. It mirrors
[Current status](../../docs/status-and-roadmap.md#current-status) and
[Roadmap](../../docs/status-and-roadmap.md#roadmap) and is updated in the same change as those
sections. Nothing here is a readiness claim; the project's own dossier
concludes that staging and production observation remain denied.

## Landed in the core (`lib/`)

| Area | What is implemented |
|---|---|
| Protocol | `insider.protocol/v1` with 19 closed operations, a bounded budget, typed errors, and effect-honest results with cleanup, confidence, and uncertainty fields. |
| Policy | Trusted runtime context, deny-by-default decisions with audit evidence, and a versioned protected-target inventory exported as `docs/protected-target-audit-matrix.json`. |
| Events and identity | Event v1 schema, canonical JSON with SHA-256 fingerprints, explicit same-node process generations and logical actors. |
| Recorder | Bounded priority recorder with direct admission, freeze and snapshot, a cursor read that needs no freeze and takes no admission lock, and a trusted classification binding. |
| Collectors | Logger (structured OTP reports), Telemetry (pure-data allowlist), Poller (scalar samples for at most 32 processes and named processes, and, when asked, recon-style process and ETS rankings with Insider's own footprint apart), and `Collector.Session` composing those three under one supervised root. SystemMonitor (OTP 28/29 isolated trace sessions, OTP 27 conflict-refusing legacy mode) runs standalone and is excluded from sessions pending a protected-subject ingress decision. |
| Detectors | `RestartRecurrence` and `MailboxGrowth`, plus a detector-neutral `Finding` envelope. |
| Redaction | Fail-closed `Redaction.redact/3` with a fingerprinted policy and a disclosure manifest. |
| Incident | Content-addressed Capsule v1 (64 events, 32 artifacts, 1 MiB) with offline validation and portable provenance. |
| Observability | Inert Trigger and Export contracts and deterministic Sentry and Datadog mock mappings; no client, transport, or delivery. |
| Runtime | `Insider.Runtime.describe/3` for one local PID under a host policy, available in development, test, and CI only. |
| Live observation | `Insider.Live` and `Insider.Live.JSON`: one leased live session owned by a supervised `Insider.Live.Owner`, cursor reads of redacted events with explicit gaps, and monitored subscribers, in development, test, and CI only. The Erlang-distribution observer node that drives it lives in Lab (below). |

## Landed in Lab (`tools/insider_lab`)

- `mix insider` (`capabilities`, `inspect --name`) over the protocol, and the
  `insider-lab` escript with `--discover`, `--json`, and `--ndjson`.
- `mix insider.live` and `insider-lab live`: a hidden, short-lived observer
  node that drives `Insider.Live` in another local BEAM node over Erlang
  distribution (`capabilities`, `start`, `events`, `status`, `renew`, `stop`,
  `watch`), with a cookie read from an owner-only file, loopback-only targets,
  and an explicit `--load` limited to development, test, and CI targets.
- `mix insider.candidates`: a bounded static inventory of ExUnit isolation
  signals with `application_env`, `telemetry_handler`, and `telemetry_event`
  targets that carry static `oracle` hints.
- Three fixed, value-free ExUnit oracle artifacts in `priv/oracles/`:
  application environment (one key or up to 16 keys), Telemetry dead
  `:telemetry_test` destinations on one exact event, and OpenTelemetry
  default-tracer and text-map propagator globals.
- An actor differential (`priv/probes/actor_differential.exs`) that an
  agent's probe test calls to run one operation as several roles, after
  checking that the entitled role succeeds, and report which roles were
  wrongly allowed or refused, without response or database values.
- A fault-and-rerun oracle (`priv/probes/fault_rerun.exs`) that an agent's
  probe test calls to run a background worker with one provider call made to
  fail and then retried, after checking that a clean run makes the expected
  effects, and report remote objects the retry orphaned or created twice,
  without provider ids or response values.
- `mix insider.privacy_corpus`: projects a synthetic corpus through the exact
  ingress handlers and reports retained field names and canary coordinates.
- Semantic contracts (`Insider.Contract`), invariants, portable scenarios, and
  the restart-storm, telemetry-lifecycle, and semantic-contract fixtures.
- The Sentinel chain: manifest, sandbox lifecycle with provider allowlist and
  owner leases, confirmation, regression, minimizer, bisection, coding-agent
  handoff and candidate submission, verification, repair report, draft
  proposal, source ownership, dedup ledger, and a disabled-by-default
  draft-creation gate whose only providers are test fixtures. One integration
  test runs the chain end to end on a live sandbox executor.
- A private bounded external-process primitive that lets a host-fixed
  provider, profile, and body run a confirmation across an OS-process
  boundary with one strict machine report.

## Landed in Load (`tools/insider_load`)

- `mix insider.load --profile PATH --output NEW_DIRECTORY` with checked-in
  `load` and `soak` profiles, canonical report and manifest, typed failure
  artifacts, and per-segment and per-cause missed-operation localization.
- `scripts/verify-load-evidence` recomputes digests and identities of emitted
  evidence directories offline.
- CI runs the load profile on pull requests across the supported Elixir/OTP
  matrix and the soak profile weekly.

## Readiness artifacts (`docs/`)

A production-observation threat model, a readiness dossier and evidence index,
a protected-target audit matrix, a staged-canary runbook, and a pre-canary
decision worksheet exist. They record what must be proven and by whom. The
worksheet records `authority: none`; the dossier concludes that a decision is
still required and staging remains denied.

## Deliberately not built yet

- Any staging or production observation. Both environments are refused in
  code; enabling either requires separate, revision-bound human decisions.
- A real draft provider (GitHub or otherwise), network delivery, credentials,
  or a candidate-disclosure attestation. The draft-creation gate exists with
  test providers only.
- Persistent dedup. The ledger is in-memory and has no eviction.
- Argument shrinking or StreamData-derived scenario inputs in the minimizer;
  version one deletes whole steps only.
- Repository reading, revision ordering, or checkout in bisection; the host
  supplies the ordered target list and in the current design targets in one
  list differ by provider identity.
- Live provider delivery for Sentry or Datadog; mappings are mock data.
- Generic adopter adapters, additional detectors, statistical anomaly
  detection, schedule exploration, distributed causality, and native
  lifecycle evidence.

## How to tell what a given revision proves

Each landed capability is paired with tests in the same project, and the
higher fidelity tiers are named in `AGENTS.md`. The CHANGELOG's `[Unreleased]`
section lists every user-visible change since the last release; the decision
log under `decisions/` records why boundaries are where they are. When the
documentation and the code disagree, the code wins and the documentation is corrected.
