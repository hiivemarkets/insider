# Contributing to Insider

Insider is a pre-release proof of concept: its protocol, APIs, and package
layout are not stable. Contributions are welcome, and they are held to the
rules below because Insider exists to expose the failures that loose tests and
weakened gates hide.

[`AGENTS.md`](AGENTS.md) is the canonical rulebook for everyone who changes
this repository, people and coding agents alike (`CLAUDE.md` points to it).
This guide summarises it for a first contribution; where they differ,
`AGENTS.md` wins. By taking part you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities privately as
described in [`SECURITY.md`](SECURITY.md), never in a public issue.

## Before you start

- Read the [README](README.md) and the code and tests you intend to change
  before changing a public contract, runtime boundary, or safety policy.
- For a change to a public contract, schema, trust or packaging boundary, or
  safety policy, open an issue first so the boundary can be agreed before the
  code is written.

## Issues

File bugs, documentation mismatches, and proposals as
[GitHub issues](https://github.com/hiivemarkets/insider/issues). Give the
Insider version, the Elixir and OTP versions, the command you ran, and what
you expected. Leave out payloads, secrets, and personal data. Report a
vulnerability privately instead, as [`SECURITY.md`](SECURITY.md) describes.

An agent that uses Insider records its reports locally with
`insider-lab live report` (or `Insider.Live.JSON.report/1`). The developer
reviews them and files them as issues in this repository with
`insider-lab live reports submit`, which uses the GitHub CLI (`gh`) and opens
one issue per report fingerprint.

## Repository map

Insider is three separate Mix projects in one repository. Decide which one a
change belongs to before editing.

| Project | Path | Purpose | May depend on |
|---|---|---|---|
| Core (`:insider`) | `lib/`, `test/` | The production-safe, bounded, read-mostly collector and evidence core. Published to Hex as `insider`. | Its own dependencies only |
| Lab | `tools/insider_lab/` | Development and disposable-environment tooling: `mix insider`, `mix insider.candidates`, `mix insider.live`, `mix insider.oracle`, fixed oracles, Sentinel, the `insider-lab` escript. Published to Hex as `insider_lab`. | Core: by path here, from Hex in its package |
| Load | `tools/insider_load/` | Synthetic load and soak evidence (`mix insider.load`). Never published. | Core, by path |

- The core never depends on Lab or Load and contains no escript, Mix task,
  fixture, scenario runner, Sentinel, command runner, or provider-mutation
  code. This is a physical packaging boundary, not a feature flag.
- A change that adds a core dependency, moves code between projects, or touches
  release contents must pass `bash scripts/verify-production-artifact`, which
  builds a production release and proves Lab-only modules cannot load.
- Lab and Load share the root `mix.lock` and `deps/`. Review every lockfile
  change. Only the Lab's Hex form (`INSIDER_LAB_HEX=1`, for packaging) uses
  its own `deps/` and lockfile, which Git ignores.

Other paths: `bench/` (hot-path benchmarks), `docs/` (readiness artifacts that
grant no authority), `decisions/` (decision log), `fixtures/`, `guides/` and
`usage-rules.md` (shipped with the package), `scripts/`, `.githooks/`, and
`.github/workflows/`.

## Setup

Use a supported Elixir/OTP pair. CI tests all three; the repository pins no
toolchain file.

| Elixir | OTP | Role |
|---|---|---|
| 1.17 | 27 | Consumer floor. Compiled and tested without the maintainer tools. OTP 27 uses the conflict-refusing legacy trace mode. |
| 1.19 | 28 | Supported. OTP 28 adds isolated `trace:system/3` sessions. |
| 1.20 | 29 | Current toolchain and the deep-analysis lane. |

The maintainer analysis tools (Credo plugins, ex_slop, ex_dna) need Elixir
1.18 or newer, so day-to-day development uses 1.19/28 or 1.20/29.

Set up once per clone or worktree:

```sh
mix setup   # mix deps.get, then git config core.hooksPath .githooks
```

Lab and Load are built from their own directories:

```sh
(cd tools/insider_lab && mix deps.get --check-locked && mix format --check-formatted \
  && mix compile --warnings-as-errors && mix test)
(cd tools/insider_load && mix deps.get --check-locked && mix test)
```

## Tests first

Tests are executable product claims.

1. For a defect, capture a failing test or a repeatable causal fingerprint
   before changing the implementation.
2. Add or strengthen focused unit tests for every behaviour change, in the
   same commit as the change. The pre-commit hook rejects a commit that
   changes `lib/` without `test/`, `tools/insider_lab/lib/` without
   `tools/insider_lab/test/`, `tools/insider_load/lib/` without
   `tools/insider_load/test/`, or `fixtures/apps/` without
   `fixtures/scenarios/`.
3. Implement the smallest causal fix. Do not hide a failure with sleeps,
   retries, broader serialisation, blanket `rescue`, or relaxed assertions.

Test behaviour and observable effects, not implementation details. Cover
positive, negative, boundary, cleanup, timeout, overload, and healthy-control
cases where they apply.

- Do not add `async: false`, sleeps, retries, test-order dependence, or a test
  exclusion without a causal explanation.
- Control clocks, random generators, ports, node names, databases, and external
  services at test boundaries. Preserve the random seed for every failure, and
  persist fixed seeds and fixtures that reproduce one.
- Versioned protocols and capsule schemas need round-trip, malformed-input,
  and backward-compatibility fixtures before release.
- A collector hot-path change needs an explicit overhead budget and a
  before/after benchmark (`mix run bench/<name>.exs`) or load comparison.
- Fixtures and test data are synthetic. Never commit secrets, real customer
  data, or unredacted incident artifacts.

## Quality gates

`mix setup` activates the committed hooks:

| Hook | Runs |
|---|---|
| `pre-commit` | Staged whitespace, `mix format --check-formatted`, `mix compile --warnings-as-errors`, the full `mix test`, `mix credo --strict` (with ex_slop and jump_credo_checks), and the test-pairing check. It refuses a commit while unstaged or untracked files exist, so what it tests is what you commit. |
| `commit-msg` | The Conventional Commit shape below. |
| `pre-push` | `mix quality`, then `mix ex_dna`. |

The aliases:

```sh
mix quality       # format, warnings-as-errors (dev, test, prod), full tests,
                  # the production-artifact check against the prod build,
                  # strict Credo + ex_slop
mix quality.deep  # mix quality, then ex_dna and Dialyzer
mix test --cover  # the coverage floor; writes cover/
mix deps.audit
mix hex.audit
bash scripts/verify-production-artifact
```

CI (`.github/workflows/quality.yml`) runs on every push and pull request: the
core matrix (format, warnings-as-errors, `mix test --cover`,
`scripts/verify-production-artifact`) and the Lab matrix on all three
toolchain pairs, and a deep-analysis lane on 1.20/29 (`mix quality.deep`,
coverage, `mix deps.audit`, `mix hex.audit`).
`.github/workflows/load-soak.yml` runs the Load `load` profile on pull
requests and a `soak` profile weekly.

Hooks are early feedback; CI and review are the authority. Do not use
`--no-verify` except to recover from broken hook infrastructure with a
maintainer's explicit approval, and then run the equivalent checks by hand and
say so in the pull request. Never weaken a threshold, exclude code, or delete
a test to make a gate pass.

Run the highest verification tier that applies to your change, from static
checks and unit tests up to a real isolated BEAM node, the target
application, or a production-like topology. `AGENTS.md` describes the six
tiers. Do not claim a higher tier than you ran.

## Coverage

`mix test --cover` enforces a 90% floor on every supported OTP release. Below
OTP 28, the modules that cannot run there (`Insider.Collector.Calls`,
`Insider.Collector.Calls.Tracing`, and `Insider.Collector.Otel.Tracing`,
which need isolated trace sessions) are left out of the total; they count on
OTP 28 and 29. The list is `otp_28_only_modules/0` in `mix.exs`, and a
guardrail test derives it from the code and fails when they differ. A module
with a supported OTP 27 mode stays counted everywhere.

Coverage is a floor and a discovery signal, not proof of correctness. Do not
write assertions whose only purpose is to raise the percentage.

## Documentation, changelog, and decisions

- **README:** keep `README.md` true in the same change. A new or changed
  capability updates its README section and `## Current status`. Lab and Load
  behaviour changes update `tools/insider_lab/README.md` or
  `tools/insider_load/README.md`. When a guide under `guides/` and the code
  disagree, the code wins and the guide is corrected in the same change.
- **Changelog:** add an entry to `CHANGELOG.md` under `[Unreleased]`
  ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)) for every
  user-visible, operational, compatibility, security, or packaging change.
  Internal refactors with no release consequence do not need one.
- **Decision records:** write one in `decisions/` when a change sets or moves a
  trust, packaging, authority, policy, or protocol boundary; denies, defers, or
  gates a capability; commits to a schema, wire format, or public contract; or
  accepts a constraint a later change would have to revisit. Name it
  `YYYY-MM-DD_snake_case_title.md` and follow the template in
  [`decisions/README.md`](decisions/README.md). Decisions are append-only:
  supersede one with a new dated file, never edit or delete it. Routine fixes
  and refactors belong in the changelog instead.

## Commits

Use Conventional Commits; the `commit-msg` hook enforces the shape:

```text
type(scope): imperative description
```

- Types: `feat`, `improv`, `fix`, `chore`, `docs`, `style`, `refactor`,
  `test`, `ci`, `build`.
- The scope is optional, lower case, and may contain `.`, `_`, `/`, and `-`.
  Mark a breaking change with `!` (`feat(lab)!: …`).
- At most 72 characters after `type(scope): `, with no trailing period.
- The body explains only non-obvious rationale.
- One logical change per commit; its tests and docs travel with it.
- Sign off every commit with `git commit -s`. See
  [Licensing of contributions](#licensing-of-contributions).

## Pull requests

- Open pull requests against `main` and fill in the
  [pull request template](.github/pull_request_template.md): what and why,
  evidence (exact commands and results, failing-before evidence for a bug
  fix, skipped or unavailable gates), adversarial review, AI assistance, and
  change control.
- Before review, have someone with fresh context, not the author, review the
  final diff adversarially. Act on every finding or record a concrete reason it
  does not apply.
- Resolve every review comment before merge: fix it or explain concretely why
  it does not apply.
- A pull request does not merge while tests are flaky, a required verification
  tier is unverified, a review finding is unresolved, or the change has a known
  correctness gap.
- Changes to `AGENTS.md`, `.githooks/`, or `.github/workflows/` need review from
  the owner named in [`.github/CODEOWNERS`](.github/CODEOWNERS).
- Dependabot proposes dependency and GitHub Actions updates; review lockfile
  changes like code.

Insider has one maintainer for now: the owner named in
[`.github/CODEOWNERS`](.github/CODEOWNERS), who reviews and merges pull
requests. A second maintainer is recommended.

## Coding agents

AI coding agents are welcome and follow exactly the same rules as people:
`AGENTS.md` is written for both.

- Each concurrent agent works in its own Git worktree, on its own branch, with
  unique node names, build paths, ports, and temporary resources.
- An agent's work passes the same hooks, tests-first rules, coverage floor, and
  CI gates. An agent does not bypass a hook or weaken a gate without explicit
  maintainer approval.
- Self-review by the context that wrote the change does not satisfy the
  adversarial review; the reviewer uses fresh context and inspects the diff
  and source independently. Name the reviewing person or agent in the pull
  request.
- Agents do not push to `main`, publish, or deploy.

AI-assisted contributions are welcome. A pull request must disclose AI
assistance: name the tool and say which parts it wrote or changed. The person
who opens the pull request is its author. They sign off the commits (see
below) and are responsible for the whole change, as if they had written it
themselves.

## Licensing of contributions

Insider is offered under the [MIT License](LICENSE). A contribution is
submitted under the same license.

Every commit carries a Developer Certificate of Origin (DCO) sign-off. By
signing off, you certify that you wrote the change, or otherwise have the
right to submit it under the project's license, as the
[Developer Certificate of Origin](https://developercertificate.org) states.
There is no Contributor License Agreement.

Sign off with `git commit -s`. Git adds a trailer with the name and email of
your Git identity:

```text
Signed-off-by: Your Name <you@example.com>
```

Use your real name. To sign off commits you already made, run
`git commit --amend -s` for the last one, or `git rebase --signoff main` for
every commit on your branch, then push again.
