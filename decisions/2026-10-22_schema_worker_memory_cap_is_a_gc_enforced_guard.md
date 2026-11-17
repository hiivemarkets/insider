# The schema-worker memory cap is a garbage-collection guard, not a quota

## Context

`2026-10-22_rich_rendering_formats_iso_values_itself_and_bounds_schema_workers.md`
says each schema worker's memory cap counts reference-counted binaries, "so
building or holding a large term or binary kills it". Review showed that is
stronger than the runtime provides: an accessor that returns a 16 MiB binary
already held in `:persistent_term` keeps a 233-word heap, survives, and its
validated answer is accepted.

## Decision

This clarifies that record's memory-cap sentence; the rest of it stands.

- The worker's `max_heap_size` (65,536 words, `include_shared_binaries: true`)
  is a guard the runtime checks at garbage collection. It stops a worker that
  builds a large term or binary of its own.
- It is not a hard allocation or retained-memory quota. Data the worker only
  references from shared storage (such as `:persistent_term`) and memory in
  processes the accessor starts are not counted.
- The owner-side guarantee is unchanged and does not depend on the cap: the
  only term a worker can make the owner copy is a list of at most 64 atoms it
  built and checked itself, or `:invalid`.

## Consequences

- A schema accessor can still use memory outside the cap for up to the 200 ms
  collection deadline, after which its worker is killed.
- Documentation (README, source comment) states the cap's limits.
