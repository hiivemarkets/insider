# Disclosure and safety

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

What each disclosure profile lets leave a node, how Insider masks
credentials, how Insider redacts portable evidence, what Insider will not do,
and where the production boundary is.

## Contents

- [Production boundary](#production-boundary)
- [Disclosure profiles](#disclosure-profiles)
  - [What each profile shows and withholds](#what-each-profile-shows-and-withholds)
- [Rich value rendering](#rich-value-rendering)
  - [Ecto redact fields](#ecto-redact-fields)
  - [Rendering bounds](#rendering-bounds)
- [Credential masking](#credential-masking)
  - [Credential-named keys](#credential-named-keys)
  - [Secret-shaped strings](#secret-shaped-strings)
  - [Mask records](#mask-records)
- [Redaction boundary](#redaction-boundary)
- [Safety and non-goals](#safety-and-non-goals)

## Production boundary

Insider is a pre-release proof of concept. The protocol, APIs, and package
layout are not stable. Production use is explicitly outside the current
phase. Live observation works only where the node resolves to development,
test, or ci.

[Phase 5](status-and-roadmap.md#roadmap) of the roadmap separates production
readiness from production enablement. Its
[threat model and evidence matrix](production-observation-threat-model.md)
define what Insider must prove while staging and production observation stay
denied. Separate human decisions gate an exact staging canary. Only after
reviewers accept that evidence does a further human decision gate an exact
production configuration.

The current [production-readiness dossier](production-readiness-dossier.md)
concludes that a decision is still required and that staging stays denied.
The [staged-canary runbook](staged-canary-runbook.md) is a planning artifact,
not an enablement guide. Its machine-readable worksheet has no authorization
effect.

## Disclosure profiles

Insider is a development-first debugging tool. In development and test a
live session discloses what an agent needs to debug: the `rich` profile.
`rich` assumes that your development data holds no real personal data. If it
does, set `config :insider, :live_disclosure, :strict`. A development node
still holds real provider credentials from its environment, so Insider masks
credential-shaped values in every profile (see
[Credential masking](#credential-masking)).

The host, never the caller, chooses the profile:

```elixir
# config/dev.exs
config :insider, :live_disclosure, :strict
```

The setting takes `:rich` or `:strict`. These rules apply:

- Without the setting, development and test are `rich` and ci is `strict`.
- Any other configured value is `strict`, and `disclosure_profile_source` is
  `invalid_application_env`.
- Every environment where live observation is denied is `strict`, whatever
  the setting says.
- A caller may ask for a stricter profile on a rich host: `"disclosure" =>
  "strict"` to `start/1`, or `--disclosure strict` on the observer.
- A caller that asks for `"rich"` on a strict host gets `disclosure_denied`.

```sh
mix insider.live start "${N[@]}" --component logger --disclosure strict
```

Insider checks the profile on every read. When a host narrows its profile,
a running session narrows from its next read, and `status/1` reports the
narrower profile. `capabilities/0` reports the host profile as
`disclosure_profile` with its `disclosure_profile_source`
(`application_env`, `invalid_application_env`, or `environment_default`).

### What each profile shows and withholds

`rich` passes each event as the collectors recorded it, rendered and bounded
(see [Rich value rendering](#rich-value-rendering)). `strict` is a fixed live
boundary (`insider-live-boundary/v1`) that keeps only opaque, shape-checked
values. Under `strict`, event payloads are always `nil`. The full rules are
under [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps).

| Source or feature | `rich` | `strict` | Detail |
|---|---|---|---|
| Logger message text, report, and metadata | `payload` with `level`, `message`, `metadata`, and `report` for a report message | Not collected, so no drop record. The event keeps level, domain, label, and message type | [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps) |
| Logger supervisor reports | The bounded supervisor projection | The same projection. A `binary:` supervisor or offender id becomes `binary-sha256:` and its SHA-256 | [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps) |
| Logger bursts (`logger_summary`) | `template` and `call_site` | `template` and `call_site` withheld. `template_fingerprint` and `call_site_fingerprint` kept | [Filters, summaries, and views](live/live-digest-filters-and-trends.md#filters-summaries-and-views) |
| Telemetry metadata | Every key, rendered, in `payload.metadata` | Always empty. One drop record counts the keys | [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps) |
| Telemetry measurements | Every measurement, unless `telemetry_measurements` selects some | Only selected names in the host allowlist, with integer or decimal-float values. None without `telemetry_measurements` | [Live observation](live/live-api-and-transports.md#live-observation) |
| Causality | As recorded | Only a 32-hex `trace_id` and a 16-hex `span_id`, not all zero | [Cursors and gaps](live/live-sessions-and-readers.md#cursors-and-gaps) |
| OpenTelemetry span attributes and status message | `span_attributes`, rendered, and `status_message` | Not collected. A status message recorded under `rich` is withheld | [OpenTelemetry spans and traces](live/live-otel-traces.md#opentelemetry-spans-and-traces) |
| Request path, user agent, and IP | Shown | Withheld. Method, status, and whether it was traced pass | [Request waits and bursts](live/live-otel-traces.md#request-waits-and-bursts) |
| Request timings | Shown when collected | Shown only while the host allowlist names `duration` | [Request waits and bursts](live/live-otel-traces.md#request-waits-and-bursts) |
| GraphQL operation names and `client` | Shown | Name lists and `client` withheld. `operation_type`, `result`, counts, and `withheld` pass | [GraphQL outcome](live/live-otel-traces.md#graphql-outcome) |
| GraphQL response `values` (`trace --values`) | `path = value` lines, credential-masked and bounded | Refused with `disclosure_denied` | [Response values](live/live-otel-traces.md#response-values) |
| Oban job `args` | `args` (at most 2,048 bytes) and `args_keys` | `args_keys` only | [Oban jobs](live/live-otel-traces.md#oban-jobs) |
| Kept mutation records | Every field | `operation`, `typenames`, `user_agent`, and `ids` withheld | [Kept mutation records](live/live-otel-traces.md#kept-mutation-records) |
| Call traces | Arguments, result, and reason, rendered | Function, `call_id`, `duration_us`, class, and exception module | [Call traces](live/live-runtime-evidence.md#call-traces) |
| Watched writes | Key and value | Key only | [Changes of in-memory values](live/live-runtime-evidence.md#changes-of-in-memory-values) |
| Query statements and shapes | Statements, grouped by shape | No statement. Span groups have an unknown shape, and query events are only counted | [Repeated query shapes](live/live-otel-traces.md#repeated-query-shapes) |
| Summary durations | Duration statistics and exemplar `duration_us` | Shown only when the host allowlist names every `duration_measurements` name | [Filters, summaries, and views](live/live-digest-filters-and-trends.md#filters-summaries-and-views) |
| Views by service or route | Routes resolve traces | Routes do not resolve traces | [Several agents on one session](live/live-sessions-and-readers.md#several-agents-on-one-session) |
| Timeline joins | Logger events join by process and trace | Logger events join only through a request's Telemetry events | [Timeline of a process or request](live/live-otel-traces.md#timeline-of-a-process-or-request) |
| Mark labels | Credential-masked, at most 120 bytes | The same | [Pairing marks](live/live-sessions-and-readers.md#pairing-marks) |
| One-shot inspections | The result, with each port's full name | The result, without port names | [One-shot inspections](live/live-runtime-evidence.md#one-shot-inspections) |
| Known-normal baseline | Kinds, identities, and counts | The same | [Known-normal baseline](live/live-digest-filters-and-trends.md#known-normal-baseline) |
| Credentials | Masked | Masked | [Credential masking](#credential-masking) |

Notes on the table:

- **Drop records.** Each value that the `strict` boundary withholds from a
  collected event becomes a `drop` record in the entry's `"redactions"`, with
  policy id `insider-live-boundary/v1`. A payload recorded under `rich` and
  read after the host narrowed is withheld at `["key:payload"]`.
- **Telemetry measurements.** A measurement the session did not select
  leaves a drop record with policy id `insider-live-telemetry`, in every
  profile. `capabilities/0` reports the allowlist as
  `telemetry_measurements_allowed`.
- **Request timings.** The timings are `total_us`, `response_us`,
  `headers_us`, `handler_us`, and `wait_us`.
- **GraphQL names.** Under `strict`, Insider withholds `operation_name`,
  `error_codes`, `error_paths`, `typenames`, `user_error_fields`,
  `user_error_types`, and `client`. A list becomes `[]` and a single value
  becomes `nil`. Insider captures `client` only under `rich`.
- **Response values.** The refusal carries `"field" => "values"` and
  `"required" => "rich"`. Insider refuses before it scans the session or
  changes its retention, so a refused `"retain"` pins nothing.
- **Oban jobs.** `args_keys` lists the top-level keys of the args, never a
  value. Under `rich`, Insider decodes Oban Pro `term-` values when it reads
  the event, not in the emitting process, and masks the result.
- **Call traces.** Each rendered value is at most `calls_max_bytes` JSON
  bytes. Under `strict`, arguments never leave the calling process, and
  Insider does not record results or reasons.
- **Watched writes.** Both profiles record the key: the first argument, when
  it is an atom or a binary of at most 128 bytes, credential-masked. Under
  `strict`, the trace copies only that key out of the calling process.
  Under `rich`, Insider renders the value as it renders call arguments. A
  value under a credential-named key, or a secret-shaped binary value,
  becomes `[masked: N bytes]`.
- **Query shapes.** Under `strict`, a span group's `label` is `TABLE (shape
  unknown)`. Query events disclose no table, so Insider counts them as
  `repeated_queries_ungrouped`.
- **Summary durations.** The withheld values are `duration_max_us`,
  `duration_p50_us`, `duration_p95_us`, and each exemplar's `duration_us`.
  Each has its own drop record. For an exemplar the path is
  `[key:attributes, key:summary, key:exemplars, index:N, key:duration_us]`.
  Under `strict`, Insider also withholds `duration_scope.emitter.module`.
- **One-shot inspections.** A port's full name is its spawn command line,
  at most 256 bytes. The session events that inspections record never hold
  port names, so a later narrowing changes nothing.

An example: a `strict` read of a request event withholds its path with this
record.

```elixir
%{
  "action" => "drop",
  "count" => 1,
  "path" => ["key:attributes", "key:request", "key:path"],
  "policy_id" => "insider-live-boundary/v1"
}
```

## Rich value rendering

Insider renders a rich value when the handler runs, in the emitting
process. Rendering never runs application code. Insider bounds every step
before it allocates.

- **Logger reports.** Insider never calls a report's `report_cb`. The
  payload carries the report rendered field by field under `"report"`. The
  message is the sanitized report text.
- **Structs.** Insider never calls a struct's `Inspect` implementation or a
  calendar callback. A struct renders field by field with a `"__struct__"`
  name.
- **Dates and times.** Insider itself formats `Date`, `Time`,
  `NaiveDateTime`, and `DateTime` values as sigil text, without `inspect` or
  any `Calendar` call. This applies only in `Calendar.ISO`, and only when all
  required fields are present and are in-range scalars. Any other value
  renders field by field.
- **Containers.** Maps, lists, and keyword lists keep their JSON structure.
  A keyword list with repeated keys becomes a list of one-entry objects.
  Insider reads maps and tuples only up to the width bound, by iterator and
  by index.
- **Scalars.** Atoms become strings. Floats and out-of-range integers become
  decimal strings. An integer of more than 150 digits becomes `"<integer
  over 150 digits>"`, and Insider does not convert it.
- **Logger formats.** Insider does not format a Logger format whose
  directives use a `*` width, a width or precision above 256, or more than
  8,192 in total. Its message is the sanitized format and arguments.
- **Charlists.** Insider reads the first 8,192 elements of a list as text
  and masks that text. An element that is not a character reads as a space.
  If the text holds a secret shape, the list becomes masked text. Otherwise
  it stays a list of integers. A top-level Logger metadata charlist (such as
  `file`) is text, as in Logger's own formatter.
- **Other terms.** Tuples, pids, references, and functions become `inspect`
  text of a term that Insider has already sanitized, so escaping cannot hide
  a secret.
- **Binaries.** Insider validates and scans only the first 8,192 bytes of a
  binary. A binary that is not UTF-8 there becomes `<<N bytes, not UTF-8>>`.
- **Credential pairs.** A two-element tuple whose first element names a
  credential, such as `{"authorization", _}` or `{:password, _}`, has its
  value masked, whatever its type.
- **Long keys.** Insider masks the value of a key longer than 128 bytes
  before it cuts the key.

### Ecto redact fields

Ecto `redact: true` fields stay hidden. When a session starts, the live
owner asks every loaded module that exports `__schema__/1` for
`__schema__(:redact_fields)`:

- Each module answers in its own worker process. All workers share one
  200 ms deadline.
- The worker catches any failure of the accessor. It sends only a list that
  it built and checked itself (at most 64 atoms), or `:invalid`.
- The worker sends to a process alias that closes at the deadline. The owner
  does not monitor the workers, so no exit reason reaches the owner.
- Each worker has a 65,536-word `max_heap_size` guard. The guard also counts
  reference-counted binaries. The runtime enforces it at garbage collection,
  so it stops a worker that builds a large term or binary.
- The guard is not a hard allocation or retained-memory quota. It does not
  count data shared from elsewhere (such as `:persistent_term`) or memory in
  processes that the accessor starts. The owner still receives only the
  validated atom list.

The owner keeps valid answers in a read-only table. A rich struct field
listed there becomes `"[REDACTED:redacted_field]"`, and leaves a mask record
with reason `redacted_field` under the masking policy id. A schema that did
not answer in time, failed, exceeded its cap, or was loaded after the
session started falls back to credential-name masking. A field that an
application hides only through a custom `Inspect` implementation stays
visible, unless it carries a credential name.

### Rendering bounds

The bounds are fixed:

| Bound | Value |
|---|---|
| String | 2,048 bytes. Cut text ends with `…[truncated]` |
| Logger message | 3,072 encoded bytes. Cut text ends with `…[truncated]` |
| Entries per map, list, or tuple | 32 |
| Container depth | 5. A deeper container becomes `…[depth_limit]` |
| Nodes per inspected term | 2,048 |
| Work per payload | 2,000,000 reductions, about 40 ms of one scheduler. Then `…[time_limit]` |
| Payload | 7,168 encoded bytes |
| Telemetry measurements | 1,024 encoded bytes |

Insider counts work in reductions, so load does not change the budget.
Within a payload, Insider places short values first, so a query's `source`
survives a long statement. Insider counts what does not fit under
`"$insider_truncated"`, as a map key or as a last list item.

## Credential masking

Credential masking (`masking_policy_id` `insider-credential-masking/v1`)
applies to every exported event in every profile, at every nesting level.
Insider masks again when it captures a rich value, so a value cut for size
never shows part of a secret.

Masking works by key name and value shape. It does not know what a value
means. A secret under a neutral key name, in a shape that no rule
recognizes, stays visible.

### Credential-named keys

Insider replaces a non-empty value under a credential-named key with
`"[REDACTED:credential_key]"`. Keys match case-insensitively, with `-` and
spaces read as `_`. A key is credential-named when it contains `password`,
`passwd`, `passphrase`, `secret`, `token`, `api-key`, `apikey`,
`authorization`, `bearer`, `cookie`, `private_key`, `privatekey`,
`access_key`, `credential`, `signing_key`, `encryption_key`, `session_key`,
`client_key`, or `jwt`.

### Secret-shaped strings

Insider replaces a secret-shaped span inside a string with
`"[REDACTED:<reason>]"`. The rest of the string stays readable. The reasons:

- `authorization_header`: a `Bearer`, `Basic`, or `Digest` credential.
- `jwt`.
- `pem_block`.
- `provider_key`: formats such as `sk_live_…`, `whsec_…`, `ghp_…`, `xoxb-…`,
  `AKIA…`, `AIza…`, `glpat-…`, and `sk-…`.
- `url_credentials`: URL userinfo. See the rules below.
- `credential_assignment`: the value in `password=…`, `token: "…"`,
  `"client_secret" => "…"`, or `{"cookie", "…"}`. It also covers a whole map,
  struct, tuple, or list in inspect text, such as `cookies: %{…}`.
- `high_entropy`: a token of 32 or more base64 characters that mixes upper
  case, lower case, and digits. Insider keeps lowercase hex digests, trace
  ids, and UUIDs.

Insider decides `url_credentials` by a scan of each URL's authority, not by
a regex. The scan fails closed:

- It masks the password in `scheme://user:password@host`, whatever userinfo
  characters it holds.
- It masks all of a userinfo without `:`, because it may be a token.
- It masks a password that a cut left at the end of a value or of a quoted
  value.
- A `host:port` stays readable, such as `http://127.0.0.1:4100`,
  `http://localhost:4100?x=1`,
  `{"url":"http://localhost:4100","email":"a@b.example"}`, or
  `http://[::1]:4000`.
- It masks an ambiguous unquoted list such as `http://h:4100,a@b` as
  userinfo.
- A mask that an earlier pattern left inside userinfo (a provider key or
  JWT) never ends the inspection. Insider masks the rest of the password
  too.
- A port is one to five digits. Insider masks an authority longer than
  2,048 bytes whole, up to its last `@`.
- Residual risk: when a cut leaves exactly an all-digit password of one to
  five digits at the end of a value, it reads as a port.

### Mask records

Each masked path and reason adds one record to the event's `"redactions"`.
The record never holds the value:

```elixir
%{
  "action" => "mask",
  "count" => 1,
  "path" => ["key:payload", "key:metadata", "key:api_token"],
  "policy_id" => "insider-credential-masking/v1",
  "reason" => "credential_key"
}
```

Paths use `key:` and `index:` segments relative to the event, at most eight.
An event carries at most 32 mask records. Beyond that, Insider cuts paths
short and sums counts, so every reason stays visible. Insider does not mask
map key names themselves. An Ecto `redact: true` field hidden in rich output
leaves a record with reason `redacted_field` under the same policy id.

## Redaction boundary

Insider sanitizes raw observations before they become portable evidence.
Trusted runtime configuration constructs a bounded, fingerprinted policy.
Callers do not supply callbacks, regexes, hash keys, or preexisting manifest
claims:

```elixir
{:ok, policy} =
  Insider.Redaction.Policy.new(
    id: "development-export-v1",
    maximum_sensitivity: :internal,
    rules: [
      [id: "token", path: ["token"], sensitivity: :secret, action: :drop]
    ]
  )

{:ok, outcome} = Insider.Redaction.redact(observation, :internal, policy)
```

Success contains only bounded Event-v1 data plus a deterministic disclosure
manifest. These cases return `:redaction_failed` with no partial output:
invalid retained terms, exceeded limits, deadlines, and malformed or forged
policies. Insider drops undeclared secret data by default. The capsule
exporter must call this gate on every root. It emits nothing until complete
schema validation succeeds.

## Safety and non-goals

Production may eventually run a low-overhead, redacted collector. It may
integrate with Sentry or Datadog as trigger and export adapters. Readiness
work does not enable that deployment. The linked threat model requires a
separate human gate. Production will not contain the coding model, Git
credentials, arbitrary evaluation, fault injection, or code mutation.

The current project explicitly does not promise:

- arbitrary remote evaluation in production
- automatic merge or deployment
- production fault injection
- continuous full function or message tracing
- deterministic replay of the VM, OS, database, network, or native UI
- universal business-logic diagnosis or automatic repair
- a replacement for Sentry, Datadog, or an observability platform
- general fraud detection
