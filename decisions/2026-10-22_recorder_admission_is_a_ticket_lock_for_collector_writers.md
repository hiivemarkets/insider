# Recorder admission is a ticket lock for collector writers

## Context

This record supersedes
`2026-10-22_recorder_writers_queue_for_admission_instead_of_dropping.md`.
That record replaced the drop-on-contention admission lock with a wait
queue (an ordered ETS table of waiters, woken through process aliases)
bounded only by lock progress. Two review rounds then found problems in it
and in the patches that followed:

- the queue and each call's wait had no hard bound, because every change
  of holder renewed every waiter's wait;
- a later capacity bound was checked after a waiter had inserted its row,
  so concurrent callers exceeded it (830 rows against a capacity of 1);
- a waiter past a later total-wait ceiling could still take a free lock or
  a dead holder's lock and record;
- killed waiters' rows needed an owner sweep, and queue order rested on a
  look before the take.

Each fix added a mechanism. All of this machinery served one fact the
earlier record already stated: every production caller of `record/2` is an
Insider collector process (Logger, Telemetry, Poller, SystemMonitor, and
later the otel collector), so the writers are few and fixed by Insider, and
application processes never wait on the Recorder.

## Decision

- **Admission is a ticket lock.** A writer takes a ticket with
  `:ets.update_counter/3` and records only after it has claimed the
  `:lock` row for that ticket; release serves the next ticket. Writers are
  admitted in ticket order. Every change to the `:lock` row is a
  compare-and-swap on the whole row, so exactly one process claims or
  passes on each ticket.
- **A writer that must wait registers its ticket** with its pid and a
  process alias. The next writer in line yields between looks; the others
  sleep until woken through the alias or a 1 ms poll ends. The alias is
  deactivated and drained before the call returns.
- **Dead turns are passed on.** A holder found dead is passed on and the
  next claimant rebuilds derived state, as before. A registered writer
  found dead is passed on without delay. A ticket with no registration (a
  writer killed between taking its ticket and registering) is passed on
  after `admission_stall_ms`; if its writer was only descheduled, it finds
  its turn passed and takes a new ticket, having never claimed.
- **One bound remains: `admission_stall_ms`** (0 to 5,000, default 1,000).
  A writer gives up with `{:dropped, :contended}` when the lock has not
  changed hands for that long. A writer that gives up marks its
  registration `:abandoned` before passing its turn on, so it can never
  claim afterwards, and its abandoned turn is passed on without delay.
  Behind an overdue holder a caller gives up without taking a ticket, so
  registrations never outnumber the writers that were already waiting.
  The bound stays because `status/1`, `snapshot/1`, and `freeze/2` are
  called from the session and Live owner under deadlines, and a stuck
  holder (a suspended collector, or a blocking custom clock in tests) must
  fail them with `:busy` rather than block them; a test holds a holder
  past the bound and checks every call returns.
- **No per-call ceiling and no queue capacity.** A collector waits for its
  turn while the lock moves. Its own bounded inbox absorbs the backlog and
  sheds with counted loss, so a backed-up collector cannot grow memory.
- **Precondition, stated in the moduledoc:** `record/2`, `freeze/2`,
  `status/1`, and `snapshot/1` are called from Insider-owned collector or
  control processes, never from application processes.
- Memory, size, event, and rate bounds, receipt assignment, and loss
  accounting are unchanged. `read_since/3` and `fill/1` take no lock.

## Why not a single recorder-owned writer process

The collectors already are bounded per-source buffers with one writer
each. Another process between them and the store would make `record/2`
asynchronous, losing the admission result the collectors' `recorded` and
`recorder_dropped` counters report and the flush barrier Live reads rely
on, and would add a second buffer that drops when full.

## Evidence

The base revision lost about 4,400, 22,600, and 90,700 of 32,000, 64,000,
and 128,000 writes with 2, 4, and 8 concurrent writers in
`bench/recorder_contention.exs`; the ticket lock loses none. The bench
interleaves writer counts in each round and gates each count against the
same run's single writer; its margins come from ten recorded runs.

## Consequences

- An application process must not call the Recorder directly. Nothing
  enforces this at run time; it is a documented precondition.
- A writer behind a stuck holder waits up to `admission_stall_ms`, and
  later writers give up at once until the holder releases.
- A killed writer's registration stays until the next writer reaches its
  turn and passes it on. With no further writes it stays, one row per
  killed writer.
