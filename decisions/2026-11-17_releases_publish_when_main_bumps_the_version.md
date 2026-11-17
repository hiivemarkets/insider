# Releases publish when main bumps the version, and Hex approval is the gate

## Context

`2026-11-16_insider_and_the_lab_publish_to_hex_under_an_organization.md`
published later releases from a pushed `v*` tag, through a workflow in the
GitHub environment `release`, whose required reviewers approved each run.
Hex staged publishing then held each release for a second approval. Two
people-gates guarded one decision, and the tag, pushed by hand, was a second
place to name the version that already sits in both `mix.exs` files.

This record supersedes that record's "Later releases publish from a `v*`
tag" point and its consequence that "the workflow checks that the tag names
that version". The rest of that record stands: the organization, the
workload identity, the manual first release and the Lab's dependency switch.

## Decision

- A push to `main` that changes `mix.exs` or `tools/insider_lab/mix.exs`
  starts `.github/workflows/release.yml`. `workflow_dispatch` on `main`
  starts it again, to finish a release that failed or waited too long. No
  tag starts it.
- The `check` job reads `@version` from both files and fails when they
  differ. For each package it asks the Hex releases API whether that version
  exists, and publishes only a version that Hex lacks. It refuses a version
  that is not greater, by SemVer precedence, than every release of that
  package on Hex. When both packages have the version and the tag
  `vVERSION` exists, nothing else runs.
- The `publish` job, in the environment `release`, publishes `insider`,
  waits up to 60 minutes until Hex serves it, publishes `insider_lab`, and
  waits for it the same way. Then it creates the annotated tag `vVERSION` on
  the commit that Hex recorded for the core release, else the run's commit,
  and pushes it with `GITHUB_TOKEN`. Each step looks at Hex or at the tags
  first, so a rerun only does what is missing.
- Hex staged publishing is the human gate: a maintainer with 2FA approves
  each release on hex.pm. The environment `release` admits only `main` and
  needs no reviewers. Reviewers added later would gate the job before it
  asks Hex for a key, and the workflow works the same.
- The workflow holds no Hex key. `GITHUB_TOKEN` can write contents only in
  the `publish` job, and only the tag step receives it.

## Why

- **The version in `mix.exs` is the release.** It is reviewed in the pull
  request that bumps it, together with the changelog. A separate tag could
  name another version, or be pushed from another commit.
- **One approval, at the registry.** Staged publishing shows the package and
  documentation checksums that will ship, and only a maintainer with 2FA can
  approve. A GitHub reviewer approved a run before anything was built, so
  that approval added a wait without showing more.
- **The tag follows the release.** The workflow tags only what Hex serves,
  so a tag never names a release that was rejected or never approved.
  Hexdocs source links point at the tag.
- **Idempotent steps.** Approval can take longer than a run waits. Asking
  Hex before each step makes a rerun safe, and lets a run that only finds
  the tag missing create it.
- Rejected alternatives:
  - Keeping the tag trigger and adding a bot that tags on merge. A tag
    pushed with `GITHUB_TOKEN` starts no workflow, so it needs a stored
    token, and the version still lives in two places.
  - Comparing versions with `sort -V`. It orders a pre-release after its
    release. Elixir's `Version` follows SemVer.

## Consequences

- Merging a version bump publishes. Agents do not bump `@version` unless a
  maintainer asks for a release.
- A release that waits for approval is not visible through the Hex API, so
  a rerun stages it again, and the maintainer approves the newest one.
- Hex refuses a revert from a workload identity while staged publishing
  applies. A maintainer reverts from their own account, within one hour.
  After a revert, `main` still names the version, so the next change to a
  `mix.exs` publishes it again unless the fix also bumps the version.
- The workload identity on hex.pm and the environment `release` on GitHub
  are configured outside this repository. This record does not create them.
