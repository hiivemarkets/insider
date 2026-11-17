# OTLP ingress is a loopback Lab receiver, and only the target masks what it receives

## Context

A frontend's Next.js dev server exports OpenTelemetry spans over OTLP/HTTP.
To read one trace from the frontend request into a BEAM node, those spans
must reach the node's live session. This is Insider's first listening
network endpoint and its first contract for evidence that does not come from
the observed node itself.

## Decision

- The receiver is Lab-only (`mix insider.live otlp-receive`), runs in the
  observer, and never in the core or the production artifact. It listens on
  a loopback address literal only (`127.0.0.1` by default, or `::1`); any
  other `--bind` is `non_loopback_bind`. It authenticates nobody: loopback is
  the trust boundary, as it is for the observer's own target.
- It accepts `POST /v1/traces` with a `Content-Length` body of OTLP protobuf
  or JSON, optionally gzip, at most 4 MiB before and after decompression,
  with bounded request lines, headers and read time. It serves one
  connection at a time and hands one report at a time to its output: it
  accepts the next connection only after the previous report was written, so
  a stalled consumer holds clients back in the listen backlog instead of
  growing memory.
- The observer only decodes and validates the wire format and identifier
  widths. It forwards plain span maps to the target's
  `Insider.Live.ingest_spans/2` (`insider.live-ingest/v1`: `accepted`,
  `rejected`, `filtered`, `shed`, `session_id`), at most 512 per call. The
  target applies the span contract, the session's disclosure profile and
  credential masking, exactly as for spans its own SDK ends. The observer's
  output carries counts and validated trace ids only, never span names,
  attributes or resource values such as `service.name`.
- Ingest runs inside the live owner, ordered with `start` and `stop`, and
  names its session: spans are recorded only by the collector of that
  session while it is running, never by a session started later. When the
  session ends, the receiver's next export is refused and the receiver
  stops.

## Why

Masking in the observer would be a second, divergent copy of the target's
redaction policy, and the observer does not know the session's profile. A
receiver inside the target node would put a listening socket into the
observed application. A collector process (the OpenTelemetry Collector) was
rejected as an extra dependency for a development loop. Checking the
session's status and then recording through the globally registered
collector let a stop and a start in between put spans into the next session
(found in review), so the check and the write are one owner operation.

## Consequences

- The frontend must point a development-only exporter at loopback; Insider
  offers no remote or authenticated ingest, and adding one needs a new
  decision.
- A malformed export is refused with an HTTP status and a fixed reason, and
  the receiver keeps running; a target that is gone answers `503` so the
  exporter retries.
- Browser-originated spans are out of scope: a browser has no loopback path
  to the observer.
