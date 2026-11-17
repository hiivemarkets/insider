# Recorder admission waiters sleep and never spin

## Context

`2026-10-22_recorder_admission_is_a_ticket_lock_for_collector_writers.md`
decided that "the next writer in line yields between looks; the others
sleep until woken through the alias or a 1 ms poll ends". This record
supersedes that sentence. The rest of that record, and of
`2026-10-22_recorder_admission_refuses_tickets_behind_a_stalled_turn.md`,
stays in force.

A writer that yields between looks is always runnable. While it waits, its
scheduler does not sleep and does not take work from another scheduler, and
every process queued on that scheduler, the host application's included,
takes turns with it. The Logger and Telemetry collectors drain on their own
timers, so under load one often waits for the other, and on a host with two
schedulers the waiter held half of them. After the ticket lock
reached the development branch, the load harness's overload phase
(5,000 operations/s on GitHub's 2-scheduler runners) missed one 10 ms tick
(50 operations) in 4 of 6 jobs.

## Decision

- Every waiter sleeps on its alias until it is woken or a 1 ms poll ends,
  then looks again. That includes the next writer in line. Release wakes
  only the writer of the turn it serves.
- Whether the served turn can be passed on is still checked every 64 looks,
  and when the stall bound is reached. A waiter now sleeps at least 1 ms
  between looks, so the next writer in line notices a dead holder after 64
  polls (nominally 64 ms, later if it is scheduled late), not after 64
  yields.

## Evidence

- `RecorderTest` "a writer next in line for the lock sleeps until its turn
  instead of spinning" measures the next writer's reductions while a holder
  keeps the lock for 100 ms: 5,429,698 with the yield loop and 650 without
  it. The test's bound is 20,000.
- `load-soak.yml` dispatched on GitHub runners (2 schedulers), the `load`
  profile, Elixir 1.17/OTP 27, 1.19/OTP 28 and 1.20/OTP 29:
  - At the ticket-lock revision, two runs: max tick lag 5.3, 15.9 and 7.3 ms,
    then 13.5, 11.6 and 8.9 ms; 50 missed operations in four of the six jobs.
    Instrumented CPU time 14.1 to 20.2 s, 19,764 to 34,311 garbage
    collections.
  - The same revision with this change, two runs: max tick lag 5.9, 3.9 and
    7.3 ms, then 7.5, 4.9 and 7.7 ms; no missed operations in any of the six
    jobs. CPU time 13.8 to 14.6 s, 12,424 to 14,654 garbage collections, as
    before the ticket lock (12.7 to 13.8 s, 13,161 to 14,489).
  - Max tick lag stays above the 3.1 to 3.8 ms measured before the ticket
    lock. Before the ticket lock the Recorder dropped 700 of the Logger
    collector's 1,150 events, almost all as `contended`. The collector now
    records all of them.
- Locally, in the instrumented phase on 2 schedulers, the Logger
  collector's reductions fell from 15.5 to 15.9 million to 8.7 million
  (three runs each).
- `bench/recorder_contention.exs` passed on the development host before and
  after the change, both runs conclusive. With 2, 4 and 8 writers, p95 went
  from 0.79, 1.01 and 1.01 times the fair share to 0.63, 0.79 and 0.80.
  Throughput went from 1.60, 1.25 and 1.22 times one writer's to 1.67, 1.51
  and 1.24.

## Consequences

- A queued writer no longer busy-waits: it runs one lock lookup per poll,
  and a liveness check every 64 polls. Each hand-off is one message and one
  wake-up.
- A holder that dies holding the lock delays the writers behind it by 64
  polls, nominally 64 ms. Writers further back already had that delay.
