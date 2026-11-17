# Security policy

## Supported versions

Insider is pre-1.0. Only the latest release receives security fixes. Earlier
releases do not, and fixes are not backported. Until the first release, fixes
land on `main` only.

| Version | Security fixes |
|---|---|
| Latest release | Yes |
| Any earlier release | No |

## Reporting a vulnerability

Do not report a vulnerability in a public issue, pull request, or discussion.

1. Report it privately through GitHub: open the repository's **Security** tab
   and choose **Report a vulnerability**
   (<https://github.com/hiivemarkets/insider/security/advisories/new>).
2. If you cannot use GitHub private vulnerability reporting, email
   [opensource@clarity.com](mailto:opensource@clarity.com).

## What to include

- The affected component: the core `:insider` library, Lab
  (`tools/insider_lab`), or Load (`tools/insider_load`).
- The Insider revision or version, and the Elixir and OTP versions.
- The host configuration that matters: the resolved environment
  (`config :insider, environment: …` or the Mix environment), the live
  disclosure profile (`config :insider, :live_disclosure, …`), and the
  components a session started with.
- Steps to reproduce, ideally a failing test or a minimal script, and the
  output you saw.
- The impact: what an attacker or an unintended reader gains, and which
  promise under [Scope](#scope) it breaks.
- Whether the issue is already public, and how you would like to be credited.

Use synthetic data. Do not send real credentials, customer data, or
unredacted incident artifacts; if a report needs a secret to reproduce, describe
its shape instead.

## How we respond

Insider is maintained by a small team. We respond on a best-effort basis and
do not promise fixed response times. We aim to acknowledge a report promptly,
assess it, and fix a confirmed issue as soon as we can, with the most severe
issues first. We keep the reporter informed at each step.

## Disclosure policy

Insider follows coordinated disclosure:

- We confirm the issue, prepare a fix, and agree a disclosure date with the
  reporter. The default embargo is 90 days from the report, and may be
  extended by agreement while a fix is in progress.
- We publish a GitHub security advisory with the fix, request a CVE when the
  issue warrants one, and record the fix in `CHANGELOG.md`.
- We credit the reporter in the advisory unless they ask not to be named.
- If an issue is already being exploited or disclosed publicly, we may publish
  sooner.

## Scope

Insider's [README](README.md), the [safety model](guides/people/safety-model.md),
and the [production-observation threat model](docs/production-observation-threat-model.md)
define what Insider promises. A report that breaks one of these promises is in
scope.

### What Insider promises

- **Production observes; it never mutates.** The core `:insider` application is
  the only part meant to run next to an application. It has no Mix task,
  escript, fixture, scenario runner, Sentinel, command runner, provider code,
  arbitrary evaluation, fault injection, or code loading.
  `scripts/verify-production-artifact` boots a production release and proves
  Lab-only modules cannot load. A way to reach Lab behaviour from a production
  release is in scope.
- **Deny by default.** Collector sessions, runtime diagnostics, and live
  observation accept only the `development`, `test`, and `ci` environments.
  The environment comes from host configuration, never from a caller, and is
  checked on every observation. A caller that runs observation in `staging`,
  `production`, or an unconfigured release is in scope.
- **Bounded and failure-isolated.** Every operation is bounded by time, events,
  bytes, and targets, and a collector failure must not crash or block the host
  application. Exceeding a documented hard bound, or crashing or blocking the
  host, is in scope.
- **Credential masking in every profile.** `insider-credential-masking/v1`
  applies to every exported live event in every disclosure profile, at every
  nesting level: values under credential-named keys and secret-shaped spans
  (bearer and basic credentials, JWTs, PEM blocks, provider keys, URL
  userinfo, credential assignments, high-entropy tokens) are replaced by
  `[REDACTED:<reason>]`. A credential of a documented kind that reaches
  exported output unmasked is in scope.
- **Disclosure profiles chosen by the host.** The host sets the live
  disclosure profile (`rich` or `strict`); a caller may only narrow it. `ci`,
  and every environment where live observation is denied, is `strict`. A
  caller that obtains `rich` output from a `strict` host is in scope. In the
  `rich` profile, Ecto `redact: true` fields stay hidden, and rendering never
  runs application code (`Inspect` implementations, `report_cb`, calendar
  callbacks).
- **Redaction fails closed.** Portable evidence (incident capsules) passes a
  fingerprinted redaction policy; undeclared secret data is dropped and a
  failed redaction produces no partial output.
- **Lab stays local.** The Lab observer attaches only to targets on the same
  machine, reads the distribution cookie only from a private file, never
  prints it, and loads code only into `development`, `test`, or `ci` targets.
  The OTLP receiver binds only to loopback. A way around any of these is in
  scope.

### Out of scope

- **What the `rich` profile discloses by design.** In development and test, a
  `rich` session discloses Logger messages and metadata, Telemetry metadata
  (such as query text and parameters), span attributes, and traced call
  arguments and results, because development data is expected to be
  anonymized before it reaches a developer machine. That disclosure is not a
  vulnerability; a credential that escapes masking in it is. Fields an
  application hides only through a custom `Inspect` implementation are visible
  unless they carry a credential name, as documented.
- **Documented soft bounds.** The live OpenTelemetry component's queue bound
  and the call-trace ingress byte bound are soft and apply only to
  development, test, and ci nodes: the BEAM delivers a trace message before
  Erlang code can refuse it, so these bounds throttle and stop collection
  rather than cap what the runtime copies first. The schema worker heap guard
  is enforced at garbage collection, not as a hard allocation quota. Memory
  growth within these documented limits is a known limitation, not a
  vulnerability.
- **Documented residual masking risk.** A value cut so that exactly an
  all-digit password of one to five digits remains at its end reads as a port.
- **Erlang distribution itself.** Anyone holding a node's distribution cookie
  can already run code on that node; Insider does not add a boundary there.
- **Staging and production enablement.** Insider is a pre-release proof of
  concept and production use is outside the current phase. The readiness
  artifacts under `docs/` grant no authority.
- **Vulnerabilities in dependencies.** Report them to the upstream project. We
  track known advisories with `mix deps.audit`, `mix hex.audit`, and
  Dependabot.
