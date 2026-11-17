# Collectors and detectors

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The runtime signals Insider reads, the bounded same-node diagnostic API,
supervised collector sessions, runtime polling, and the detectors built on
them.

## Contents

- [What Insider connects to](#what-insider-connects-to)
- [Supervised collector sessions](#supervised-collector-sessions)
  - [Start, check, and stop a session](#start-check-and-stop-a-session)
  - [Session ownership and stop receipts](#session-ownership-and-stop-receipts)
  - [Lifecycle admission, flush, and stop](#lifecycle-admission-flush-and-stop)
  - [Read redacted events](#read-redacted-events)
- [System-event collector](#system-event-collector)
  - [System-event collector policy](#system-event-collector-policy)
  - [System-event receiver limits](#system-event-receiver-limits)
- [Restart-recurrence detector](#restart-recurrence-detector)
- [Lab contracts and invariants](#lab-contracts-and-invariants)
  - [Application contracts (Lab)](#application-contracts-lab)
  - [Declared invariants](#declared-invariants)
- [Bounded runtime polling](#bounded-runtime-polling)
- [Mailbox-growth detection](#mailbox-growth-detection)
- [Detection goals](#detection-goals)
- [Runtime diagnostics](#runtime-diagnostics)

## What Insider connects to

The proof of concept (an early, deliberately small implementation) is designed
around public BEAM and ecosystem mechanisms:

- isolated OTP trace sessions for explicitly selected processes, descendants,
  message shapes, or MFAs
- isolated `trace:system/3` events on OTP 28+, with the node-global OTP 27
  `system_monitor` limited to disposable development and CI nodes
- structured Logger events and OTP/SASL crash and supervisor reports
- selected Telemetry and OpenTelemetry lifecycle and correlation events
- bounded process, scheduler, allocator, ETS, port, distribution, and VM
  snapshots
- application-supplied stable identities, safe observations, invariants, and
  ownership through the Lab-only `Insider.Contract` API
- Tidewave/MCP development access: Insider loads and runs through Tidewave
  `project_eval`. Adapters for observer_cli and recon are not built. Insider
  has no dependency on either. Its own bounded probes follow recon's approach
  (for example, port counts by type), and the welcome lists observer_cli only
  as a terminal UI for a human.
- later, native lifecycle, render, effect, device, and cross-platform evidence

The initial runtime targets are OTP 27–29 and Elixir 1.17–1.20, subject to the
documented compatibility pairs passing CI. Core tracing uses OTP's public
session API directly. Insider will not use legacy globally destructive tracing
as its trace owner.

## Supervised collector sessions

`Insider.Collector.Session` is the opt-in host boundary. It composes the
permitted Logger, Telemetry, Poller, OpenTelemetry, and calls collectors with
one Recorder. It does not replace the legacy standalone collectors: existing
`Poller` callers keep their current behavior. A trusted host constructs the
immutable protected-target policy and provides all startup configuration.
Decoded requests, nested collector options, and handles cannot replace the
policy, environment, authority, clocks, or fixed global handler identities.

### Start, check, and stop a session

```elixir
{:ok, host_policy} = Insider.Runtime.HostPolicy.new(host_protected_targets: [])

{:ok, session} =
  Insider.Collector.Session.start(host_policy,
    id: "development-observation",
    environment: :development,
    authority: "development-observation",
    boot_id: boot_id,
    clock_id: "session-clock",
    recorder_options: [classification: {:internal, redaction_policy}],
    components: [:logger, :telemetry, :poller],
    telemetry_policy: telemetry_policy,
    poller_options: [targets: [pid], provider: MyPollerProvider]
  )

{:ok, health} = Insider.Collector.Session.health(session)
{:ok, receipt} = Insider.Collector.Session.stop(session)
```

The session API rejects staging and production before it creates a recorder,
process, filter, handler, timer, or monitor. It permits one active session
globally, because Logger uses the fixed `:insider_logger` primary-filter ID.
The session never removes an unrelated holder of that ID. Session components
are temporary and do not restart after a crash. Health reports liveness
separately from bounded component-status evidence, so liveness does not claim
correctness.

### Session ownership and stop receipts

A dedicated `one_for_all` session root owns session state. A failure of the
session manager (internal: `Insider.Collector.Session.Manager`) or of its
DynamicSupervisor resets both and terminates active children. It does not
affect unrelated top-level application children.

A stop or kill receipt lists the cleanup of each of these items as verified
absent, unavailable, or residual:

- component
- Logger filter
- Telemetry handler
- recorder
- monitor
- timer
- policy reference
- session-manager entry

A policy is an immutable value. The session drops its reference, so it is not
a resource that is released. The session manager retains at most 32 terminal
receipts. Within that retention window, a repeated stop or kill returns the
exact receipt. After eviction it returns `:expired_or_unknown_session`. A
restart of the session manager or session root intentionally loses that
terminal knowledge. Owner death triggers the same bounded cleanup path.
`SystemMonitor` stays excluded from sessions, because it needs a separate
protected-subject ingress decision.

### Lifecycle admission, flush, and stop

Lifecycle calls use bounded trusted-host API admission and carry monotonic
deadlines. Raw same-node messages are not a public admission boundary.

A start can time out while its `DynamicSupervisor.start_child/2` call is still
queued. The session then revokes authorization before any collector side
effect. The start stays quarantined, and it keeps its single worker/ownership
slot until that exact call reports its result. If the supervisor never
responds, a host must reset the dedicated session root to release that
fail-closed slot. The session never permits a new session on inferred absence
alone.

`flush/1` is a bounded barrier for entries visible when its call is handled.
Concurrent emitters are outside that guarantee. `stop/1` conditionally detaches
only the exact owned handler and drains entries visible after detach. Callers
must quiesce emitters to claim a complete shutdown, because Telemetry may
already have selected a callback. A handler already detached upstream is
normal.

### Read redacted events

`read_events/3` returns redacted event content without a freeze trigger. It
works in three steps:

1. It drains the visible Logger and Telemetry inboxes.
2. It reads the Recorder with `Insider.Recorder.read_since/3`. That call
   returns receipts greater than a cursor, in order, bounded by count and
   bytes. It does not take the admission lock, so a read never delays a
   producer.
3. It passes each event through `Insider.Redaction` under the session's own
   trusted classification policy.

The session withholds and counts an event that fails redaction. The receipt of
that event still advances the cursor. The Recorder assigns receipts
consecutively on admission. So every receipt missing between the cursor and
`next_cursor` was evicted, and the result reports that exact count.
`"truncated_by"` names what ended a truncated read: `"limit"`, `"max_bytes"`,
or `"deadline"` (redaction ran out of time). The result also carries the
cumulative Recorder admission counters and the Logger, Telemetry, and Poller
ingress counters. A caller can use them to account for losses that never
received a receipt.

## System-event collector

The system-event collector records selected ERTS anomalies. It runs apart from
a supervised collector session.

### System-event collector policy

An explicit pure-data policy selects the ERTS anomalies to collect:

```elixir
{:ok, system_policy} =
  Insider.Collector.SystemMonitor.Policy.new(
    events: [
      long_gc: 100,
      long_message_queue: {100, 1_000},
      long_schedule: 100,
      large_heap: 1_000_000,
      busy_port: true,
      busy_dist_port: true
    ]
  )

{:ok, runtime_context} =
  Insider.Policy.Context.new(
    environment: :ci,
    actor: "trusted-ci-runtime",
    target_class: :host,
    features: %{
      "events.subscribe" => %{
        available: true,
        provider: "erts.trace.system",
        isolation: :session_local
      }
    }
  )

{:ok, system_collector} =
  Insider.Collector.SystemMonitor.start_link(handle, system_policy,
    authority: "ci-runtime-observation",
    boot_id: boot_id,
    clock_id: "system-monitor-order",
    runtime_context: runtime_context
  )
```

The event policy contains no caller-asserted environment. Startup requires a
validated `Insider.Policy.Context` that the trusted host integration supplies.
It accepts only development, test, and CI. On OTP 28-29, its exact
`events.subscribe` feature must name `erts.trace.system` with `:session_local`
isolation. OTP 27 additionally requires a disposable target,
`legacy_node_global: true`, and an exact `erlang.system_monitor` /
`:node_global` feature. The collector refuses to start when it finds an
existing legacy monitor.

### System-event receiver limits

The unregistered receiver uses an off-heap mailbox. It projects only these
values into a fixed-slot inbox: known numeric counters, entered/recovered queue
state, closed port-operation atoms, and local PID/port identities. It discards
MFA locations, unknown fields, and arbitrary terms. Monitor tuples are ordinary
same-node messages, and a process can forge them. So this is policy-bound
observation, not VM-authenticated evidence. Recorder classification and
authority come only from trusted collector configuration.

Fixed retained evidence and collision shedding do not hard-bound the transient
ERTS delivery mailbox. A burst can arrive before the receiver is scheduled. A
sampled mailbox tripwire records high water. It disables the exact owned
backend after the mailbox crosses its configured limit. It cannot retract
messages already sent. This stays development/CI evidence until production
load and threat-model gates pass.

`flush/1` uses an isolated trace-delivery marker where available, then drains
the bounded inbox. Concurrently generated signals stay outside the guarantee.
On overload, the receiver stops normal projection immediately. It counts
messages handled during the disable handshake. The collector stays alive with
cleanup evidence. OTP 27 releases ownership through receiver death, the only
atomic VM primitive available. Observation after that death is best effort. An
uncooperative direct `system_monitor/2` call can still race the initial
install. The collector then reports `legacy_install_race` and uncertain
best-effort restoration. `stop/1` reports cleanup and the same concurrency
uncertainty.

## Restart-recurrence detector

A pure reducer reduces normalized supervisor terminations without starting
another process. The supplied timestamp must come from a trusted receipt clock,
such as the `received_at` value of a recorder snapshot entry:

```elixir
{:ok, detector} = Insider.Detectors.RestartRecurrence.new()
{detector, outputs} =
  Insider.Detectors.RestartRecurrence.observe(detector, event, received_at)
```

By default, the detector emits one finding after three abnormal terminations of
distinct child incarnations under the same logical supervisor/child identity.
Expected shutdowns, temporary children, duplicate incarnations, and unrelated
crash reports stay quiet. Incomplete target evidence becomes an explicit
detector error.

## Lab contracts and invariants

These APIs belong to Lab. They let an application declare its own semantics.

### Application contracts (Lab)

Lab applications can expose stable semantic vocabulary. They do not export
callback names, and Insider does not scan loaded modules:

```elixir
defmodule MyApp.CheckoutContract do
  use Insider.Contract, id: "my_app.checkout", version: 1

  identity :checkout, from: &checkout_id/1, sensitivity: :internal
  observe :summary, with: &summary/1, sensitivity: :confidential
  invariant :total_matches_items, check: &total_matches_items?/1

  action :add_item,
    with: &add_item/2,
    environments: [:development, :test]

  owns modules: [MyApp.Checkout]
end
```

Lab `Insider.Contract.describe/1` and `list/1` return deterministic, versioned,
string-keyed metadata with a canonical fingerprint. Callback invocation accepts
only bounded inputs. It re-authorizes the original protocol request against
trusted runtime context and runs in a fixed-capacity disposable worker.
Timeouts, overload, callback failure, invalid output, invariant violation,
cleanup, and uncertainty stay distinct outcomes. Actions and resets require an
authorized `scenario.run` or `verification.run` on a disposable local target.
A contract's environment list can only narrow that authority.

### Declared invariants

Insider can evaluate Lab-declared invariants into recorder evidence. It keeps
an application failure apart from an observation failure:

```elixir
{:ok, evaluator} =
  Insider.Invariant.new(
    authority: "development-observation",
    boot_id: boot_id,
    clock_id: "monotonic-us",
    executor: contract_executor,
    recorder: recorder_handle,
    redaction_policy: collection_policy,
    source_instance_id: "checkout-invariants"
  )

outcome =
  Insider.Invariant.check(
    evaluator,
    MyApp.CheckoutContract,
    :total_matches_items,
    [checkout_snapshot],
    request: request,
    context: policy_context,
    timeout_ms: 100
  )
```

The outcome keeps verdict, execution, disclosure, and recording as independent
axes. Only one result becomes a confirmed `semantic_invariant` finding: a
completed, policy-disclosed `false` result that is sealed in a recorder
snapshot. Timeouts, exceptions, overload, unavailable infrastructure, invalid
requests, and redacted results stay machine-distinct non-incidents. When the
recorder has a post-trigger window, pass the frozen outcome to
`Insider.Invariant.resolve/2` after that window closes. Confirmation then binds
the finding to the recorder's retained trigger and receipt time.

## Bounded runtime polling

`Insider.Collector.Poller` records low-frequency VM trends and scalar samples
for at most 32 explicit local processes. Process samples contain queue length,
memory and heap/stack sizes, cumulative reductions, status, registered name,
and current MFA. They never copy mailbox contents, process dictionaries,
links, monitors, stack traces, or full private process state. By default the
collector never enumerates every process on the node. It does so only when
configured with `top_processes` or `top_ets_tables` (Live turns them on with
the poller component). It then reads only the scalars, group leader, and names
described under [Process and ETS evidence](live/live-runtime-evidence.md#process-and-ets-evidence).
`watch_names` samples the processes registered under up to 16 names, resolved
anew each cycle. Every poller event carries `wall_time`.

Each probe runs in one linked, monitored worker under per-probe and whole-cycle
sampling deadlines. Bounded events and collector counters keep these visible:
protected or exited targets, partial probes, timeouts, truncation, invalid
results, and recorder refusal. The poller schedules periodic ticks only after a
cycle completes. A timeout stops Insider from waiting. It cannot retract a
runtime inspection already delivered to the target, so timeout evidence
reports that observer-effect uncertainty. Unconfirmed cleanup quarantines the
worker and blocks later probes, so workers never overlap. The poller does not
expose manual cycles, so external calls cannot queue polling work.

## Mailbox-growth detection

`Insider.Detectors.MailboxGrowth` consumes complete scalar process samples as a
bounded pure reducer. It reports a medium-confidence finding only after one
process has a configured run of strictly increasing queue samples with an
unchanged cumulative reductions counter, sufficient queue depth and growth,
and no sampling gap. Queue recovery, reductions progress, unavailable samples,
or a truncated poll cycle reset the candidate.

The claim is intentionally narrow: no reductions were observed. It is not proof
that no work completed. Intentional buffers can be declared through a bounded
exact-subject ignore list because runtime counters cannot safely infer
application intent. The detector never inspects queued messages. Findings use
trusted recorder receipt time, keep separate state per poller stream and process
generation, and retain at most 32 samples for each of at most 4,096 keys.

Every operation must carry deadlines and resource limits, disclose observer
effects, report dropped or truncated evidence, clean up its runtime resources,
and keep the host application alive if Insider itself fails.

## Detection goals

The first detectors target structural failures with strong runtime evidence.
Two goals have a detector today. The others are goals only.

| Goal | Detector today |
|---|---|
| Normalized crash and restart recurrence in one logical subtree | Yes: [Restart-recurrence detector](#restart-recurrence-detector) |
| Sustained mailbox growth without corresponding progress | Yes: [Mailbox-growth detection](#mailbox-growth-detection) |
| Processes, tasks, timers, monitors, or resources that outlive their scenario | No |
| Replies or side effects that arrive after timeout or owner termination | No |
| Incomplete paired Telemetry lifecycles | No |
| Application-declared invariant violations | No detector. [Declared invariants](#declared-invariants) confirm a `semantic_invariant` finding. |
| Test-order and shared-state failures exposed by concurrent execution | No |

Later work may add statistical anomaly detection, schedule exploration,
distributed causality, and broader semantic adapters. Insider cannot discover
arbitrary business-logic errors without an observable failure or declared
invariant. It does not claim to find bugs in the BEAM VM itself. It can capture
the evidence needed to tell application, library, and runtime behavior apart.

## Runtime diagnostics

The root runtime surface is deliberately small. Direct Elixir calls expose a
bounded process description. They use the existing protocol, policy, and
scalar-only Erlang poller. Lab also exposes that same operation through its Mix
task and canonical JSON wire format:

```sh
(cd tools/insider_lab && mix insider capabilities)
(cd tools/insider_lab && mix insider inspect --name Elixir.MyApp.Supervisor)
```

The Lab Mix task starts the current project before it resolves the registered
name, so the diagnostic runs in the same BEAM as the application. It
deliberately does not accept textual PIDs, because a PID copied from a
different BEAM can alias an unrelated local process. The task fixes a narrow
diagnostic budget (`max_duration_ms` 1,000, `max_events` 1, `max_bytes`
65,536, `max_targets` 1). Some inputs make it print an
`insider.mix-task.error/v1` document and exit `64` instead of returning a
protocol result: a usage error, an unparseable name, or a name with no
registered process. The document has `status` `invalid_input` and an
`error.code` of `usage`, `invalid_target`, `invalid_name`, or
`process_not_found`. In IEx, callers that already hold a typed local PID can
use the root domain API directly:

```elixir
{:ok, host_policy} = Insider.Runtime.bind_host_policy(host_protected_targets: [])
Insider.Runtime.describe(pid, [environment: :development], host_policy)
```

The host policy is trusted startup configuration, never decoded from protocol
requests, adapter parameters, or target data. It may add protected application
PIDs but cannot remove the versioned OTP/Elixir runtime inventory.

Results contain process status, reductions, memory, heap sizes, queue length,
registered name, and current function. They do not contain messages, process
dictionaries, stack traces, links, monitors, or application state. The
operation is deadline- and heap-bounded, reports its observer effect and
cleanup outcome, and is unavailable in staging and production in this phase.

The root application starts no contract, scenario, or Sentinel executor.
Those Lab-only executors remain opt-in under the Lab application:

```elixir
config :insider_lab, components: [:contract, :scenario, :sentinel]
```

The Lab default is `[:contract]`. Selecting `:scenario` also starts its
contract-executor dependency. Root runtime inspection has no resident worker
and requires no component setting.
