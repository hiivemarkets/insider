# Development

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The repository layout, local and CI gates, synthetic load and soak evidence,
documentation tooling, and how to release Insider to Hex.

## Contents

- [Repository layout](#repository-layout)
- [Checks and gates](#checks-and-gates)
- [Synthetic load and soak evidence](#synthetic-load-and-soak-evidence)
- [Documentation](#documentation)
- [Project documents](#project-documents)
- [Releasing](#releasing)
  - [The first release, by hand](#the-first-release-by-hand)
  - [Later releases, from a tag](#later-releases-from-a-tag)

## Repository layout

| Path | What it holds |
|---|---|
| `lib/`, `test/` | The root `:insider` application: the production-safe collector and evidence core. |
| `tools/insider_lab/` | Separate Mix project for development and disposable environments, published to Hex as `insider_lab`. Its contents are listed below the table. |
| `tools/insider_load/` | Separate, non-published Mix project for synthetic load and soak evidence (`mix insider.load`). |
| `bench/` | Hot-path benchmarks, run with `mix run bench/<name>.exs`. |
| `scripts/verify-production-artifact` | Builds and boots a production release and proves Lab-only modules cannot load. |
| `scripts/verify-load-evidence` | Recomputes digests and identities of emitted load evidence directories offline and prints one JSON verdict line per directory. |
| `docs/` | The reference documentation, indexed by [`docs/README.md`](README.md), and the production-readiness artifacts listed below the table. |
| `docs/assets/` | The logo and the README images. |
| `guides/` | Curated ex_doc guides for people (`guides/people/`) and for agents (`guides/agents/`). `mix docs` renders them. See [Documentation](#documentation). |
| `usage-rules.md` | Short rules for agents with pointers into the guides, read by `mix usage_rules.sync` from `deps/insider/`. |
| `decisions/` | Append-only decision records. See [`decisions/README.md`](https://github.com/hiivemarkets/insider/blob/main/decisions/README.md). |
| `fixtures/` | Reserved for faulty applications and paired healthy/failing scenarios. |
| `LICENSES/`, `THIRD_PARTY_NOTICES.md` | License text for adapted third-party code and for recon, which the Lab observer can push into a target. The project license is `LICENSE` (MIT). The Lab keeps copies of `LICENSE` and the recon text for its own package. |
| `.githooks/`, `.github/workflows/` | Local gates (activated by `mix setup`) and CI (`quality`, `load-soak`, and `release`, which publishes to Hex from a tag). |

- `tools/insider_lab/` holds `mix insider`, `mix insider.candidates`,
  `mix insider.oracle`, `mix insider.privacy_corpus`, `mix insider.live`, the
  fixed oracles, Sentinel, scenarios, and the CLI. In this repository it
  depends on the core by path. Its Hex package depends on the core from Hex.
  The core never depends on it.
- `docs/` also holds the production-readiness threat model, dossier, evidence
  index, protected-target audit matrix, and staged-canary planning artifacts.
  The readiness artifacts grant no authority.

## Checks and gates

Install dependencies, activate the committed Git hooks, and run the full local
quality gate:

```sh
mix setup
mix quality
```

Maintainer tools currently require Elixir 1.18 or newer. The canonical deep
analysis lane uses Elixir 1.20/OTP 29. CI compiles and tests Insider's Elixir
1.17/OTP 27 consumer floor separately, without maintainer-only tools.

Individual checks are also available:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix test --cover
mix credo --strict
mix quality.deep
```

The coverage command enforces the 90% floor and writes per-module HTML reports
to `cover/`. Its test-only reporter writes those reports one at a time, so the
same command stays reliable under the default macOS open-file limit. The
reporter does not raise the shell limit or reduce collected product coverage
evidence. Reporting begins after the coverage snapshot, so unit tests cover the
reporter directly.

Below OTP 28 the total leaves out the modules that cannot run there.
`Insider.Collector.Calls`, `Insider.Collector.Calls.Tracing`, and
`Insider.Collector.Otel.Tracing` need isolated trace sessions (OTP 28). On
OTP 27 only their `requires_otp_28` refusal runs. Their coverage counts on the
OTP 28 and OTP 29 runs, and the 90% floor applies to every run. A module with
a supported OTP 27 mode counts on every release. Examples are the otel
collector (ingest only) and the system monitor (legacy backend). The list is
`otp_28_only_modules/0` in `mix.exs`. A guardrail test derives the list from
the code and fails when they differ. See
`decisions/2026-10-23_otp_28_only_modules_count_toward_coverage_on_otp_28_only.md`.

The pre-commit hook runs fast deterministic checks. It requires tests alongside
behavior-bearing source changes. Pre-push runs the full unit suite and the
semantic duplication scan. CI adds the supported runtime matrix, Dialyzer,
coverage, and dependency audits. `AGENTS.md` defines the required adversarial
review and verification-fidelity evidence.

## Synthetic load and soak evidence

The separate, non-published
[`tools/insider_load`](https://github.com/hiivemarkets/insider/blob/main/tools/insider_load/README.md)
project compares a fixed-seed synthetic host workload without and with a
production-readiness Collector Session. Its bounded canonical reports and
manifests bind measurements to the exact revision, tree state, runtime, and
profile. The evidence applies only to the host that recorded it. Pull requests
run the load profile across the supported Elixir/OTP matrix. Scheduled runs and
manually selected soak runs retain longer evidence.

Each phase summary localizes missed scheduled operations by segment and by
cause (`skipped_tick` or `segment_end_remainder`). It records the largest
observed tick- or segment-deadline overshoot. The sums must reconcile with the
total, or the report is invalid. `scripts/verify-load-evidence <dir>`
re-derives the digests and identities of an emitted evidence directory offline.

These measurements are development/CI evidence, not approved performance
budgets or production-capacity claims. Reports keep `production_capacity=false`
and `budget_evaluation=not_approved`. Staging and production observation remain
policy-denied until separate, revision-bound human decisions allow them.

## Documentation

The documentation has three layers:

- [`README.md`](https://github.com/hiivemarkets/insider/blob/main/README.md) is a
  short synopsis for a person who decides whether to use Insider. It holds no
  reference material.
- `docs/` is the reference. [`docs/README.md`](README.md) is its index: a
  contents list and a table that tells an agent which file and section to
  read for which task. Each topic file starts with its own contents list.
- `guides/` holds short curated entry points, for people
  (`guides/people/`) and for agents (`guides/agents/`). The guides point
  into `docs/` and do not copy it:
  - `guides/people/`: [overview](../guides/people/overview.md),
    [how a session works](../guides/people/how-a-session-works.md),
    [the safety model](../guides/people/safety-model.md),
    [what exists today](../guides/people/what-exists-today.md), and
    [try it locally](../guides/people/try-it-locally.md).
  - `guides/agents/`: operating contracts for
    [`mix insider.candidates`](../guides/agents/candidates-cli.md),
    [the ExUnit oracles, the actor differential, and fault and rerun](../guides/agents/oracles.md),
    [`mix insider` and the protocol envelope](../guides/agents/protocol-and-mix-task.md),
    [the Sentinel chain](../guides/agents/sentinel-chain.md),
    [`mix insider.privacy_corpus`](../guides/agents/privacy-corpus.md),
    [the load harness](../guides/agents/load-harness.md),
    [what Insider refuses to do](../guides/agents/refusals.md),
    [reading a report](../guides/agents/reading-a-report.md), and
    [live observation](../guides/agents/live-observation.md). The root
    `usage-rules.md` points into them.

`mix docs` renders the README, `docs/`, the guides, the CHANGELOG,
`AGENTS.md`, and the usage rules into `doc/` with ex_doc. ex_doc is a
`dev`-only dependency, so the production dependency graph is unchanged. The
root project does not compile Lab-only modules.
`(cd tools/insider_lab && mix docs)` writes their API reference to
`tools/insider_lab/doc/`. Both output directories are gitignored.

`test/documentation_links_test.exs` checks that every relative link and anchor
in the README, `docs/`, the guides, and `AGENTS.md` resolves. It checks that
each linked heading gets the same anchor on GitHub and in ex_doc. It also
checks that the sizes in the index stay close to the sections they describe.
When a document and the code disagree, the code wins. Correct the document in
the same change.

## Project documents

- [`AGENTS.md`](../AGENTS.md) defines the change discipline, verification-fidelity
  ladder, gates, and safety invariants for contributors and coding agents.
- [`CHANGELOG.md`](../CHANGELOG.md) records release-facing changes.
- [`decisions/`](https://github.com/hiivemarkets/insider/blob/main/decisions/README.md) holds the append-only decision log.
- [`docs/`](README.md) holds the reference documentation, the
  production-observation threat model, the production-readiness dossier and
  evidence index, and the staged-canary runbook and worksheet.
- [`tools/insider_lab/README.md`](https://github.com/hiivemarkets/insider/blob/main/tools/insider_lab/README.md) and
  [`tools/insider_load/README.md`](https://github.com/hiivemarkets/insider/blob/main/tools/insider_load/README.md) document the two
  tool projects. The Lab is published to Hex. The Load project is not.
- [`THIRD_PARTY_NOTICES.md`](https://github.com/hiivemarkets/insider/blob/main/THIRD_PARTY_NOTICES.md) records adapted code and
  links its complete third-party license text.
- `fixtures/apps/` and `fixtures/scenarios/` are empty today. They are
  reserved for faulty applications and their healthy/failing scenarios.

## Releasing

Insider publishes two Hex packages from one tag, at one version:
`insider` (the core, from the repository root) and `insider_lab` (the
observer CLI, the Mix tasks and the escript, from `tools/insider_lab`). The
Hex organization `clarity` owns both. It has one admin and owner for now.
Add a second admin, who is also a package owner, so that releases and
ownership do not depend on one account.
`decisions/2026-11-16_insider_and_the_lab_publish_to_hex_under_an_organization.md`
records why.

In this repository the Lab depends on the core by path. A Hex package cannot
carry a path dependency, so `INSIDER_LAB_HEX=1` builds the Lab's Hex form:
it depends on `insider` from Hex at the same version, with its own `deps/`
and lockfile in `tools/insider_lab`. The unpacked package always uses the
Hex form.

Before a release:

1. Set the version in both `mix.exs` files (`@version`). A test checks that
   they agree.
2. Move the `[Unreleased]` entries of `CHANGELOG.md` under
   `## [VERSION] - YYYY-MM-DD`, with the day you publish.
3. Check both packages and their documentation:

   ```sh
   mix hex.build
   mix docs
   (cd tools/insider_lab && INSIDER_LAB_HEX=1 mix hex.build)
   (cd tools/insider_lab && mix docs)
   ```

   Read the file lists and the dependencies. The core depends on `jason`
   and `telemetry` only. The Lab depends on `insider` and `recon` only,
   and never on a path.

### The first release, by hand

A Hex workload identity cannot create a package or publish its first
release, so a maintainer publishes `0.1.0` from their own machine:

1. Make the repository public. Hexdocs source links and the package links
   point at it.
2. Create the Hex user accounts, with 2FA on each, and the Hex organization `clarity`.
   Run `mix hex.user auth` on the publishing machine.
3. Tag the release commit `v0.1.0` and push the tag. Hexdocs source links
   point at the tag. The tag also starts the release workflow, which cannot
   publish a first release. If the `release` environment exists, its
   reviewers reject that run.
4. Publish the core, then the Lab, and give the Hex organization `clarity`
   both packages:

   ```sh
   mix hex.publish
   (cd tools/insider_lab && cp ../../mix.lock mix.lock && INSIDER_LAB_HEX=1 mix deps.get)
   (cd tools/insider_lab && INSIDER_LAB_HEX=1 mix hex.publish)
   mix hex.owner transfer insider clarity
   mix hex.owner transfer insider_lab clarity
   ```

   The Lab resolves `insider` from Hex, so publish it after the core is
   available. `mix hex.publish` asks for confirmation and publishes the
   package and its documentation.
5. Install from Hex in a fresh project: add `{:insider, "~> 0.1"}`, then run
   `mix deps.get` and `mix compile`. Install the CLI with
   `mix escript.install hex insider_lab` and run `insider-lab live --help`.

For one hour after publishing, `mix hex.publish` can publish the same
version again. Within that hour, `mix hex.publish --revert VERSION` removes
it. After that, publish a new version.

### Later releases, from a tag

`.github/workflows/release.yml` publishes later releases. It holds no Hex
key. It authenticates through a Hex workload identity (trusted publishing),
and each `mix hex.publish` exchanges a fresh GitHub OIDC token for a
short-lived Hex key. Set it up once:

- An admin of the Hex organization `clarity`, with 2FA, adds a `write` workload identity.
  It names this repository, `release.yml` and the GitHub environment
  `release`.
- Create the `release` environment in the repository settings, with
  required reviewers.

Then, for each release:

1. Do the steps under "Before a release" and merge them.
2. Tag the merge commit `vVERSION` and push the tag.
3. A reviewer approves the `release` environment. The workflow checks that
   the tag matches both versions and publishes `insider`.
4. Staged publishing holds the release until a maintainer with 2FA approves
   it in the Hex dashboard. The workflow waits up to 60 minutes for the
   core release, then publishes `insider_lab`, which waits for approval the
   same way.

If the wait times out, approve the core release and publish the Lab by hand
(step 4 of the first release). Revert a bad release within one hour with
`mix hex.publish --revert VERSION`.
