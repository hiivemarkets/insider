# Insider

Runtime evidence for the BEAM, structured for coding agents.

Insider is an Elixir library and a set of development tools that turn the
signals a running BEAM system already produces (OTP crash and supervisor
reports, Logger events, Telemetry events, process and VM counters) into bounded,
redacted, content-addressed evidence. That evidence can be detected against,
captured into a portable capsule, reproduced on a disposable target, minimized,
bisected, and used to verify a candidate repair, with every step producing a
record that says exactly what was observed and what was not.

Insider is a pre-release proof of concept. Its
protocol, APIs, and package layout are not stable. Production use is explicitly
outside the current phase, and the project's own readiness artifacts conclude
that staging and production observation remain denied.

## The problem

A failing test, a restart storm, or a growing mailbox is easy to notice and hard
to prove. The usual artifacts are an exit status, a stack trace, or a log line:
enough to suspect a cause, not enough to confirm one, and not enough for a
coding agent to act on without guessing. Agents given raw access to a live node
can observe too much, change too much, and mistake a plausible hypothesis for a
confirmed one.

Insider's position is that the loop around the signals is the valuable part:

- correlate evidence from several sources into one normalized stream with
  explicit identity and ordering;
- keep the causal window around a trigger in a fixed-size recorder;
- export a sealed capsule that can be validated offline, without the original
  node;
- reproduce the failure on a clean, disposable target, and record it as
  `nonreproduced` when it does not reproduce;
- turn a confirmed reproduction into a regression, shrink it, and locate the
  boundary where it starts reproducing;
- verify a candidate repair before and after, and produce an inert draft
  proposal for a human to review.

Every one of those steps is bounded by time, events, bytes, and targets, reports
truncation and uncertainty, and refuses to grant itself authority it was not
configured with.

## Who it is for

**Engineers** who want a precise, reviewable record of a runtime failure rather
than a hunch, and who want a coding agent to work from that record instead of
from the live system.

**Coding agents** that need machine-readable candidates, oracles, and
verification artifacts with closed vocabularies, explicit limits, and no
ambiguity about what has and has not been proven. The agent-facing pages in
this documentation are written for them.

## What it is not

Insider does not replace Sentry, Datadog, or an observability platform; its
provider mappings are deterministic mock data marked `mock: true` and
`delivery_status: not_attempted`. It does not evaluate arbitrary code in
production, inject faults, trace every function or message, or replay the VM.
It does not merge or deploy anything. It does not find business-logic bugs that
have no observable failure or declared invariant, and it does not claim to find
bugs in the BEAM itself. A full list is in
[Safety and non-goals](../../docs/disclosure-and-safety.md#safety-and-non-goals).

## Where to go next

- [How a session works](how-a-session-works.md) walks the loop end to end.
- [The safety model](safety-model.md) explains the boundaries in plain words.
- [What exists today](what-exists-today.md) separates landed code from
  deliberate gaps.
- [Try it locally](try-it-locally.md) is the shortest path to running the
  quality gate, the candidate inventory, an oracle, and the load harness.
- The [documentation index](../../docs/README.md) leads to the long-form
  reference; the guides are curated entry points into it.
- Operating manuals for agents start at
  [`mix insider.candidates`](../agents/candidates-cli.md).
