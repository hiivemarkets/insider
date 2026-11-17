# Protected targets and ingress profiles are host-owned

## Decision

Runtime and Poller consult one immutable protected-target policy before any
provider work. The policy resolves a versioned BEAM/OTP/Elixir registry at
classification time and binds its configured registration names plus local OTP
major into its fingerprint. It accepts only bounded additive host declarations,
and binds Poller's own PID plus its recorder PID and fixed `Insider.Supervisor`
when the collector starts. A
caller cannot provide a control-plane inventory to `classify/2`, omit it from a
bound session, or replace it through collector options.

Ingress profiles are required, explicit, finite host selections. Development, test, and
CI can attach Logger and Telemetry collectors. Staging and production profiles
are deliberately denied. Their tested safe defaults retain only fixed
structural Logger attributes: payload, subject, wall time, domain, causality,
and all message/metadata-derived identifiers/fingerprints are suppressed.
Telemetry continues
to project only its exact policy allowlists before the recorder handoff.

## Consequences

- Protected target denials include bounded policy evidence and occur before a
  Runtime/Poller provider runs.
- Host declarations can only add protections. There is no provider, identity,
  assignment, authorization, mutation, network, or production enablement path.
- `SystemMonitor` is not an explicit target-taking collector. Protected-subject
  filtering for its passive node-global ingress is deferred and it remains
  staging/production-denied.
- A later production enablement needs a separate human decision and a reviewed
  exact ingress/target inventory; this decision provides no exception mechanism.
