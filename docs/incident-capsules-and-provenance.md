# Incident capsules and provenance

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The sealed, content-addressed incident capsule, the provenance it carries, and
the inert observability trigger and export data that a host integration can
map.

## Contents

- [Incident capsules](#incident-capsules)
- [Portable provenance](#portable-provenance)
- [Observability integration boundary](#observability-integration-boundary)

## Incident capsules

`Insider.Incident.Capsule` assembles a deterministic redacted artifact from five
inputs: a sealed recorder snapshot, a normalized finding, provenance, audit
authority, and digest-only artifact references. A trusted
`Insider.Incident.ExportPolicy` classifies every export root. Assembly rejects
caller-provided Event redaction claims. It invokes the configured redaction
policy itself, and it revalidates every sanitized root before it produces bytes.

Capsule v1 chains sanitized event entries and content-addresses the full
envelope. Its canonical decoder rejects corruption and alternate JSON encodings.
It does not consult a live BEAM node or fetch referenced artifacts. In this
proof of concept (an early, deliberately small implementation), a capsule
accepts at most 64 events, 32 artifact references, and 1 MiB of canonical JSON.
It rejects larger snapshots instead of silently truncating evidence.

`Insider.Finding` gives new capsules one exact detector-neutral envelope with
bounded detector-specific details. "Detector-neutral wire envelope" means one
fixed JSON shape that every detector uses. Only the `details` map differs per
detector. The envelope has the schema `insider.finding/v1` and exactly these
keys:

```text
schema  detector  detector_version  fingerprint  occurred_at_us
confidence  severity  trigger_event_id  evidence_event_ids  details
```

Static validators for restart-recurrence and mailbox-growth findings
recompute fingerprints independently. They reject cross-detector field
substitution, and they correlate every ordered evidence event with the claimed
summary. Previously emitted flat restart findings remain a read-only v1
variant. Their canonical capsule bytes and integrity digests therefore still
verify unchanged.

## Portable provenance

`Insider.Provenance` records five independently fingerprinted evidence
components: code, configuration, dependencies, runtime, and target. Every
component is explicitly available, unavailable with a closed reason, or
redacted under a named policy fingerprint. The built-in capture path records
stable BEAM and machine-class facts without reading Git, environment variables,
hostnames, paths, or other volatile and potentially sensitive runtime state.

Build systems can supply already-sanitized revision, lock, configuration, and
deployment facts. Equivalent string-keyed maps produce the same canonical JSON
and SHA-256 fingerprints regardless of insertion order. Materially different
facts and explicit absence states change the aggregate fingerprint.

## Observability integration boundary

Vendor integrations begin as inert, canonical data rather than clients:

```elixir
{:ok, trigger} =
  Insider.Observability.Trigger.new(
    operation: "follow_up",
    provider: "sentry",
    external_event_fingerprint: keyed_event_fingerprint,
    external_incident_fingerprint: keyed_incident_fingerprint
  )

{:ok, export} =
  Insider.Observability.Export.new(capsule, "sentry", destination_fingerprint)

{:ok, ^export} =
  Insider.Observability.Export.validate_against_capsule(export, capsule)

{:ok, mock_event} =
  Insider.Observability.Sentry.map(export, capsule)

true = mock_event.mock
"not_attempted" = mock_event.delivery_status
```

A trusted host authenticates a vendor signal and supplies approved keyed
correlation fingerprints. Insider does not retain raw external IDs. A trigger
can request only local freeze or follow-up handling. It cannot choose an
environment, target, authority, collection scope, redaction policy, endpoint,
credential, or callback. It does not prove that the requested operation ran.
External delivery cannot be required to preserve the local pre-trigger window.

An export is recomputed from a validated, already-redacted capsule and contains
only a fixed structural summary. It excludes event bodies, payloads, artifacts,
provenance attributes, audit identifiers, endpoints, credentials, and client
configuration. Standalone validation proves canonical identity, not authentic
capsule derivation. A host integration must revalidate against the full capsule
immediately before mapping or delivery.

Provider SDKs, callback authentication, TLS, destination allowlists,
credentials, bounded asynchronous queues, retries, circuit breaking, and
delivery receipts remain host-owned. Mapping success is not evidence of remote
delivery, production readiness, or rollout authorization. The included Sentry
ingestion-event and Datadog Events v2 projections are deterministic mock data
inside an exact `insider.observability-mock-event/v1` envelope. That envelope is
always marked `mock: true` and `delivery_status: not_attempted`. Its handoff
metadata names the host application as the owner of any asynchronous handling.
`Insider.Observability.MockHostClient` is a behaviour contract only: Insider
provides no implementation and never invokes it. No provider SDK, endpoint,
credential, HTTP transport, queue, retry, callback receiver, or send operation
is included. Live delivery and staging or production rollout remain unsupported
and require a separate security, privacy, and operations decision.
