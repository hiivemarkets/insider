# Architecture

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The loop Insider serves, the trust boundary between the in-application
collector and the Lab-only Sentinel, the module boundaries, and the packaging
boundary that keeps Lab code out of a production build.

## Contents

- [The intended loop](#the-intended-loop)
- [Architecture and trust boundary](#architecture-and-trust-boundary)
- [Module boundaries](#module-boundaries)
- [Production artifact boundary](#production-artifact-boundary)

## The intended loop

Insider is a runtime-evidence library for BEAM applications, built for coding agents.

The library turns bounded OTP, Logger, Telemetry, supervision, process, and VM
signals into structured evidence. Agents and tools can detect, reproduce, and
verify failures from that evidence safely.

The individual signals already exist across the BEAM ecosystem. Insider's value
is the loop around them: correlate evidence, preserve the causal window, prove a
failure on a clean target, create a regression, and verify a repair. The
long-term goal is to let agents investigate and draft fixes rapidly. An agent
never gets unrestricted control of a production node.

```text
BEAM/OTP signals + application contracts
                  |
                  v
       normalize and correlate
                  |
                  v
        bounded flight recorder
                  |
                  v
          incident capsule
                  |
          sanitized export
                  v
       external clean-room Sentinel
     reproduce -> regress -> repair -> verify
                  |
                  v
       evidence-rich draft output / PR
```

An exit status or exception is not sufficient proof. Insider records observed
effects, runtime and code provenance, truncation, cleanup, and uncertainty. If a
failure cannot be reproduced or its oracle is weak, the outcome stays
inconclusive rather than becoming a speculative fix.

## Architecture and trust boundary

The in-application collector is deliberately boring. It is bounded,
read-mostly, redacted, failure-isolated, and credential-free. It normalizes
events, maintains a fixed-size pre/post-trigger recorder, evaluates precise
detectors, and exports immutable incident capsules.

The Lab-only external `Insider.Sentinel` is the only place for mutating work.
It runs only against disposable targets supplied by a trusted provider
allowlist. At this revision it performs these steps:

- reproduction
- regression materialization
- minimization
- bisection over host-declared targets
- before/after verification through host-allowlisted body modules
- inert draft-proposal assembly

Checkout creation, dependency restoration, source changes, and draft PR
creation are not implemented. Every portable Sentinel artifact records
`source_mutation=prohibited` or `repository_mutation=none`. The draft-creation
gate has only test-fixture providers. The capsule boundary remains
serializable, so a reader can inspect or replay evidence without access to the
original live node.

## Module boundaries

Each module owns one concern:

- `Insider.Protocol`: versioned commands, results, effects, budgets, and
  serialization.
- `Insider.Policy`: capability discovery and deny-by-default runtime
  authorization from trusted runtime context.
- `Insider.Event`: the versioned, bounded event schema that collectors and
  detectors share.
- `Insider.Redaction`: fail-closed sanitization of untrusted terms into
  bounded event values.
- `Insider.Collector`: runtime signal adapters and normalized ingestion.
- `Insider.Identity`: explicit same-node process generations, logical actors,
  operations, and conflict-safe event correlation.
- `Insider.Recorder`: bounded storage, correlation, trigger windows, and
  pressure behavior.
- `Insider.Detectors`: high-confidence runtime and lifecycle findings.
- `Insider.Contract` (Lab-only): application semantics, invariants,
  ownership, and redaction declarations.
- `Insider.Incident`: portable capsules, fingerprints, provenance, and
  evidence integrity.
- `Insider.Observability`: inert vendor triggers, exports, and mock
  projections for a host integration to map.
- `Insider.Live`: live observation of a running development, test, or ci
  node. A supervised owner holds one leased collector session, and callers
  read it with cursors and gaps.
- `Insider.Runtime`: the bounded same-node diagnostic API and environment
  policy.
- CLI, JSON, and NDJSON adapters (Lab-only), and later MCP adapters:
  transports over the same domain API.
- `Insider.Sentinel` (Lab-only): clean-target reproduction and verification
  outside the observed application.

## Production artifact boundary

The root `:insider` application is the production-safe collector and evidence
core. It contains only bounded observation, detector, recorder, redaction,
capsule, policy, and runtime-facade code. It has no escript, Mix task, fixture,
contract/invariant executor, scenario runner, Sentinel, command runner, or
provider-mutation surface.

Those development and disposable-environment capabilities live in the separate
[`tools/insider_lab`](https://github.com/hiivemarkets/insider/blob/main/tools/insider_lab/README.md) Mix project, published to Hex as `insider_lab`.
Lab depends on the core (by path in this repository, from Hex in its package). The core never depends on Lab. This is a
physical packaging boundary, not a runtime feature flag. Verify each artifact
independently:

```sh
mix test --cover
bash scripts/verify-production-artifact
(cd tools/insider_lab && mix test)
```

The artifact gate builds a fresh production release, inventories its source,
application, beam, and release contents, and boots the release to prove that
Lab-only modules cannot load. The core and the Lab are separate Hex packages,
and the core's package holds no Lab code.
