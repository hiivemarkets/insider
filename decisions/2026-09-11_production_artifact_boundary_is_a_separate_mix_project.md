# Production artifact boundary is a separate Mix project

## Decision

Ship the root `:insider` application as the production-safe collector and
evidence core. Put Sentinel, fixtures, contract/invariant and scenario
execution, CLI/Mix/escript interfaces, external-process/sandbox code, and the
restart-capture fixture harness in `tools/insider_lab`, a separately buildable,
non-published Mix project that depends on `:insider` by local path.

The root application has no dependency on Lab and starts no execution component.
This is a package and artifact boundary, not an environment flag.

## Evidence

`scripts/verify-production-artifact` creates a fresh production build and
release, then rejects forbidden source paths/modules, source links,
command/mutation primitives, forbidden beam and application inventory, Lab
release contents, and a release VM that can load a Lab-only module. Its tests
inject forbidden source, source-link, and compiled-module entries to prove
failure. CI runs the root boundary gate and the independently buildable Lab
suite on every supported OTP lane.

## Consequences

- Existing staging and production denials remain unchanged.
- A capsule or any Lab result grants no provider, credential, network,
  publication, repository, deployment, or mutation authority.
- Hex publication is deferred: the repository has no approved publishing
  metadata, so a Hex unpack check is intentionally out of scope until that
  separate decision.
- Production capability additions must preserve this inventory gate or receive
  a separately reviewed boundary decision.
