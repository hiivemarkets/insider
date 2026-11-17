# Live default mutation retention never costs explicit retention

## Context

`2026-10-25_live_keeps_mutation_traces_by_default_and_names_the_graphql_client.md` kept the traces of mutation requests by default. A review found three places where that default could lose or misattribute evidence:

- Past the store's bounds, automatic traces went before mutation traces. The default could therefore cost what `retain_traces` keeps.
- A trace the automatic pool let go took its earlier events with it, so a later mutation stop kept only itself, with `lost` 0.
- At 2,048 loss counters, all of them were cleared, so recent losses were forgotten.

Separately, a request's remembered GraphQL client outlived a collection that stopped mid-request, and a later collection took it for its own.

This record supersedes the earlier record's eviction order and its "exact for the last 2,048 traces" clause. The rest of the earlier record stands.

## Decision

- **Eviction order.** Past the store's bounds, mutation traces (the default) go first, then automatic traces, then the oldest events of explicit pins.
- **Automatic traces that run a mutation.** Such a trace stays automatic while the `retain_traces` pool keeps it. When the pool lets it go, it becomes a mutation trace (within the 16-trace bound).
- **Traces the automatic pool lets go.** Any other trace the pool lets go has its events moved to the mutation lookback, while mutation traces are kept. A later mutation stop of that trace finds them there.
- **Loss counters.** They are kept for the 2,048 traces updated last. Past that, the least recently updated counter goes, counted as `retention.loss_counters_evicted`. That trace's later loss is then unknown, not reported as 0.
- **Remembered clients.** Each Telemetry collection has its own generation. A remembered client is stored bounded and masked, with the generation that remembered it, and counts only for that generation. Phoenix's endpoint `exception` also forgets it.

## Why

`--retain` and `retain_traces` are explicit requests. A default must never shrink what those requests kept before the default existed. Attributing an operation to the wrong client is worse than naming no client, so stale data is rejected rather than trusted.

## Consequences

- With `retain_traces` set, mutation traces may be evicted earlier than automatic traces, so the default is the first to give way.
- Moving the events of a let-go automatic trace into the lookback can push older lookback events out. Those losses are counted.
- `retention.loss_counters_evicted` is public in `status`.
