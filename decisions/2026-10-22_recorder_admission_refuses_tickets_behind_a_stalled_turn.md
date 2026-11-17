# Recorder admission refuses tickets behind a stalled turn, and its bench is meant for an idle host

## Context

`2026-10-22_recorder_admission_is_a_ticket_lock_for_collector_writers.md`
said that behind an overdue holder a caller gives up without taking a
ticket, so registrations never outnumber the writers already waiting.
Review showed the rule covered only a turn with a live holder. A served turn
that a live, registered writer has not yet claimed (for example, the writer
was suspended after its predecessor released) let every later call take a
ticket, wait out the stall bound, and leave an abandoned registration: 201
rows after 200 calls from one process. The same review showed the contention
bench failing on the reviewer's machine, and that a Recorder lost during a
wait left the writer's wake alias active.

This record supersedes that record's sentence on overdue holders. The rest
of it stays in force.

## Decision

- Before taking a ticket, a caller looks at the served turn. If it has not
  changed for `admission_stall_ms`, the caller passes it on when it can (its
  holder or registered writer is dead, or its writer gave up) and then
  proceeds; when the turn is held or registered by a live writer, the caller
  returns `:contended` without taking a ticket. A turn with no registration
  is free or about to be claimed, and the caller takes a ticket as usual.
  Registrations therefore grow with the number of writing processes, not
  with repeated calls.
- A waiter registers inside the protected scope, and its wake alias is
  deactivated and drained in an outer `after`, which runs even when the
  Recorder's tables are gone.
- `bench/recorder_contention.exs` is meant to run on an idle host. A FIFO
  lock hands each turn to one writer, so when the OS preempts that writer's
  scheduler thread every writer behind it waits out the OS time slice. As
  an advisory screen, the bench probes scheduler-thread preemption before
  and after each round (not during it, where the probe would compete with
  the writers), gates on the median of per-round ratios over 8 rounds whose
  probes were quiet, and exits 2 (inconclusive) when it cannot get them
  within 20 rounds. The probes cannot see a pause inside a round.

## Evidence

The new regressions reproduce both review findings on the previous
revision (202 rows; a late message delivered through the alias) and pass
on this one. Beside 20 busy shell loops on a many-core host, the previous
bench reported 4- and 8-writer p95 at 8.6x and 9.4x the fair share and
throughput at a quarter of one writer's, with p50 unchanged.

## Consequences

- A collector behind a writer that is alive but not running gives up after
  the stall bound and keeps giving up, without registering, until the turn
  moves.
- The bench refuses to judge when the host was visibly busy around its
  rounds, but a pause inside a round goes unseen, so a pass is evidence
  only for a host that was otherwise idle; the median over 8 rounds keeps
  one disturbed round from deciding the result.
- Production deployments are not affected by the bench, but the FIFO lock's
  sensitivity to OS preemption is real: on an oversubscribed host,
  contended writes wait for the preempted writer.
