# `mix insider`, the request envelope, and the CLI transport

The root application defines a closed protocol; Lab exposes it through a Mix
task and an escript. This page gives the envelope, bounds, and exit statuses
exactly as `lib/insider/protocol.ex`, `lib/insider/protocol/budget.ex`,
`tools/insider_lab/lib/insider/adapter/mix_task.ex`, and
`tools/insider_lab/lib/insider/adapter/cli.ex` define them.

## Protocol vocabulary

Protocol version `insider.protocol/v1`; request schema `insider.request/v1`;
result schema `insider.result/v1`. The 19 operations, in declaration order:

```text
runtime.capabilities  runtime.health      runtime.fingerprint  runtime.snapshot
runtime.diff          process.describe    process.await        supervision.tree
mailbox.summarize     trace.start         trace.stop           events.subscribe
incident.capture      incident.export     contract.list        contract.observe
contract.check        scenario.run        verification.run
```

Membership in this list is not availability. The standalone CLI dispatcher
implements only `runtime.capabilities`; every other operation returns
`unsupported` until a host injects an executor. The root `Insider.Runtime`
implements `runtime.capabilities` and `process.describe`.

## Request envelope

Required fields: `schema`, `protocol`, `operation`, `request_id`. Optional
fields and their defaults when decoded from a map:

| Field | Default | Accepted values |
|---|---|---|
| `environment` | `"development"` | `development`, `test`, `ci`, `staging`, `production` (the last two are then denied by policy) |
| `budget` | `{}` | object with only `max_duration_ms`, `max_events`, `max_bytes`, `max_targets`; unknown or extra fields are `invalid_budget` |
| `timeout_ms` | `budget.max_duration_ms` | integer |
| `target` | `{"node": "<local node name>"}` | object with exactly one key, `node` |
| `redaction_policy` | `"default"` | only `default` |
| `params` | `{}` | operation-specific object |
| `caller` | `"local"` | string |
| `capability` | absent | string naming the host capability a policy decision requires |
| `idempotency_key` | absent | string |

Budget floors, defaults, and ceilings:

| Field | Minimum | Default | Maximum |
|---|---|---|---|
| `max_duration_ms` | 1 | 5,000 | 600,000 |
| `max_events` | 1 | 1,000 | 100,000 |
| `max_bytes` | 16,384 | 1,048,576 | 16,777,216 |
| `max_targets` | 1 | 1 | 100 |

Decoding errors are typed: `unsupported_protocol_version` (wrong `protocol` or
`schema`), `unsupported_operation`, `invalid_request` (missing fields, unknown
environment, bad target or redaction policy), `invalid_budget`. External
strings are never converted to atoms by the decoder.

## Result envelope

`status` is one of `ok`, `error`, `timeout`, `cancelled`, `unsupported`. The
result always carries `protocol`, `request_id`, and `operation` copied from the
request so a transport can refuse an uncorrelated result. Other fields:
`value`, `error` (code, message, details), `effects`, `truncated`
(`{reason, dropped}` or `null`), `dropped`, `duration_us`,
`requested_limits`, `effective_limits`, `consumption`, `target`, five
fingerprints (`target`, `code`, `dependency`, `runtime`, `policy`), `cleanup`
(`status` one of `not_required`, `complete`, `partial`, `uncertain`,
`unknown`), `confidence` (`certain`, `high`, `medium`, `low`, `unknown`), and
`uncertainty` (list of strings). `stdout`, `stderr`, `logger_events`,
`compiler_events`, `trace_events`, `redactions`, and `warnings` are bounded
lists.

## `mix insider`

Run from `tools/insider_lab`. The task declares `@requirements ["app.start"]`,
so the current Mix project is started first and the diagnostic executes in the
same BEAM as the application.

```sh
mix insider capabilities
mix insider inspect --name Elixir.MyApp.Supervisor
```

- `capabilities` sends `runtime.capabilities`.
- `inspect --name NAME` (alias `-n`) resolves `NAME` with
  `String.to_existing_atom/1` and `Process.whereis/1`, then sends
  `process.describe` with `params.pid` set to the resolved PID and
  `capability` set to `insider.runtime.local-observation`. The name must be
  at most 256 bytes. Textual PIDs are refused.
- The task fixes the budget to `max_duration_ms` 1,000, `max_events` 1,
  `max_bytes` 65,536, `max_targets` 1, and `timeout_ms` 1,000. `request_id` is
  `mix-<unique integer>`. The environment is `development` under `MIX_ENV=dev`,
  otherwise the Mix environment name.
- A usage error, an unparseable name, or a name with no registered process
  prints an `insider.mix-task.error/v1` document with `status` `invalid_input`,
  `error.code` one of `usage`, `invalid_target`, `invalid_name`,
  `process_not_found`, a `usage` list, and exits `64`. Otherwise output and
  exit status follow the JSON transport table below.

`process.describe` returns status, reductions, memory, heap sizes, queue
length, registered name, and current function. It never returns messages,
process dictionaries, stack traces, links, monitors, or application state. It
is deadline- and heap-bounded, reports observer effect and cleanup, and is
denied in staging and production.

## The escript transport

```sh
(cd tools/insider_lab && mix escript.build)
./tools/insider_lab/insider-lab --discover
printf '%s' '{"schema":"insider.request/v1","protocol":"insider.protocol/v1","operation":"runtime.capabilities","request_id":"example-1"}' | ./tools/insider_lab/insider-lab --json
printf '%s\n' '{"schema":"insider.request/v1","protocol":"insider.protocol/v1","operation":"runtime.health","request_id":"example-2"}' | ./tools/insider_lab/insider-lab --ndjson
```

`--discover` prints `insider.cli.discovery/v1`: the operation list with each
operation's policy capability in development, the transports (`erlang`,
`json`, `ndjson`), framing, required and optional request fields, the limits
below, `default_dispatcher` `adapter_discovery_only`, and the exit-status
table. Read it instead of scraping this page.

| Limit | Value |
|---|---|
| `max_input_bytes`, `max_output_bytes`, `buffered_max_input_bytes`, `buffered_max_output_bytes` | 16,777,216 |
| `max_frames` (NDJSON) | 1,000 |
| `max_json_depth` | 8 |
| `max_json_width` | 1,000 |
| `decoder_timeout_ms` | 5,000 |
| `decoder_max_heap_words`, `max_dispatcher_heap_words` | 16,777,216 |
| `stream_terminal_error_reserve_bytes` | 1,024 |
| `max_stream_output_bytes` | `1000 * (16,777,216 + 1) + 1,024` |

Exit statuses for `--json` (one request):

| Result status | Exit |
|---|---|
| `ok` | 0 |
| `error` | 1 |
| `unsupported` | 3 |
| adapter or request input error (`insider.cli.error/v1`) | 64 |
| catastrophic stream or write failure | 70 |
| `timeout` | 124 |
| `cancelled` | 130 |

`--ndjson` processes one request per line, at most 1,000 frames and 16 MiB per
frame; blank, malformed, and oversized frames each yield one error frame
without ending the stream, and a cleanly framed stream exits 0 because each
line carries its own status. Every output frame is compact canonical JSON
followed by exactly one newline.

Dispatch runs in a spawned worker with a 16,777,216-word heap cap and the
request's own deadline. A worker that exceeds its deadline is killed and the
result is `timeout` with `cleanup.status` `uncertain` and the uncertainty
"dispatcher worker stopped; escaped runtime effects are unknown". A worker that
raises, exits, or returns an uncorrelated result yields `error` with code
`operation_failed`, `cleanup.status` `uncertain`, and the uncertainty
"dispatcher started; escaped runtime effects are unknown". Those strings are
how you tell a clean refusal from a stopped attempt.

## What the transport does not do

It does not implement runtime operations, parse ETF or textual Erlang terms
from untrusted input, trust the `environment` or `capability` a request
claims, or decide policy. A host that injects a dispatcher must recheck its
policy decision immediately before runtime work starts; the adapter only
validates the envelope, bounds the worker, and refuses uncorrelated results.
