# Telemetry discovery reads debug info and runs no application code

## Context

An agent could not learn which Telemetry events a node emits: it guessed
names, and an accepted name that stayed silent looked like inactivity.
Event names live in two places
Insider can read without the application's cooperation: the `:telemetry`
handler table and the literal event lists compiled into modules.

## Decision

- `Insider.Live.discover/1` is a public operation with the schema
  `insider.live-telemetry-discovery/v1`. It lists attached handlers' event
  names (except Insider's own) and literal event lists passed to
  `:telemetry.execute/2,3` and `:telemetry.span/3` in loaded application
  modules, each name with its sources (`handler`, `execute`, `span`) and
  module.
- The static scan reads object files only, of every loaded module except
  Insider's and those in the exact `ebin` directory of a named OTP or Elixir
  application. No installation root is excluded, because a release puts
  OTP, Elixir, and the application under one `lib` directory. A module's
  debug info is read only when its import table names one of those
  functions and the file's MD5 equals the loaded code's. The debug info
  chunk is decoded with `binary_to_term/1` and walked as a plain term in a
  per-module reader process; only the `:elixir_erl` and
  `:erl_abstract_code` data shapes are read, and the backend module a chunk
  names is never called. No application function, `module_info/0`,
  `on_load`, or compiler backend runs.
- It is bounded and runs in a worker: a 2,000 ms deadline, a 16 Mi-word
  heap guard on the worker and on each reader, 20,000 modules, 4,096 names,
  2 MiB of debug info and 2,000,000 walked nodes per module, 8 sources per
  name, 512 names returned, and at most two concurrent scans (`busy`).
  `truncated_by` names every bound that dropped evidence (`deadline`,
  `modules`, `names`, `too_large`, `walk`, `sources`, `events`).
- A `"telemetry_events"` entry ending in `"*"` is a prefix expanded by that
  scan when `start/1` is called, in the caller's process, so the owner is
  never blocked by a scan. The option's shape (a proper list of at most 64
  proper lists of at most 8 elements) is checked before anything is
  traversed. Each distinct prefix is expanded once; the expansion counts
  against the 64-event bound, is `complete: false` when a bound dropped
  names, and is fixed for the session.
- `status/1` reports `telemetry_subscriptions` with each event's `seen`
  count from the record-time gate, which now counts recorded events too
  (one `:counters.add/3` per recorded event).

## Consequences

- Names built at run time are discovered only through a handler. A stripped
  release (no debug info) yields handler names only, reported as
  `without_debug_info`.
- Decoding debug info may create atoms for names in the loaded modules'
  compile output (variables, metadata keys); the set is bounded by the
  loaded modules and repeats across scans.
- Changing the scan to call code, load modules, or read unloaded files is a
  boundary change and needs a new record.
