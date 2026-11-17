# Recorder writers queue for admission instead of dropping

## Context

`Insider.Recorder` admits each event under a short lock held in its own ETS
control table, in the writer's process. Until now a writer that found the lock
held gave up at once and returned `{:dropped, :contended}`, so the host never
waited. In Live sessions the Logger and Telemetry collectors drain into the
same Recorder on independent 10 ms timers, and they met at the lock often
enough that `recorder_contended` gaps appeared in smoke runs and made Live
tests flaky. With 8 writers at full speed, 66% of writes were lost
to the lock.

## Decision

- A writer that finds the admission lock held, or other writers already
  waiting, joins a wait queue ordered by a node-wide monotonic ticket and is
  admitted when its turn comes. Writers are admitted in arrival order.
- The first two waiters watch the lock, yielding between looks. The others
  block until woken or until a 1 ms poll ends. Each waiter that takes the lock
  wakes the front of the queue as it leaves it, so the next one is already
  watching when the lock is released.
- Wakes go to a process alias created for the wait. The waiter deactivates
  the alias and drains any wake before it returns, so no message reaches a
  writer's mailbox after the call, including a host process's.
- A waiter whose lock holder died takes the lock over and rebuilds derived
  state, as before. A dead waiter at the front of the queue is removed by
  the waiters behind it.
- A waiter gives up only when the lock has not changed hands for
  `admission_wait_ms` (0 to 5,000, default 1,000; 0 is a single attempt),
  counted from the newest acquisition it has seen. A queue that moves is
  waited out however long it is; a stuck holder is the limit, and a writer
  arriving after the holder has already held the lock that long gives up at
  once. A writer that gives up returns `{:dropped, :contended}`, which is
  counted. `snapshot/1`, `status/1`, and `freeze/2` wait the same way and
  return `{:error, :busy}` when they give up.
- Memory, size, event, and rate bounds, receipt assignment, and loss
  accounting are unchanged. `read_since/3` and `fill/1` still take no lock.

## Evidence

`bench/recorder_contention.exs` releases 1, 2, 4, or 8 writers at once
against one Recorder, 2,000 events each, 8 rounds. On the base revision it
recorded 4,668 / 22,818 / 85,009 contended losses with 2 / 4 / 8 writers. On
this change it records none at every writer count. Two designs were tried
and rejected on the way:

- Letting every waiter spin collapsed to under half of one writer's rate with
  8 writers on a loaded machine, and still lost writes to the bound, because
  spinning waiters took CPU from the holder.
- Bounding each writer's total wait lost writes under heavy machine load
  (load average above 50) when 8 writers queued behind holders that the
  schedulers kept off the CPU for 13 to 29 ms each: the queue moved, but not
  fast enough for the last writer. Counting the bound from the last change of
  hands removed those losses.

## Consequences

- A host process that calls `record/2` may now wait while other writers are
  admitted, where it previously never waited. Each wait ends when the lock
  stops changing hands for `admission_wait_ms`, so the longest wait is that
  bound for each writer ahead in the queue, and the queue holds at most one
  entry per writing process.
- `recorder_contended` now means a real limit was reached: the lock did not
  change hands for the whole bound.
- A writer in the queue scans its own mailbox for wakes, so a writer with a
  very long mailbox pays for that scan on each wake or poll.
- The reasoning of
  `2026-10-21_live_observation_is_owner_held_leased_and_host_environment_gated.md`
  for keeping live reads off the lock still holds: frequent locked reads
  would now delay producers rather than drop their events.
