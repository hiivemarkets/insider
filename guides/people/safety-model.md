# The safety model

Insider is built so that the thing observing a system cannot become the thing
that damages it. The rules below are enforced in code and tests, not stated as
intentions. Each one is followed by where to look.

## Production observes; disposable environments mutate

The root `:insider` application is the only part that could ever run next to
an application. It contains collectors, detectors, the recorder, redaction,
capsules, policy, and a small runtime facade. It has no Mix task, escript,
fixture, scenario runner, Sentinel, command runner, or provider code. Those
live in the separate `tools/insider_lab` Mix project, which depends on the core
by path; the core never depends on Lab.

This is a packaging boundary, not a feature flag.
`scripts/verify-production-artifact` builds a production release, inventories
its source, application, beam, and release contents, and boots the release to
prove that Lab-only modules cannot load. `mix quality` runs that gate.

## Deny by default

Environments are five closed values: `development`, `test`, `ci`, `staging`,
`production`. Collector sessions, runtime diagnostics, and the system-event
collector accept only the first three. Staging and production are refused
before any process, filter, handler, or timer is created, and the refusal is a
typed error (`:environment_denied` from a session, an `invalid_request` error
from the runtime facade) rather than an exception. The one Lab tool that takes
`staging` or `production` is the privacy corpus runner, which projects
synthetic items through those profiles' allowlists and observes nothing.

Requests are evaluated against trusted runtime context supplied by the host at
startup, never against the environment or capability a request claims for
itself. A host-owned protected-target policy denies fixed OTP and Elixir
registrations and Insider's own session processes before any provider runs;
hosts can add protected targets but cannot remove the built-in inventory. The
exact denial table is committed as
`docs/protected-target-audit-matrix.json` and pinned by a test.

## Bounded in every dimension

Every protocol request carries a budget with four fields, each with a floor and
a ceiling: `max_duration_ms` (1 to 600,000, default 5,000), `max_events`
(1 to 100,000, default 1,000), `max_bytes` (16,384 to 16,777,216, default
1,048,576), and `max_targets` (1 to 100, default 1). Results report the
requested and effective limits, consumption, truncation, dropped counts,
cleanup status, confidence, and a list of named uncertainties.

The same discipline applies off the protocol path: the recorder has fixed
event and byte capacities; the poller samples at most 32 processes; the
mailbox detector keeps at most 32 samples for each of at most 4,096 keys; a
capsule holds at most 64 events, 32 artifact references, and 1 MiB; the
candidate scanner stops at 5,000 files, 64 MiB, 500 candidates, and 10 seconds
by default; the oracle artifacts cap handler lookups at 1,024 handlers, 1
second, and 262,144 heap words. Where a bound is hit, the output says so.

## Value-free by construction

Portable evidence contains structure, identities, counts, and fingerprints,
not the values that would make it sensitive:

- the recorder requires a trusted sensitivity and redaction-policy binding;
  event fields cannot select or downgrade it;
- redaction runs on every capsule root with a fingerprinted policy; undeclared
  secret data is dropped; a failed redaction produces nothing;
- the candidate inventory emits application-env keys and Telemetry event
  names, never configured values, callbacks, or executable terms;
- the three ExUnit oracles report presence and per-run HMAC fingerprints
  computed with a random key that is never exported, so two reports can be
  compared only within a run;
- the privacy corpus runner names retained field paths and canary coordinates
  and never emits a retained value;
- load reports retain no raw Logger payloads, Telemetry values, event bodies,
  process identifiers, or recorder handles.

## No authority is ever granted by an artifact

Sentinel documents that can have effects carry fixed `controls` that record
what they cannot do. A manifest permits confirmation only and prohibits source mutation. A
coding-agent handoff records `model_invocation=none`, `network_effect=none`,
`provider_effect=none`, `repository_mutation=none`. A candidate submission is
`declared_unverified` with `draft_eligible=false`. A bisection record pins
`repository_read=none`, `checkout=none`, `source_mutation=prohibited`,
`git_authority=none`, `network_effect=none`. A draft proposal records
`merge_prohibited=true` and `review_required=true`, and its eligibility carries
the reason `candidate_disclosure_attestation_missing`.

SHA-256 identities prove content, not authenticity. A record is trusted only
through the configured adapter or host that produced and validated it, and
every `validate_with_evidence` function recomputes the record from the exact
inputs before anything downstream accepts it.

## Humans make the decisions

The production-readiness dossier, evidence index, staged-canary runbook, and
decision worksheet under `docs/` describe what would have to be true; they
grant nothing. The worksheet records `authority: none`. A successful load run
records `production_capacity=false` and `budget_evaluation=not_approved`. The
draft-creation gate is disabled by default and requires a configured disclosure
authority, and even then produces draft-only requests that require review.
Staging and production remain policy-denied pending separate, revision-bound
human decisions.

## Honest about failure

Collector failure must not crash or block the host application; sessions run
under a dedicated `one_for_all` root so a manager failure resets the session
without touching unrelated children. Timeouts stop Insider from waiting but
cannot retract an inspection already delivered, so timeout evidence reports
observer-effect uncertainty. Cleanup is `complete` only when independent
inventory is observed empty; anything else is `partial`, `uncertain`, or
`unknown`, and leases whose cleanup cannot be proven are quarantined instead
of being reported as reclaimed. Missing oracle output is an infrastructure
failure, never a clean result.
