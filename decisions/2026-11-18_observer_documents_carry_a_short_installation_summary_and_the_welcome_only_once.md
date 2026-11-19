# Observer documents carry a short installation summary and the welcome only once

Supersedes, in part,
[`2026-10-22_live_report_consent_is_scoped_per_source_and_welcome_is_delivered_on_connect.md`](2026-10-22_live_report_consent_is_scoped_per_source_and_welcome_is_delivered_on_connect.md):
its "Welcome on connect" rule that the first command of any operation
carries the quick start and that every later command carries a pointer. It
also narrows the `installation` object that
[`2026-10-23_observer_load_matches_builds_and_never_silently_ends_a_session.md`](2026-10-23_observer_load_matches_builds_and_never_silently_ends_a_session.md)
put in every observer document. The promise of
[`2026-10-22_live_sessions_are_shared_amended_in_segments_and_drained_after_stop.md`](2026-10-22_live_sessions_are_shared_amended_in_segments_and_drained_after_stop.md)
that every observer document reports `installation.insider_commit` stands.
Everything else in those records stands.

## Context

An agent new to the observer found that every JSON document opened with the
whole installation report (two build identities, the action, the pushed
applications, the environment), and that short receipts such as `mark` and
`amend` carried a welcome pointer, or the whole quick start when they
happened to be the first command. A `mark` after delivery was 1938 bytes,
of which the installation and the pointer were most; a `mark` as the first
command was about 41 KB. Reading the receipt was only practical by parsing
the JSON and dropping those keys.

## Decision

- **Installation summary.** `installation` is the whole report on
  `capabilities`, when the command loaded or started Insider (`action` other
  than `none`), and whenever `same_build` is false, so the `remedy` is never
  hidden. Every other ok document, the `subscribed` line of `watch`
  included, carries only `same_build`, `insider_version`, and
  `insider_commit`. Error documents are unchanged and carry no
  `installation`.
- **Welcome once.** The first command run against a target node incarnation
  carries the quick start under `"welcome"`, unless it is a short receipt:
  `mark`, `amend`, `stop`, `renew`, `chart`, `reports`, or `reports submit`
  (`Insider.Live.Welcome.observer_receipts/0`). A receipt neither carries
  nor delivers it; the next other command does. After delivery, only
  `capabilities`, the discovery command, carries the pointer with the
  delivered hash; every other command carries no `"welcome"` key. The
  compact `# welcome:` line follows, since it is printed only when the quick
  start is attached.
- Delivery stays recorded per node name and distribution creation, only
  after the carrying document was written; printing `welcome` still counts
  as delivery.

## Why

The fields a consumer acts on are `same_build` (is the target this build),
`insider_version` and `insider_commit` (is the escript stale). The build
identities and the push details matter at discovery, after a load, and when
the builds differ; repeating them on every receipt only adds bytes. Dropping
`installation` entirely from receipts was rejected because a decision and
the escript freshness rule promise `insider_commit` in every document.

The pointer on every command told an agent nothing new after the first
delivery. `capabilities` keeps it because that is where an agent compares
the delivered hash with the node's current `result.welcome.hash`. Delivering
the quick start on a receipt was rejected because a receipt is typically
read by a script or a short check, not by an agent orienting itself.

## Consequences

- A `mark` after delivery shrinks from 1938 to 550 bytes in the observer
  tests; a first `mark` no longer carries the 41 KB quick start.
- A consumer that read `installation.observer_build`, `target_build`,
  `action`, `pushed_applications`, or `environment` from any command must
  read them from `capabilities` (or a load) instead.
- A consumer that read `welcome.hash` from later commands must read it from
  `capabilities`.
- The welcome hash is still not compared on every command: a node whose
  Insider was replaced without a restart is noticed through `capabilities`
  (`welcome.hash` against `result.welcome.hash`) or a `--force-load`, which
  reports the whole installation.
- `tools/insider_lab/test/fixtures/live_watch_stream_v1.ndjson` pins the
  summary on the `subscribed` line and no `welcome` after delivery.
