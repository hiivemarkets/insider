# Live keeps mutation traces by default and names the GraphQL client

## Context

In testing, an agent took 11 minutes to prove who sent a mutation. The client's user agent was only on the request span. The first two `trace` calls found nothing, because no `--retain-traces` was set. In another run, a `ValidationError` returned inside a 200 read as `result=ok` on the kept mutation record. The kept records also could not be listed on their own.

This record extends `2026-10-25_live_watched_writes_record_keys_under_strict_and_kept_mutations_outlive_the_recorder.md`. It changes the fields of a kept record, the default for retention, and what rich capture takes from the request process.

## Decision

- **The GraphQL client, rich capture only.** While a rich session records `absinthe.execute.operation.stop`, a Telemetry handler on Phoenix's `[:phoenix, :endpoint, :start]` keeps the request's user agent and remote address in one process-dictionary key of the request process. The endpoint's `stop` deletes the key.
  - The operation stop then carries `graphql.client`: `user_agent`, credential-masked and at most 256 bytes, and `remote_ip` as text.
  - The handler is attached with the collector's handler and detached with it.
  - Strict captures no client. A rich-captured client read under strict is withheld with a drop record, as the GraphQL outcome's names are.
- **Kept records gain three fields:** `user_agent`, `typenames` (the response types) and `ids`. The ids are at most 8 values of argument fields named `id` or ending in `Id`/`_id`, from the rich `graphql_arguments`, at most 64 bytes each and never secret-shaped.
  - Strict withholds all three, as it withholds `operation`.
  - `mutations [--id ID]` (`insider.live-mutations/v1`) lists the records through the reader's view and renews the lease.
- **Mutation traces are kept by default.** With the telemetry component, retention keeps the trace of a request that ran a GraphQL mutation:
  - at most 16 traces, the least recently active let go first;
  - within the store's existing bounds of 4,096 events and 4 MiB;
  - its earlier events come from a lookback of the last 1,024 traced events (1 MiB) of traces not yet kept.

  What fell out of the lookback before the stop arrived counts as the trace's `lost`. That count is exact for the last 2,048 traces. Past the store's bounds, automatic traces go first, then mutation traces, then explicit pins' oldest events.

## Why

The client and the response type are what an agent needs to say who sent a mutation and whether it failed. Both are in the request process and in the outcome. Absinthe's metadata has no conn, so the client has to be remembered from the request's start. One key in the request process is the narrowest place to keep it. Keeping mutation traces by default costs at most the existing retention bounds plus the 1 MiB lookback. It avoids the empty `trace` that cost that agent a full retry.

## Consequences

- A rich session writes and deletes one process-dictionary key per Phoenix request while it records Absinthe operation stops. An operation outside an endpoint request has no client.
- Every session with the telemetry component now sweeps retention on the owner's tick, even with `retain_traces` 0.
- A mutation trace's events older than the lookback, and those of a 17th concurrent mutation trace, are lost. Both are counted.
- `insider.live-mutations/v1`, `status.retention.keep_mutations` and `mutation_traces`, and `graphql.client` are public contract.
