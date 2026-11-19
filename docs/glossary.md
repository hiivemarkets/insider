# Glossary

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The terms that Insider's documents use, with the section that gives the
detail. Some words have more than one meaning. Each entry names every
meaning and tells them apart.

## Contents

- [Packages](#packages)
  - [insider vs insider_lab](#insider-vs-insider_lab)
- [Live observation](#live-observation)
  - [Session](#session)
  - [Owner](#owner)
  - [Observer](#observer)
  - [Component](#component)
  - [Recorder](#recorder)
  - [Receipt](#receipt)
  - [Cursor](#cursor)
  - [Gap](#gap)
  - [Reader](#reader)
  - [View](#view)
  - [Stored view](#stored-view)
  - [Mark](#mark)
  - [Window](#window)
  - [Baseline](#baseline)
  - [Lease](#lease)
  - [Disclosure profile](#disclosure-profile)
  - [Masking](#masking)
  - [Exemplar](#exemplar)
- [Lab and Sentinel](#lab-and-sentinel)
  - [Lab](#lab)
  - [Sentinel](#sentinel)
  - [Capsule](#capsule)
  - [Candidate](#candidate)
  - [Oracle](#oracle)
- [Production readiness and load](#production-readiness-and-load)
  - [Proof of concept](#proof-of-concept)
  - [Load profile](#load-profile)
  - [Production readiness](#production-readiness)

## Packages

### insider vs insider_lab

Insider ships as two Hex packages, always at the same version:

- **`insider_lab`** is the CLI: the `insider-lab` escript
  (`mix escript.install hex insider_lab`, then `insider-lab live …`) and
  the Mix tasks, such as `mix insider.live` and `mix insider.candidates`.
  Install it to observe a node. The app needs no dependency, because
  `--load` pushes the CLI's own Insider into the node.
- **`insider`** is the core library: the collectors, the Recorder and
  `Insider.Live`. It has no Mix tasks, by design. Add
  `{:insider, "~> 0.1", only: :dev}` to an app only for its agents (the
  usage rules and guides in `deps/insider/`) or for Tidewave
  `project_eval`.

An app that depends only on `insider` reports
`The task "insider.live" could not be found` for `mix insider.live`. Run
`insider-lab live` instead. See
[Install the CLI](getting-started.md#1-install-the-cli).

## Live observation

### Session

A Live session is one observation of a running node, started with `start`.
A node has at most one Live session, and several agents can share it. See
[Live observation](live/live-api-and-transports.md#live-observation).

A collector session (`Insider.Collector.Session`) is the lower-level host
boundary that runs the collectors with one Recorder. A Live session runs on
a collector session. See
[Supervised collector sessions](collectors.md#supervised-collector-sessions).

### Owner

The owner is the process in the target node that holds the Live session,
its lease, its readers, and its marks (internal: `Insider.Live.Owner`).
Insider starts it only where live observation is allowed. See
[Environment and ownership](live/live-api-and-transports.md#environment-and-ownership).

### Observer

The observer is the short-lived, hidden node that the `insider_lab` CLI
starts for one command: `insider-lab live`, or `mix insider.live` in an
Insider checkout. It calls `Insider.Live` in the target over Erlang
distribution, prints one JSON document, and stops. See
[Observer node (Erlang distribution)](live/live-api-and-transports.md#observer-node-erlang-distribution).

### Component

A component is one collector that a Live session runs: `calls`, `logger`,
`otel`, `poller`, or `telemetry`. `start --component NAME` chooses them.
Without the option, a session runs `logger`, plus `telemetry` when the node
has quiet default events. See
[Live observation](live/live-api-and-transports.md#live-observation).

### Recorder

The Recorder is the bounded in-node store of a session's events. It holds
16 to 4,096 events (`max_events`, default 4,096) and at most 4 MiB. When it
is full, it evicts the oldest event, and reads report the loss as a gap. See
[Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps).

### Receipt

The word has three meanings:

- **Event receipt.** The number that the Recorder gives each event it
  admits, consecutively from 1. Cursors and marks are receipts. See
  [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps).
- **Cleanup receipt.** The `receipt` (`insider.collector-session-receipt/v1`)
  that a stopped or expired session reports, as proof of its cleanup. See
  [Stop and check the cleanup receipt](live/live-api-and-transports.md#stop-and-check-the-cleanup-receipt).
- **Sentinel receipts.** The bounded records that Sentinel keeps of a
  confirmation, a verification, or a deduplication ledger entry. See
  [Collector-to-Sentinel handoff](sentinel-and-proof-workflow.md#collector-to-sentinel-handoff).

### Cursor

A cursor is the receipt that a read starts after. Cursor `0` is the start of
the session. Each read returns `next_cursor`, the cursor for the next read.
Cursor `latest` is the newest receipt, so its batch is empty and its
`next_cursor` starts a tail. See
[Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps).

### Gap

A gap is a known loss in a read: a `%{"reason", "count", "scope"}` entry in
`"gaps"`. An empty list means no known loss. Insider never loses events
silently. See [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps).

### Reader

A reader is a named agent that reads a session (`--reader NAME`). The
session tracks each reader's cursor and view, and `status` lists them. A
`stop` while another reader is active returns `readers_active`, unless the
caller adds `--force`. See
[Several agents on one session](live/live-sessions-and-readers.md#several-agents-on-one-session).

### View

A view narrows what a read shows, by source, kind, and minimum severity. It
never changes what the session records. A per-read view applies to one read
only, even with `--reader` (`--view-source`, `--view-kind`,
`--view-min-severity`).

### Stored view

A stored view is a named reader's view that later reads by that reader
apply when they give no view of their own. A read stores one only with
`--view-keep` (`"view_keep"`), and `--view-clear` clears it. A result that a
stored view narrowed carries `"stored_view"` and starts its text with a
`Note:` line. See
[Filters, summaries, and views](live/live-digest-filters-and-trends.md#filters-summaries-and-views)
and [Stored views](live/live-sessions-and-readers.md#stored-views).

### Mark

A mark is a labelled point in a session, made with `mark --label` just
before an action. It records a `live.mark` event at the newest receipt.
Reads with `--since-mark` start after it. A session keeps its newest 256
marks. See [Pairing marks](live/live-sessions-and-readers.md#pairing-marks).

### Window

The word has three meanings:

- **Digest window.** The receipts that a `digest`, `baseline`, or `trends`
  call reads, set by `--since` or `--since-mark`. See
  [Digest](live/live-digest-filters-and-trends.md#digest).
- **Mark window.** Everything after a mark, up to the newest receipt. See
  [Pairing marks](live/live-sessions-and-readers.md#pairing-marks).
- **Retention window.** The events that the Recorder still holds, plus the
  traces that a session keeps outside the Recorder: pinned, or kept by
  default because they failed, were slow, or ran a mutation. See
  [Pin a trace](live/live-otel-traces.md#pin-a-trace).

### Baseline

The word has three meanings:

- **Known-normal baseline.** The anomalies of a window that `baseline` marks
  as normal for a session. Later digests list them as known and lead with
  new ones. See
  [Known-normal baseline](live/live-digest-filters-and-trends.md#known-normal-baseline).
- **Load-test baseline.** The uninstrumented phases of a synthetic load run,
  which the instrumented phases are compared with. See
  [Synthetic load and soak evidence](development.md#synthetic-load-and-soak-evidence).
- **Oracle boundary.** The point in `test/test_helper.exs`, after any
  intended suite-baseline configuration, where an agent installs an oracle.
  See [Value-free application-env oracle](lab-candidates-and-oracles.md#value-free-application-env-oracle).

### Lease

The word has two meanings:

- **Live session lease.** The time a session lives without a renewing call:
  `lease_ms`, 1,000 to 900,000, default 120,000. When it runs out, the owner
  stops the session as `expired`. See
  [Lease](live/live-api-and-transports.md#lease).
- **Sentinel sandbox lease.** The owner lease on the resources of one
  Sentinel run. It is complete only when an independent owner inventory is
  empty. Otherwise it stays quarantined. See
  [Collector-to-Sentinel handoff](sentinel-and-proof-workflow.md#collector-to-sentinel-handoff).

### Disclosure profile

The disclosure profile decides what a Live session lets leave the node:
`rich` (payloads, rendered and bounded) or `strict` (opaque, shape-checked
values only). The host chooses it, and a caller can only narrow it. Do not
confuse it with a load profile or an oracle host profile. See
[Disclosure profiles](disclosure-and-safety.md#disclosure-profiles).

### Masking

Masking replaces credential-shaped values with `[REDACTED:<reason>]` in
every profile. It works by key name and value shape. Each mask adds a `mask`
record to the event's `"redactions"`, never the value. Redaction of portable
evidence is a separate, policy-driven step. See
[Credential masking](disclosure-and-safety.md#credential-masking) and
[Redaction boundary](disclosure-and-safety.md#redaction-boundary).

### Exemplar

An exemplar is a full event that a summary keeps as an example: up to three
of an interval's slowest events and its first error. The summary names each
by receipt, so an agent can open it. See
[Filters, summaries, and views](live/live-digest-filters-and-trends.md#filters-summaries-and-views).

## Lab and Sentinel

### Lab

The Lab is `tools/insider_lab`, a separate Mix project, published as
`insider_lab`, for development and disposable environments. It holds the
observer task (`mix insider.live`), its escript, the candidate inventory,
the oracles, and Sentinel. A production release cannot load Lab modules.
See [insider vs insider_lab](#insider-vs-insider_lab) and
[Repository layout](development.md#repository-layout).

### Sentinel

Sentinel is the Lab-only part that takes a capsule and tries to prove its
failure on a clean target. It confirms, verifies, makes a regression,
minimizes, and bisects. Then it hands off to a coding agent for a draft
proposal. See [Proof workflow](sentinel-and-proof-workflow.md#proof-workflow).

### Capsule

An incident capsule (`Insider.Incident.Capsule`) is a deterministic,
redacted artifact of one incident. It holds sanitized events, a finding,
provenance, and digest-only artifact references. It accepts at most 64
events, 32 artifact references, and 1 MiB of canonical JSON. See
[Incident capsules](incident-capsules-and-provenance.md#incident-capsules).

### Candidate

A candidate is one entry of the inventory that `mix insider.candidates`
writes: a test with static isolation or nondeterminism signals. It is a
heuristic, never a confirmed defect. See
[Agent-requested ExUnit candidates](lab-candidates-and-oracles.md#agent-requested-exunit-candidates).

### Oracle

An oracle is a fixed Lab-only check that answers one question about a
selected test run. It reports without values. Examples: whether a test
changed an application-env key, left a Telemetry handler behind, or changed
OpenTelemetry global state. See
[Oracle runner](lab-candidates-and-oracles.md#oracle-runner).

## Production readiness and load

### Proof of concept

A proof of concept is an early, deliberately small implementation that shows
an approach works. Insider as a whole is one, so its protocol, APIs, and
package layout are not stable. See
[Production boundary](disclosure-and-safety.md#production-boundary).

### Load profile

A load profile is the fixed-seed synthetic workload that `tools/insider_load`
runs without and with a collector session. It is not a disclosure profile.
The threat model's "future production profile" is a third meaning: the
defaults a production deployment would need. See
[Synthetic load and soak evidence](development.md#synthetic-load-and-soak-evidence).

### Production readiness

Production readiness is the evidence that production observation would be
safe. It grants no authority: staging and production observation stay
denied until separate human decisions enable them. See the
[threat model](production-observation-threat-model.md), the
[production-readiness dossier](production-readiness-dossier.md), and
[Production boundary](disclosure-and-safety.md#production-boundary).
