# Insider agent instructions

Insider is a runtime-evidence library for BEAM applications, built for coding
agents. Read the relevant section of the reference in `docs/` and the
relevant implementation and tests before changing a public contract, runtime
boundary, or safety policy.

Prototype workflow: keep intermediate refinement work local on `main` or in
isolated worktrees. Record commands, results, constraints, review findings, and
residual uncertainty in local task notes. GitHub is optional for sharing or
backup during iteration; open one PR when the prototype is ready for review.
Never push directly to remote `main`, publish, deploy, or weaken a gate without
explicit maintainer authorization.

## Additional info

[`docs/README.md`](docs/README.md) indexes the reference documentation. Its
task table names the file, the section anchor, and the approximate size, so
you can read one section instead of a whole file. The most-used entry points:

- [Cheat sheet](docs/cheat-sheet.md) and [Glossary](docs/glossary.md): the
  most-used observer commands, and the terms that mean different things in
  Live, Sentinel and the load harness.
- [Getting started](docs/getting-started.md): attach to a running node and
  set up this repository.
- [Disclosure and safety](docs/disclosure-and-safety.md): the profiles,
  masking, redaction, and the production boundary.
- [Development](docs/development.md): repository layout, gates, and load and
  soak evidence.
- [`usage-rules.md`](usage-rules.md) and [`guides/agents/`](guides/agents/live-observation.md):
  the short rules and operating contracts that host-app agents read.

## Repository map and project boundaries

Insider is three separate Mix projects in one repository. Decide which one a
change belongs to before editing:

| Project | Path | Purpose | May depend on |
|---|---|---|---|
| Core (`:insider`) | `lib/`, `test/` | Production-safe, bounded, read-mostly collector and evidence core: events, collectors, detectors, recorder, redaction, capsules, policy, runtime facade. | Its own deps only |
| Lab | `tools/insider_lab/` | Development and disposable-environment tooling: `mix insider`, `mix insider.candidates`, fixed oracles in `priv/oracles/`, Sentinel, scenarios, contracts, CLI. Published to Hex as `insider_lab`, at the core's version. | Core: by path here, from Hex in its package (`INSIDER_LAB_HEX=1`) |
| Load | `tools/insider_load/` | Synthetic load and soak evidence (`mix insider.load`). Never published. | Core, by path |

- The core never depends on Lab or Load, and it contains no escript, Mix task,
  fixture, scenario runner, Sentinel, command runner, or provider-mutation code.
  This is a physical packaging boundary, not a feature flag.
- A change that adds a core dependency, moves code between projects, or touches
  release contents must pass `bash scripts/verify-production-artifact`. That gate
  builds a production release and proves Lab-only modules cannot load.
- Other paths: `bench/` (hot-path benchmarks), `docs/` (the reference
  documentation, indexed by `docs/README.md`, and the production-readiness
  artifacts, which grant no authority), `decisions/` (append-only decision
  log), `fixtures/` (reserved for faulty apps and scenarios), `guides/` and
  `usage-rules.md` (agent guides and usage rules; `docs/`, `guides/` and
  `usage-rules.md` are listed in the `mix.exs` package files), `scripts/`,
  `.githooks/`, `.github/workflows/`.

## Hosting and conventions

- The repository is `hiivemarkets/insider`. The core and the Lab are
  published to Hex as `insider` and `insider_lab`. Publish only through
  [Releasing](docs/development.md#releasing), never from an agent session.
- Use the repository PR template for the final PR.
- `.github/CODEOWNERS` names the owner who must review changes to agent
  authority, hooks, and workflows.

## Toolchain

- Supported pairs, tested in CI: Elixir 1.17/OTP 27 (consumer floor), 1.19/OTP 28,
  and 1.20/OTP 29. The repository pins no toolchain file; use one of those pairs.
- Maintainer tools (ex_slop, ex_dna, and the other analysis dependencies) need
  Elixir 1.18 or newer. The deep-analysis lane uses Elixir 1.20/OTP 29.
- OTP 28+ provides isolated `trace:system/3` sessions. OTP 27 uses the explicit,
  conflict-refusing legacy mode; keep both paths tested.

## Change discipline

Keep changes coherent, reversible, and independently reviewable. Batch related
prototype work when it improves iteration.

1. Start from a known local revision or dedicated worktree and understand the acceptance criteria.
2. For a defect, capture a failing test or repeatable causal fingerprint before
   changing the implementation.
3. Add or strengthen focused unit tests for every behavior change. Keep each
   behavior change with its test in the same local change.
4. Implement the smallest causal fix. Do not hide failures with sleeps, retries,
   broader serialization, blanket rescue, or relaxed assertions.
5. Run the highest relevant verification tier available.
6. Before external sharing or the final PR, request a fresh-context adversarial
   review of the final diff. Act on every finding or record a concrete reason
   it does not apply.
7. Keep review scope, findings, disposition, and verification evidence in local
   notes during iteration; copy relevant evidence into the final PR.
8. Commit only when the evidence supports high confidence that the change is
   correct and introduces no known defect. State residual uncertainty plainly.

Tests are executable product claims. Prefer behavior and observable effects over
implementation details. Include positive, negative, boundary, cleanup, timeout,
overload, and healthy-control cases when relevant. Fixed seeds and fixtures must
be persisted when they reproduce a failure.

- Do not add `async: false`, sleeps, retries, test-order dependence, or a test
  exclusion without a causal explanation. These often conceal the exact
  failures Insider exists to expose.
- Control clocks, random generators, ports, node names, databases, and external
  services at test boundaries. Preserve the random seed for every failure.
- Versioned protocols and capsule schemas need round-trip, malformed-input, and
  backward-compatibility fixtures before release.
- Collector hot paths need an explicit overhead budget and a benchmark or load
  comparison. A performance assertion without before/after measurements is not
  evidence.

## Verification fidelity ladder

Run every applicable lower tier and the highest relevant available tier. As
Insider gains capabilities, its own incident capture and reproduction become
required evidence rather than optional demonstrations.

1. **Static:** formatting, warnings-as-errors, strict Credo/ex_slop, and focused
   static checks.
2. **Unit/schema:** deterministic unit, property, serialization, compatibility,
   and policy tests.
3. **Integration:** supervised components, faulty fixtures, healthy controls,
   resource accounting, and failure isolation.
4. **Runtime end to end:** a real isolated BEAM node produces a bounded capsule,
   a clean target reproduces it, and cleanup is observed.
5. **Target application:** the adopter scenario fails before and passes after
   under the same amplifier.
6. **Platform/production-like:** real device, cluster, load, redaction, or
   deployment topology when the changed surface requires it.

Do not silently substitute a lower tier because a higher one is slow or broken.
Fix the harness, file a blocking issue, or document why the tier cannot apply.
Never claim device, distributed, production, or repair-loop confidence from unit
tests alone.

## Local and CI gates

Set up once per clone or worktree:

```sh
mix setup
```

This activates committed hooks in `.githooks/`:

- `pre-commit`: staged whitespace, format, warnings-as-errors, a full unit run,
  strict Credo/ex_slop, and a same-commit source/test heuristic;
- `commit-msg`: Conventional Commit shape;
- `pre-push`: full `mix quality` plus ex_dna duplication analysis.

Useful commands:

```sh
mix quality       # format, compile, full unit suite, Credo + ex_slop
mix quality.deep  # quality + ex_dna + Dialyzer
mix test --cover  # enforces the 90% coverage floor, writes cover/
mix deps.audit
mix hex.audit
bash scripts/verify-production-artifact   # release boot proves Lab cannot load
mix run bench/<name>.exs                   # hot-path benchmark and its budget

(cd tools/insider_lab && mix deps.get --check-locked && mix format --check-formatted \
  && mix compile --warnings-as-errors && mix test)
(cd tools/insider_load && mix deps.get --check-locked && mix insider.load \
  --profile config/load.json --output ../../_build/insider_load/evidence/load)
```

CI workflows:

- `quality.yml` runs on every push and pull request. It runs the core runtime
  matrix (format, warnings-as-errors, `mix test --cover`, the artifact-boundary
  test, and `scripts/verify-production-artifact`), the Lab matrix, and a
  deep-analysis lane (`mix quality.deep`, coverage, `mix deps.audit`,
  `mix hex.audit`).
- `load-soak.yml` runs the `load` profile on pull requests, a `soak` profile
  every Monday, and a selected profile on manual dispatch.

CI runs format, warnings-as-errors, and tests across the supported Elixir/OTP
compatibility pairs. The current toolchain lane runs full quality and deeper
analysis.
The AI-oriented analysis dependencies require Elixir 1.18+, so maintainers and
the deep-analysis lane use the current toolchain; the Elixir 1.17 compatibility
lane compiles and tests the runtime/test dependency graph without those tools.
Do not use `--no-verify` except to recover from broken hook infrastructure with
explicit human approval; record the bypass and run equivalent checks manually.
Never weaken a threshold, exclude code, or delete a test merely to make a gate
green.

Local hooks are early feedback, not the authority: required GitHub checks and an
independent PR review must protect `main`, because hooks can be bypassed. Keep
dependencies locked, review lockfile changes, and let Dependabot propose bounded
dependency and GitHub Actions updates.

The current supporting tools are deliberately complementary:

- **ex_slop:** AI-associated structural and prose/code-quality smells;
- **ex_dna:** semantic duplication, especially parallel-agent drift;
- **jump_credo_checks:** weak, vacuous, assertion-free, and structural test/code
  patterns;
- **Dialyzer:** whole-program type and success-typing inconsistencies;
- **StreamData:** generated boundary cases and reproducible shrinking;
- **mix_audit / `mix hex.audit`:** known vulnerabilities and retired packages.

Coverage is a floor and a discovery signal, never proof of correctness. Do not
write assertions whose only purpose is to raise the percentage.

## Commits and pull requests

Use Conventional Commits:

```text
type(scope): imperative description
```

Allowed types: `feat`, `improv`, `fix`, `chore`, `docs`, `style`, `refactor`,
`test`, `ci`, and `build`. Keep subjects concise, omit a trailing period, and
explain only non-obvious rationale in the body.

- One logical change per commit; tests and docs travel with that change.
- Never commit secrets, generated build products, raw customer data, or
  unredacted incident artifacts.
- Use the PR template and keep it current as the implementation changes. Its
  "AI assistance" section names the AI tools that helped and what they wrote.
  The human who opens the PR is responsible for the whole change.
- Every commit carries a Developer Certificate of Origin sign-off
  (`git commit -s`) from the human author. An agent never signs off for a
  person who has not reviewed the change.
- Resolve every review comment before merge: fix it or explain concretely why it
  does not apply.
- Never merge while tests are flaky, a required fidelity tier is unverified, a
  review finding is unresolved, or the change has a known correctness gap.

## Changelog

Maintain `CHANGELOG.md` under `[Unreleased]` for every user-visible, operational,
compatibility, security, or packaging change. Do not fill it with internal
refactors that have no release consequence.

## Documentation

The README is a short synopsis for people. It holds the pitch, a quick start,
when to use Insider and when not, its relation to Tidewave, status and
safety in a few lines, and a map of the documentation. Keep it under about
120 lines, and keep every claim in it backed by evidence. Reference material
belongs in `docs/`, never in the README.

Keep `docs/` true in the same change. A new or changed capability updates its
section in `docs/` and
[`docs/status-and-roadmap.md`](docs/status-and-roadmap.md#current-status),
and the roadmap when the phase moves. A new section, file, or task updates
the task tables and the files table in `docs/README.md`. A new term goes in
[`docs/glossary.md`](docs/glossary.md). A new everyday command goes in
[`docs/cheat-sheet.md`](docs/cheat-sheet.md).

`test/documentation_links_test.exs` enforces the layout:

- every relative link, anchor, and image resolves;
- a linked heading has the same anchor on GitHub and in ex_doc, so it holds
  no `.`, `/`, or `'`;
- each topic file stays under 600 lines, opens with the line
  `[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)`,
  and has a `## Contents` list that names its `##` and `###` headings in order;
- each index row points at a section of at most 150 lines, with a size close
  to the real one;
- each file under `docs/` is an ex_doc extra in `mix.exs`.

`test/readiness_artifacts_test.exs` fails when any tracked file, binaries
included, names an internal company or product, an evaluation or review
round, a work-item or ticket id, or a personal path. Its allow-list names each
exception with a reason. Give the reason in a comment, not the round that
found it. Use neutral examples (`MyApp`, `my_app`, `shop.*`,
`example-marketplace`).
Write observer command lines in the portable form, `N=(--node … --cookie-file
…)` and `"${N[@]}"`, and quote glob-like values. The Lab
`live_shell_examples_test.exs` runs every documented command line through bash
and zsh and parses it.

A new path or project updates
[Repository layout](docs/development.md#repository-layout) and this file's
repository map. Guides in `guides/` are short entry points that point into
`docs/` and do not copy it. Lab and Load behavior changes update
`tools/insider_lab/README.md` or `tools/insider_load/README.md`.

## Decision log

Record durable decisions in `decisions/`, one Markdown file per decision, named
`YYYY-MM-DD_snake_case_title.md`. Use a sentence-case `#` title, then
`## Decision`, `## Why`, and `## Consequences`. Use `## Evidence` in place of
`## Why` when measurements or artifacts carry the argument, or `## Context`
before `## Decision` when the surrounding constraint must be stated first.
`decisions/README.md` holds the full convention and a template.

Write one when a change sets or moves a trust, packaging, authority, policy, or
protocol boundary; denies, defers, or gates a capability; commits to a schema,
wire format, or public contract; or accepts a constraint a later change would
have to revisit. Routine implementation, refactors, fixes, and performance work
belong in `CHANGELOG.md` instead.

Decisions are append-only. Supersede one with a new dated file that names the
record it replaces; never rewrite or delete a superseded decision. A decision
records what was decided and why, and never grants authority that a separate
human gate is required to give.

## Runtime safety invariants

- Production observes; disposable external environments mutate.
- No arbitrary evaluation, fault injection, code loading, source credentials,
  or coding model belongs in the production collector.
- Every operation is bounded by time, events, bytes, targets, and cleanup.
- Report truncation, dropped evidence, observer effects, and uncertainty.
- Redaction and authority are part of the event and artifact model.
- Collector failure must not crash or block the host application.
- Use isolated OTP trace sessions; never take over global diagnostics silently.
- An unconfirmed finding does not authorize a repair.

## Collaboration

Each concurrent agent must use its own Git worktree. Give each agent a distinct
branch and unique node names, build paths, databases, ports, simulators, and
temporary resources. Do not edit the same files concurrently without explicit
ownership. A reviewer must use fresh context and independently inspect the diff
and relevant source; self-review by the implementing context does not satisfy
the adversarial gate.

Record handoff context in local task notes before yielding ownership; include
relevant context in the final PR when it is opened.
