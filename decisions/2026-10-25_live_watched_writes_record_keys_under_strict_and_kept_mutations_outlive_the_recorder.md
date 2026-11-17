# Live watched writes record keys under strict, and kept mutations outlive the Recorder

## Context

A dev feature flag that every process shares, such as one kept in a `MyApp.Flags.Overrides` store, can be flipped by another developer's `setFeatureToggle` request. When the store holds only the current value, nothing shows who flipped the flag, or when. The mutation's outcome is only in the Recorder, and only until a flood evicts it.

Three things answer this:

- watched writes (`watch_writes`);
- a per-session ring of compact mutation records;
- a mutation's inputs in `trace --values`.

Together they move three boundaries. Strict call tracing now copies an argument. A session keeps evidence outside the Recorder. And mutation inputs are payload content.

This record partly supersedes `2026-10-22_live_call_trace_ingress_has_a_documented_soft_bound.md`. That record said: "the strict profile traces with the `arity` flag, so no argument is copied". This record narrows the claim to "no argument except a watched write's key". The rest of that record stands.

## Decision

**Watched writes.** Start option `watch_writes` (at most 8 functions, with the calls component) traces each named write function as a call trace. It stays within the call trace's bounds and limits: `calls_max`, the rate, the ingress bound, and cleanup. Each call records a `call` event with `"write" => true` and `"key"`.

| Field | Strict | Rich |
|---|---|---|
| `key`: the first argument, or the application and key of `Application.put_env` / `:application.set_env`, when it is an atom or a binary of at most 128 bytes | yes, credential-masked | yes, credential-masked |
| `key` otherwise | `nil`; the call is still recorded and counted toward the limits | `nil` |
| writing process (`subject.value`) | yes | yes |
| written value (`payload.arguments` after the key) | never | rendered and masked |
| value under a credential-named key, or a secret-shaped binary value | never | `[masked: N bytes]` only (N is the binary's size or the term's external size) |

Under strict, the key is the only argument that leaves the calling process. A match-spec `{message, Key}` copies it. Every other call sends the fixed message `{:insider_unnamed_key}`, never `false`: `false` would suppress the call's notification, and with it its record and the trace's limits. Runtime-preloaded functions (`:persistent_term.put/2`, `:ets.insert/2`) stay refused. Agents watch the application's own write function instead.

**Writer attribution.** `changes` names a write's writer from one request only. First come the events of the writing process whose time covers the write. If those events name two traces, the write is `unattributed`. Without covering events, the nearest following event of the process is used (within 60 s), together with only the events of that event's trace. Next comes the process's kept mutation record, when its trace agrees. Otherwise the write is `unattributed`. A user id comes only from a span attribute or Logger metadata under rich.

**Kept mutation records.** A session with the telemetry component keeps a ring (`Insider.Live.Mutations`) of at most 4,096 compact records, one per GraphQL mutation, apart from the Recorder. Each record holds:

- `receipt`, `at`, `trace_id` and `pid`;
- `operation` (rich only; `nil` under strict);
- `result`, `error_count` and `user_error_count`;
- the fields a reader's view reads.

Filling the ring:

- The owner fills it from raw, redaction-checked reads on its 500 ms push tick.
- Every loss is counted: `dropped` (oldest records past the bound) and `missed_receipts` (receipts evicted before a tick read them).
- The ring lives as long as the session's retained record.

Reading the ring:

- Records pass the reader's view, given or stored, as events do.
- `trace` says a kept record's event was evicted only when a Recorder read no longer finds its receipt.

**Mutation inputs.** `trace --values` (rich only) adds the current mutation's arguments after Absinthe's input conversion, by schema name. Raw `variables` are never used. A credential-named argument is masked whole. The rest are bounded to 2,048 JSON bytes and masked by the rich renderer. Strict records none and refuses `values`.

**Counts.** `changes` and the digest count every write they read. Detail rows are paged (the newest 256, with `omitted`), and the digest keeps at most 1,024 writes. A window with gaps (evictions, an unread budget, or capped writes) reports counts as lower bounds ("at least N", `complete: false`).

## Why

The evidence that answers "who changed it" is the key, the writing process and its request. The key is a name the store already exposes, not content, and strict needs it to answer at all. The value is content, so only rich carries it, and never when the key names a credential. A ring of a few fields per mutation is cheap: 4,096 records of about 300 bytes, about 1.2 MB. Unlike the Recorder, a log or request flood cannot evict it.

## Consequences

- Under strict, watched-write keys are disclosed to readers. Credential-shaped keys are masked, and longer or non-name keys are withheld as `nil`.
- Some mutations can still be lost: a mutation whose operation stop the Recorder evicts within one push tick is not kept, but it is counted in `missed_receipts`.
- After eviction, a kept record names the operation and trace, not the user or route.
- The Lab `changes` command, `insider.live-changes/v1`, and `status.mutations` are public contract.
