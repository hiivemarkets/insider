# Inspections use recon only where it respects protected targets

## Context

Two agents compared Insider, recon, and observer_cli on a faulty shop node.
Both rated recon 5/5 and asked Insider to wrap a curated
subset as bounded JSON operations: `process`, `bin_leak`, `ports`, and
`alloc`, plus a port census as a Poller sample. Insider's protected-target
policy says a protected process (the fixed OTP inventory and host
declarations) is never read.

## Decision

- `Insider.Live.process/1`, `bin_leak/1`, `ports/1`, and `alloc/1` run once
  in a worker under a 3 s deadline and a heap guard, at most two at once,
  return at most 64 KiB, pass the disclosure profile and credential
  masking, and are recorded in a running session as `inspect.*` events
  through `Insider.Collector.Session.record_event/3`, which records in the
  session process and is refused after the seal.
- recon is used where it reads no process: `ports` counts types with
  `recon:port_types/0` and `alloc` needs `recon_alloc` (without recon,
  `component_unavailable`).
- `process` and `bin_leak` are always Insider's own. `recon:info/1` reads
  the process dictionary, and `recon:bin_leak/1` reads and garbage-collects
  every process, protected ones included. Insider's versions skip protected
  processes.
- `bin_leak` ranks two ways: `by_retained_bytes` (what a process still
  references after a collection) and `by_freed_bytes` (what the collection
  released, recon's notion). recon's freed-only ranking cannot name a
  process that keeps sub-binaries on purpose, such as the shop's
  ImageCache, whose binaries are referenced and never freed.
- `process` never reads a message value, a dictionary key other than
  `$initial_call`, or `sys:get_state/1`. It reads a mailbox of at most
  10,000 messages in a separate reader under its own heap guard, which
  keeps only the shapes (types in place of values; in strict, atoms only as
  tags).
- The Poller's `port_top` (`top_ports`) types a port by the first word of
  its name without a directory, so a spawn command's arguments are never
  recorded; the full name appears only in a `ports` result under the rich
  profile.
- recon (BSD-3-Clause) is a Lab runtime dependency and a root test-only
  dependency. Insider's core never depends on it. The observer's `--load`
  pushes it, loaded and never started, into a development, test, or ci
  target that cannot resolve it.

## Consequences

- With recon on a node, `ports` counts include Insider's own ports in
  `types`; the native census leaves them out.
- `bin_leak` collects every unprotected process once: an observer effect
  it reports as `observer_effect`.
- A process's mailbox is copied once into a reader when it is read; queues
  longer than 10,000 messages are reported by length alone.
