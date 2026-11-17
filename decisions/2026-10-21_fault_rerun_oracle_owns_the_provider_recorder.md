# Fault-and-rerun oracle is a probe library that owns the provider recorder

## Context

Retry probes kept being written by hand in the same shape: stub the provider
client with Mimic so each create returns a fresh id and reports itself, make
one provider call fail on the first attempt, run the worker's `perform_job`
twice, and compare the creates with the ids the database kept. For example,
`MyApp.Payments.PaymentWorker` calls a payment provider and stores the
provider's id on a `MyApp.Accounts.Account` row. Each hand-built copy chose
its own control and printed raw provider ids and job results, and one run
was lost because the stub covered `put/4` while the code called `put/3`
through a default argument.

The worker, its fixtures, the provider client, the simulated responses, and
where the database keeps a provider id are host knowledge that exists only in
the host's own test VM. Insider must not hold host-specific code.

## Decision

Lab ships `tools/insider_lab/priv/probes/fault_rerun.exs`, a self-contained
source file defining `InsiderLab.FaultRerunOracle`. An agent-written ExUnit
probe loads it with `Code.require_file/1` and calls `run/1` with a
declaration. It is not a `mix insider.oracle` kind, for the same reasons as
the actor differential
(`2026-10-21_actor_differential_oracle_is_a_probe_library.md`).

- **Host adapters are caller-supplied functions.** The declaration names the
  operation, a `fixture` function, the worker invocation `perform` (given the
  fixture and optionally the attempt number), an optional `succeeded?` check
  (default `:ok` or `{:ok, _}`), a `stub` installer (`&Mimic.stub/3` on a
  Mimic host), the provider `boundaries`, the `fault`, and a `references`
  projection that returns the provider ids committed rows for one fixture
  hold, grouped by the referenced effect boundary that creates them. Effect
  identities and references are both fingerprinted with their boundary name,
  so equal ids from two providers never match each other; a projection that
  is not such a map (at most 1,024 ids) is `references_failed`. Each
  boundary names a `{module, function}`, a `respond` function
  that simulates the provider from the call's arguments and a per-boundary
  sequence number, and optionally an `effect` identity extractor with the
  exact number of distinct effects the healthy control `expect`s,
  `referenced: false` for effects the host never stores, and an idempotency
  `key` extractor.
- **The engine owns the recorder and covers every arity.** It reads the
  function's exported arities and installs one recorder per arity through
  the `stub` adapter, so a call through a default-argument arity cannot
  escape. A declared `arities` list must name exactly the exported arities
  (`arity_not_covered`, `arity_not_exported`); a missing function, an arity
  above 12, or any other malformed field is an `infrastructure_failure` with
  a closed `reason`, and no adapter runs. Recording uses a public ETS table
  owned by the calling process, so calls from tasks the worker starts are
  recorded; the table is deleted when `run/1` returns, and a later call to a
  stubbed function raises.
- **The fault is declared at one provider call.** `fault` names a boundary,
  the call position within the attempt (default 1), how many leading attempts
  are faulted (default 1, fewer than `attempts`, default 2, at most 8), and a
  result: `{:return, term}` or `{:raise, exception}`. With
  `lost_response: true` the provider still performs the call and records its
  effect, but the caller receives the fault.
- **Idempotency keys replay, or the run is not comparable.** A boundary with
  `key` replays the first response for a repeated non-nil key within one
  scenario, as a provider that honours idempotency keys does. The first
  caller claims the key in the table and responds without holding any lock;
  a concurrent caller polls the table up to 2 s for that response, so two
  callers cannot both create, and no message is sent to a host process. At
  most 512 claims are admitted per scenario, charged before they enter the
  table, so a caller killed mid-response cannot grow it. A response is
  cached only within the fingerprint budget and 8 MiB per scenario, so a
  response that shares subterms is never copied in full. A key that cannot
  be fingerprinted, a claim past the limit, a repeat of a key whose response
  could not be cached, a responder that calls its own key again (directly or
  from a child task), a dead claimant, or a wait that times out is
  `key_not_comparable`: it makes the control unhealthy, and the fault run
  `not_observed` ahead of any confirmed reason, because a missed replay could
  have manufactured the repeat.
- **A healthy control gates every verdict.** The worker first runs once
  against its own fixture with no fault. It must succeed, reach the fault
  position, make exactly `expect` distinct effects at each effect boundary,
  have every referenced-boundary effect referenced, and leave every value
  comparable. Otherwise the call is `infrastructure_failure`
  (`control_unhealthy`, with the control's reason) and no fault run is
  attempted.
- **Verdicts in the shared vocabulary.** The fault run builds a fresh fixture
  and runs up to `attempts` attempts, stopping at the first success. An
  effect at a referenced boundary that no committed reference matches is
  `orphaned_effect`; more distinct effects than expected is
  `repeated_effect`; a converged run with fewer committed effects than
  expected is `missing_effect`. Any of them is `confirmed`. An adapter
  failure, a faulted attempt that never reached its fault, a key that could
  not be replayed, a declared effect made outside an attempt
  (`effect_outside_attempt`), a truncated record, an unfingerprintable
  identity, or a retry that never succeeds is `not_observed`; otherwise
  `not_reproduced` (`converged_once`). A key that could not be replayed and
  an effect outside an attempt outrank any confirmed reason, since either
  can change the counts; in the control either is unhealthy. It never
  reports `contract_disproved`. Completeness is `complete`, `truncated` (a
  record or listing bound was hit; orphans and repeats are lower bounds and
  still confirm), or `infrastructure_failure`.
- **Value-free, bounded report.** `insider.fault-rerun-oracle/v1` holds the
  boundaries with their function names and arities, the fault shape and
  exception module, and per scenario the attempts with result tags (the
  leading atom of the return) and exception modules, call counts per
  boundary and arity, at most 64 listed effects, and per-boundary counts.
  Effect identities, idempotency keys, and references are compared by
  HMAC-SHA-256 under a per-call random key, within the actor differential's
  65,536-term and 1 MiB fingerprint budget, and shown only as per-call
  labels (`e1`, `k1`). At most 512 calls are recorded per scenario and 1,024
  references read. No argument, response, identity, key, or reference value
  is printed.
- **One line per call.** `run/1` prints one `INSIDER_FAULT_RERUN_ORACLE=`
  line, starting on a fresh line, and returns the same report.

## Why

Owning the recorder, rather than accepting caller-written stubs, is what
makes the counts trustworthy: arity coverage, fault placement, and effect
recording are the parts the hand-built probes got wrong. The stub installer
stays an adapter so the engine needs no Mimic dependency and works with any
host mechanism that replaces a function per process.

Comparing against a healthy control, rather than against a declared count
alone, catches a projection that misses where the host stores an id. If
`PaymentWorker` made a second provider call whose id it never stored on the
`Account` row, the control would fail `control_orphaned_effect` before any
fault run, where a hand-built probe that only counted creates would not
notice. The control also refuses a fault position the worker never reaches.

The retry is a direct second call of the worker's entry point. Modelling
the job queue (backoff, uniqueness, `max_attempts`, discard) would need
host-specific code and is not needed to show that an attempt's effects
outlive it.

## Consequences

- An agent writes the fixture, the simulated responses, and the reference
  projection once per worker. The oracle supplies arity coverage, fault
  placement, ordering, controls, counting, verdicts, and the value-free
  report. During development, the oracle was validated against a real
  application by reproducing hand-built retry probes with the same verdicts.
- Only declared boundaries are recorded. A provider the agent does not
  declare, or stubs outside the oracle, is invisible to it, and a
  `not_reproduced` covers only the declared boundaries and fault.
- Simulated responses are the caller's: an orphan is real only if the real
  provider creates the object on the call that was simulated as succeeding.
  Lost-response faults and key replay model common provider behaviour, not a
  verified one.
- Attempts run in the calling test process, so the ExUnit test timeout bounds
  the call. Stubs installed through the adapter stay installed until the test
  ends. Both fixtures share the test's database sandbox, so the reference
  projection must be scoped to its fixture.
- The oracle sees only what happens while `run/1` runs. `perform` must run
  the jobs the worker enqueues and join the processes it starts. A declared
  effect after `perform` returns (from left-over work, the fixture, or the
  projection) is charged to that scenario and withholds a verdict, but work
  still running when `run/1` returns, or a left-over process that writes the
  database without calling a declared boundary, is invisible.
- `insider.fault-rerun-oracle/v1` is a versioned contract. A field change
  needs a new schema version. A runner kind that saves these reports remains
  a later decision.
