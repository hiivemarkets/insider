# Insider and the Lab publish to Hex under an organization

## Context

Insider was not published. The core had package `files` but no license,
description or links, and the Lab was a non-published project that depended
on the core by path. Users needed a checkout of this repository to run the
observer. `decisions/2026-09-11_production_artifact_boundary_is_a_separate_mix_project.md`
deferred Hex publication and called the Lab non-published. This record
replaces those two points. Its artifact boundary stands.

## Decision

- Publish two Hex packages from one tag, at one version: `insider` (the core,
  from the repository root) and `insider_lab` (the observer CLI, the Mix
  tasks and the escript, from `tools/insider_lab`). The first version is
  `0.1.0`. Both are MIT-licensed.
- The Hex organization `clarity` owns both packages. Every member uses 2FA.
  For now it has one member, the maintainer, who is its admin. A second
  admin, who is also a package owner, is recommended. The maintainer
  publishes each package's first release from their own account and then
  transfers it to the organization.
- Later releases publish from a `v*` tag through `.github/workflows/release.yml`.
  The workflow authenticates with a Hex workload identity (trusted
  publishing) and holds no stored key. It runs in the GitHub environment
  `release`, whose required reviewers approve each run. Hex staged
  publishing holds each release until a maintainer with 2FA approves it.
- In this repository the Lab depends on the core by path and shares the
  root `deps/`, `_build/` and `mix.lock`. Its package depends on
  `{:insider, "~> VERSION"}` from Hex. `INSIDER_LAB_HEX=1` selects the Hex
  form in this repository, to build or publish the package. Anywhere else,
  for example the unpacked package that `mix escript.install hex insider_lab`
  builds, the Hex form is the only one. The Hex form uses its own `deps/`
  and lockfile in `tools/insider_lab`.
- The Lab's escript `name` equals its default path, `insider-lab`, so
  `mix escript.install` finds the escript it built.
- The Lab package carries copies of `LICENSE` and recon's BSD-3-Clause text,
  because a package holds only files below its own directory. A test keeps
  the copies equal to the root files.

## Why

- **An organization, not a personal account.** Ownership can move to other
  members without a transfer from a person, and every member needs 2FA.
  Hex organizations are free for public packages. With one member, the
  organization does not yet remove the dependence on one account. A second
  admin does.
- **Workload identity, not an API key.** A stored key can leak and does not
  expire. A workload identity issues a short-lived key per publish, only to
  this repository, this workflow file and the `release` environment. Hex
  does not let a workload identity create a package or publish its first
  release, so the first release is manual.
- **Both packages.** The observer is the way most users meet Insider, and
  `--load` pushes the observer's own Insider into the target. With only the
  core on Hex, users still needed a checkout for the CLI. With the Lab on
  Hex, `mix escript.install hex insider_lab` installs it, and a target app
  needs no dependency at all.
- **The dependency switch.** A Hex package cannot depend on a path, and the
  monorepo must keep building the Lab against the core next to it, so that
  a change to both lands in one commit and CI tests them together. Mix has
  no built-in way to swap a path dependency for a Hex one at publish time.
  Rejected alternatives:
  - An `override` in a separate publishing project. It needs a copy of the
    Lab's sources, which drifts from them.
  - A sed rewrite of `mix.exs` in CI. It publishes a file nobody reviewed.
  - The environment variable alone. The unpacked package that
    `mix escript.install` builds would then have a path dependency.

  Detecting the repository (the project lives in `tools/insider_lab`, two
  levels below a directory that holds `lib/insider.ex`) makes the published
  `mix.exs` correct without the variable. The variable lets this repository
  build the package.

## Consequences

- The production artifact boundary is unchanged. The core's package holds
  no Lab code, and `scripts/verify-production-artifact` still proves it.
- The core and the Lab release together. A test checks that both
  `@version`s agree, and the workflow checks that the tag names that version.
- Publishing the Lab's package grants it no authority. Its staging and
  production denials hold, as before.
- The Load project stays unpublished.
- After a release is approved, Hex allows changes for one hour. Then a fix
  needs a new version.
- Staged-publishing approval and the `release` environment are configured on
  hex.pm and GitHub, outside this repository. This record does not create
  them.
