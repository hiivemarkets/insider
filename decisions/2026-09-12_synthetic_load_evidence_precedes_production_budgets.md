# Synthetic load evidence precedes production budgets

## Decision

Add a separate, non-published `tools/insider_load` project that compares an
uninstrumented synthetic host workload with the same fixed-seed workload while
an `Insider.Collector.Session` is active. The harness emits canonical,
revision-bound load and soak reports plus a content manifest. Generated runs
are retained as CI artifacts rather than committed to the repository.

The collector session exposes a bounded flush-and-evidence operation for this
purpose. Its result contains only fixed-schema scalar counters and state. It
does not expose event bodies, Logger payloads, Telemetry values, recorder
handles, process identifiers, or arbitrary component state.

The harness enforces structural evidence gates: the host workload completes
without errors or missed operations, component ingress and recorder accounting
balance, pressure increases during the exact declared overload interval, required
runtime measurements are available, queues empty after emitters stop, the owned
poller is quiesced, resources are cleaned up, and a fresh session can start and
stop. It records
latency, throughput, CPU, scheduler, memory, garbage-collection, resource-count,
loss, recovery, and leak-slope measurements without assigning universal pass
thresholds to those measurements.

Pull requests run the bounded load profile on every supported Elixir/OTP pair.
Longer soak evidence is scheduled or manually requested. Both profiles use
only synthetic development/CI workloads and exclude `SystemMonitor`.

## Why

The existing component benchmarks show that bounded collectors can process
events, shed overload, and clean up on one development machine. They do not
bind all evidence to a repository revision, compare host behavior before and
after collection, exercise the complete host-owned session, measure tail
latency or leak slope, or retain comparable evidence across supported runtime
versions.

A synthetic harness can close those measurement gaps without pretending to
know the adopting service's topology, traffic, or acceptable overhead. Those
service-specific inputs are required before a human can evaluate production
budgets.

## Consequences

- Every report fixes `production_capacity` to `false` and
  `budget_evaluation` to `not_approved`.
- A clean synthetic report is evidence about its exact revision, runtime,
  profile, seed, and CI host only. It is not production approval.
- Staging and production observation remain denied. The harness adds no
  network, vendor, credential, source, mutation, deployment, or Git authority.
- OTP 27 node-global system monitoring remains outside the first production
  profile and outside this harness.
- Target service, topology, observed rates, approved overhead and recovery
  budgets, retention, protected application targets, canary design, and named
  approvers remain explicit human decisions.
