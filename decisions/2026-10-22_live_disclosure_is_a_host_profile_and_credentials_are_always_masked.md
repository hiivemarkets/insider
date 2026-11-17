# Live disclosure is a host-chosen profile, and credentials are always masked

## Context

The 2026-10-21 live observation decision fixed one disclosure boundary for
every live session: no Logger message content, report fields, or metadata, no
Telemetry metadata, and only allowlisted numeric measurements. In use, that
boundary left an agent unable to debug: it could see that a repo query took
930 µs but not which query. Insider is a development-first debugging tool and
a partner to the developer who directs the agent. A host may anonymize data
before it reaches a developer machine, so its development data may carry no
personal-data concern. Credentials are different: a local development node
may hold real provider keys in its environment.

## Decision

This supersedes the "never collected" and "fixed boundary" parts of
`2026-10-21_live_observation_is_owner_held_leased_and_host_environment_gated.md`.

- **Profiles.** `Insider.Live.Disclosure` has two profiles. `rich` discloses
  Logger message text and metadata, Telemetry metadata, and all measurements,
  rendered at collection by `Insider.Collector.Rich` into bounded,
  JSON-shaped values. `strict` is the previous boundary, unchanged.
- **The host chooses.** `config :insider, :live_disclosure` selects `:rich`
  or `:strict`. Without it, development and test are `rich` and ci is
  `strict`. Any other value is `strict`, and every environment where live
  observation is denied (staging, production, unconfigured, unrecognized) is
  `strict` whatever is configured. A future staging or production option
  starts from `strict`.
- **Callers may only narrow.** `start/1` accepts `"disclosure"`; a profile
  stricter than the host's is honoured, a richer one is `disclosure_denied`.
  The effective profile is re-read on every read, so a host that narrows its
  profile narrows running sessions from their next read.
- **Credential masking in every profile.** `Insider.Redaction.Credentials`
  (`insider-credential-masking/v1`) masks values under credential-named keys
  and secret-shaped spans (HTTP `Bearer`/`Basic` credentials, JWTs, PEM
  blocks, well-known provider key formats, URL passwords, `key=value`
  credential assignments, and long high-entropy tokens) in every exported
  event at every nesting level. Rich capture masks before it cuts a value for
  size. Each mask leaves a `mask` record with its reason and path, never the
  value.
- **Reporting.** `capabilities/0` reports the host profile, its source, the
  profile names, and the masking policy id; session start and status report
  the effective profile and the masking policy id.

## Why

A debugging partner that cannot see the query, the route, or the log line is
not useful, and development data is often anonymized or synthetic, so the
strict boundary cost the developer much and protected little. Keeping the
choice with the host, and only ever letting a caller narrow, preserves the
original reason for the boundary: the transport caller is not trusted to make
disclosure decisions. Several agents may share one node, so the profile is a
node property, not a per-caller grant.

Masking stays unconditional because credentials are the one real secret on a
development node, and an agent transcript is a place they must not reach.
`Insider.Redaction` was considered for this and kept for what it does:
path-declared rules over a bounded walk. Credential masking needs key-name and
value-shape matching anywhere in an arbitrary term, so it is a separate,
reusable module in the redaction namespace.

Rich values are rendered in the emitting process, so the recorder never holds
raw terms and the existing per-event size and depth bounds hold. Structs
render through their own `Inspect` implementation, which keeps fields an
application already redacts (for example `redact: true` Ecto fields) hidden.

## Consequences

- In development and test, an agent now sees log text, metadata, query
  statements, parameters, and results. It must treat that output as
  development data.
- Masking is heuristic. A credential under an innocuous key and without a
  known shape (for example a short random password in a positional query
  parameter) is not recognised. Map key names are not masked. False positives
  (a `token` measurement, a 32-character mixed-case identifier) are masked
  and recorded, which costs readability, not safety.
- Rich capture costs more in the emitting process than the strict
  projection; it is a development profile and has no production budget.
- The strict profile, its `insider-live-boundary/v1` drop records, and the
  measurement allowlist are unchanged, so ci output is unchanged apart from
  mask records where a strict value matches a credential rule.
