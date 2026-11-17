# Lab: CLI transport and privacy corpus

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The Lab's `mix insider` task and escript, their canonical JSON and NDJSON
envelopes, and the privacy corpus runner.

## Contents

- [Lab CLI transport](#lab-cli-transport)
  - [Adapter and dispatcher](#adapter-and-dispatcher)
  - [Escript](#escript)
  - [Envelope and budgets](#envelope-and-budgets)
  - [Exit codes](#exit-codes)
- [Acceptance hosts](#acceptance-hosts)
  - [Fixture observation host](#fixture-observation-host)
  - [Restart capture](#restart-capture)
  - [Incident capture host](#incident-capture-host)
- [Recorder](#recorder)
  - [Recorder admission](#recorder-admission)
  - [Source shares](#source-shares)
  - [Classification binding](#classification-binding)
- [Logger and Telemetry collectors](#logger-and-telemetry-collectors)
  - [Logger collector](#logger-collector)
  - [Telemetry collector](#telemetry-collector)
  - [Telemetry omission evidence](#telemetry-omission-evidence)
- [Ingress profiles and protected targets](#ingress-profiles-and-protected-targets)
  - [Collector ingress profiles](#collector-ingress-profiles)
  - [Protected-target audit matrix](#protected-target-audit-matrix)
  - [Privacy corpus runner](#privacy-corpus-runner)

## Lab CLI transport

### Adapter and dispatcher

`Insider.Adapter.CLI` is a Lab-only transport adapter over `Insider.Protocol`.
It does not implement runtime operations. It does not trust caller-supplied
environment and capability fields as authority. An embedding host injects an
`Insider.Adapter.CLI.Dispatcher` backed by its trusted policy context. The
host must recheck an allowed policy decision immediately before runtime work
begins.

The adapter validates the exact v1 request envelope and runs dispatch in a
bounded worker. It accepts only a result correlated to that request. It fully
revalidates `Request` structs that a caller already decoded. Result
validation and JSON projection stay inside the same heap and deadline boundary
as dispatch.

### Escript

The direct in-VM API accepts an `Insider.Protocol.Request` or a string-keyed
request map. It intentionally does not parse ETF or textual Erlang terms from
untrusted input. Portable callers use canonical compact JSON or NDJSON:

```sh
(cd tools/insider_lab && mix escript.build)
./tools/insider_lab/insider-lab --discover
printf '%s' '{"schema":"insider.request/v1","protocol":"insider.protocol/v1","operation":"runtime.capabilities","request_id":"example-1"}' | ./tools/insider_lab/insider-lab --json
printf '%s\n' '{"schema":"insider.request/v1","protocol":"insider.protocol/v1","operation":"runtime.health","request_id":"example-2"}' | ./tools/insider_lab/insider-lab --ndjson
```

`--discover` reports the closed protocol operation vocabulary, transports,
bounds, and exit-status table, so callers need no prose scraping. The bounds
include parser shape, decoder worker, buffered-helper, stream, and dispatcher
ceilings.

The standalone dispatcher implements only `runtime.capabilities`. So callers
can see that every other runtime operation is unavailable until a host injects
an executor. This separates protocol membership from deployed availability.

### Envelope and budgets

JSON input and output are limited to 16 MiB. JSON nesting is limited to depth
8 and width 1,000. Every output frame is compact canonical JSON followed by
exactly one newline.

A decoded request without an explicit `budget` gets the protocol defaults.
Each budget field has a ceiling:

| Field | Default | Ceiling |
|---|---|---|
| `max_duration_ms` | 5,000 | 600,000 ms |
| `max_events` | 1,000 | 100,000 events |
| `max_bytes` | 1,048,576 | 16,777,216 bytes (floor 16,384 bytes) |
| `max_targets` | 1 | 100 targets |

The adapter processes NDJSON sequentially, with at most 1,000 frames and
16 MiB per frame. Blank, malformed, and oversized frames each produce one
error frame, and a valid stream continues.

Discovery byte limits count the canonical JSON payload. The advertised stream
maximum also includes its one-byte newline delimiters. It also includes a
fixed 1 KiB reserve for the terminal frame-limit error.

The in-memory `invoke_ndjson/2` helper also caps its combined response and raw
input at 16 MiB. It gives each response a fair share of that combined output
bound. Larger results become correlated `operation_failed` result frames. The
executable writes frames incrementally. The per-frame and frame-count ceilings
bound it instead.

### Exit codes

A cleanly framed NDJSON stream exits zero, because each line carries its own
status. A one-shot JSON invocation exits as follows:

| Exit | Meaning |
|---|---|
| `0` | `ok` |
| `1` | protocol `error` |
| `3` | `unsupported` |
| `64` | adapter/request input errors |
| `70` | unrecoverable stream I/O failure |
| `124` | `timeout` |
| `130` | `cancelled` |

## Acceptance hosts

### Fixture observation host

The Lab Phase A acceptance suite compiles a deliberately narrow host only from
Lab `test/support`. Its host-specific capabilities advertise one
`scenario.run` fixture observation. Trusted local test/disposable policy backs
it. The supervised host owns execution outside the CLI's deadline-killed
dispatcher worker. It projects actual faulty or healthy measurements into
bounded portable results and verifies eventual resource cleanup. Non-test
builds do not contain this harness. It does not change standalone CLI
availability.

### Restart capture

The Lab Phase B evidence gate adds `Insider.Incident.RestartCapture`. It is a
reusable orchestration seam for trusted, already-normalized restart events. In
one causal step, it admits each event to a bounded recorder and to the
restart-recurrence reducer. It freezes on the first finding. It assembles and
redacts one content-addressed capsule and validates its canonical bytes
offline. It confirms the recorder cleanup outcome before it returns. It
deliberately does not collect signals or authorize callers.

**Lifecycle owner.** A temporary lifecycle owner monitors the API caller and
owns the naturally linked recorder. It contains recorder failure. It runs
capture work behind correlated begin, execute, and cancel references. So
caller death, cancellation, and deadlines stay observable.

**Admission.** After start, the owner reserves each resource slot and
publishes the actual recorder PID. It waits for an acknowledgement correlated
by reference and PID before it opens the recorder or declares readiness. An
explicit phase machine makes duplicate admit, begin, and execute messages
idempotent. One inventory keeps every reserved slot and every published PID,
monitor, and terminal status.

This makes pre-readiness failure accounting explicit:

- `resource_pids` counts published PIDs.
- `resources` also includes any reserved slot that failed before a PID could
  be published.
- `unmaterialized_resource_slots` records that difference.

Its owned terminal paths wait boundedly for cleanup. An outer caller that must
kill an unresponsive owner drains correlated owner messages and reports
cleanup as uncertain.

### Incident capture host

A separate host, compiled only from `test/support`, authorizes one bounded
`incident.capture` command for the real restart-storm fixture. Before it
runs, it independently authorizes an internal `incident.export` request with a
different trusted grant and audit ID. Capsule bytes cannot cross the command
boundary without both live decisions.

Its adapter projects the fixture's measured crash generations and process IDs
into the same normalized supervisor-event contract that the detector uses. The
faulty variant yields exactly one canonical capsule byte string. The identical
healthy variant yields none. The result and capsule keep fixed budgets,
recorder loss/gap counters, projection observer effect, provenance, redaction,
and fixture/recorder cleanup.

**Idempotency.** The host caches successful outcomes behind a required
intent-bound idempotency key, in a fixed 32-entry store. So a retry returns
the same capsule without rerunning the fixture. Cache exhaustion is typed
overload, not an uncached execution. Hits already in a full cache stay
available. The host owns one monitored worker lease. It releases admission
only after that worker terminates, so overload and cancellation stay
responsive.

**Resource accounting.** Command accounting measures from authorized fixture
admission through final cleanup, against a fixed ten-resource budget. It
deduplicates published fixture and capture PIDs. It keeps any reserved,
unmaterialized capture slot. A complete faulty command owns the actual fixture
owner, supervisor, Agent, workers, capture owner, recorder, and capture worker.
The restart fixture itself has a caller-monitoring owner for its linked Agent,
supervisor, and every worker. Worker-resource notifications are opt-in for the
async test adapter. So ordinary `Fixtures.run!` callers keep a clean mailbox.

**Cancellation and deadlines.** Cancellation uses unforgeable fixture,
capture-owner, and host lease references. It returns only after bounded
cleanup observes the real resource set and both owners down. If the CLI
deadline kills its dispatcher after work starts, its immediate result reports
cleanup as uncertain. The independently owned test host still cancels by its
deadline. It emits separate causal evidence when its observed restart fixture
resources are down. The transport does not rewrite that later fact into the
already-returned timeout.

This host does not show that live Logger events are wired to capsule export.
The Logger collector's real OTP normalization stays covered by its separate
integration suite.

## Recorder

### Recorder admission

Recorder producers get a handle once during collector setup. Recording uses
direct admission and never queues behind the recorder owner. Admission is a
ticket lock. The Recorder admits writers that meet at it one at a time in
arrival order, and it does not drop them.

A writer that waits for its turn sleeps until another writer wakes it through
a process alias. The writer deactivates and drains the alias before the call
returns, so no wake stays in its mailbox. The lock passes over a holder or
waiter that died. A writer gives up with `:contended` only when the lock has
not changed hands for `admission_stall_ms`. That option is 0 to 5,000, default
1,000. With 0 the writer makes a single attempt.

Call the Recorder from collector or other Insider-owned processes, never from
an application process. A call can wait while other writers are admitted. A
collector held up this way backs up into its own bounded inbox, which sheds
with counted loss.

### Source shares

Each event source has a reserved share of the Recorder's event and byte
bounds. So one noisy source cannot evict the others' evidence.
`source_shares` maps a source to a whole percentage (at most 16 sources).
`other_share` is the percentage that every other source draws on together.
They sum to at most 100. The default reserves:

| Source | Share |
|---|---|
| `logger` | 25% |
| `telemetry` | 15% |
| `poller` | 25% |
| `otel` | 10% |
| `inspect` | 5% |
| `system_monitor` | 5% |
| other sources | 5% |

That leaves 10% unreserved. A share reserves room without holding it. A
source can use any room no one else is using.

**Eviction.** When a write needs room, a source over its share evicts its own
oldest entries first. A source within its share takes the oldest entries of
sources over theirs. A normal write never evicts a source's entries while that
source is within its share in both events and bytes. Protected entries keep
their precedence. Normal writes never evict them. A protected write can evict
any normal entry and then protected ones, but never the freeze trigger. It
takes its own source's and over-share sources' entries first.

**Reporting.** `Insider.Recorder.fill/1` and `status/1` report each share
group's `share_percent`, `reserved_events`, `reserved_bytes`,
`retained_events`, `retained_bytes`, and `evicted` under `sources`. `fill/1`
also reports `memory_bytes`: the Recorder's tables and the event binaries they
hold. The cumulative `evicted` counter is the sum of the per-source ones.

Both counters are conservative. The Recorder counts an eviction before it
deletes the entry. So a writer killed in between leaves an entry that is
counted as evicted but still kept (and counted again if it is evicted later).
The counters never undercount. The receipt-range `evicted` of `read_since/3`
stays exact.

### Classification binding

Every recorder requires one trusted sensitivity and redaction-policy binding.
Event fields cannot select or downgrade it:

```elixir
{:ok, redaction_policy} =
  Insider.Redaction.Policy.new(
    id: "runtime-evidence",
    maximum_sensitivity: :internal,
    rules: []
  )

{:ok, recorder} =
  Insider.Recorder.start_link(
    classification: {:internal, redaction_policy},
    max_events: 1_000,
    max_bytes: 4_000_000,
    post_trigger_ms: 0
  )
{:ok, handle} = Insider.Recorder.handle(recorder)
:ok = Insider.Recorder.record(handle, event)
{:ok, freeze_id} = Insider.Recorder.freeze(handle, trigger_event)
{:ok, snapshot} = Insider.Recorder.snapshot(handle)
```

`record/2` returns `{:dropped, reason}` under classification failure,
contention past the admission bounds (`:contended`), pressure, rate limits,
invalid input, closure, or recorder loss. Snapshots keep these gaps and the
policy-bound classification companion. They keep separate Event and
classification byte accounting and do not imply complete replay. Capsule
assembly verifies and consumes that companion, then omits it from the
portable artifact.

## Logger and Telemetry collectors

### Logger collector

A supervised Logger collector attaches structured OTP reports:

```elixir
{:ok, collector} =
  Insider.Collector.Logger.start_link(handle,
    authority: "development-observation",
    boot_id: boot_id,
    clock_id: "logger-order",
    environment: :development
  )
```

The collector installs a first-position primary filter. So it sees crash and
supervisor reports before Elixir translates them to text. Logger callers do
only bounded structural shaping and one fixed-slot ETS insertion. A separate
process drains into the recorder. Full inboxes shed and increment fixed health
counters. Events that Logger's primary level excludes never reach the filter.
They stay an explicit visibility boundary.

`Insider.Collector.Logger.flush/1` drains at most the configured inbox
capacity. It returns status only after those Recorder admissions complete. It
is a freeze barrier for producers that already finished. Concurrent Logger
emitters can insert after its scan. Quiesce them when you need a complete
boundary.

### Telemetry collector

Selected Telemetry events use an explicit pure-data allowlist:

```elixir
{:ok, telemetry_policy} =
  Insider.Collector.Telemetry.Policy.new(
    id: "checkout-telemetry",
    events: [
      [name: [:my_app, :checkout, :start], kind: "checkout.start",
       lifecycle: "checkout", phase: :start],
      [name: [:my_app, :checkout, :stop], kind: "checkout.stop",
       lifecycle: "checkout", phase: :stop]
    ],
    metadata: [component: "component"],
    measurements: [duration: "duration"],
    correlation: [logical_operation_id: :request_id, trace_id: :trace_id,
                  span_id: :span_id]
  )

{:ok, telemetry_collector} =
  Insider.Collector.Telemetry.start_link(handle, telemetry_policy,
    authority: "development-observation",
    boot_id: boot_id,
    clock_id: "telemetry-order",
    environment: :development
  )
```

Only configured scalar fields enter the bounded handoff. Arbitrary metadata,
measurements, span-context terms, exception reasons, and handler
configuration do not. The Recorder applies its own classification at
admission. Trace and span IDs accept only exact nonzero OpenTelemetry-width
binary or lowercase-hex representations.

Lifecycle health tells apart open, expired, capacity-shed,
missing-correlation, duplicate-start, and unmatched-terminal observations. So
every start, stop, or exception rule requires a configured
`logical_operation_id` source. Source instance IDs are limited to 114 bytes,
so the generated Event ID stays valid through Event v1's maximum sequence.

### Telemetry omission evidence

When the collector leaves something out of a recorded Telemetry event, the
event carries the collection-time omission evidence in its `"omitted"`
attribute: `%{"policy_id", "measurements", "measurement_names", "metadata"}`.
It holds the exact numbers of withheld measurements (unallowlisted or
malformed) and metadata keys. It also holds the withheld measurements that the
collector may name.

The collector names a measurement only when its `nameable_measurements` option
lists it. That option holds up to 16 distinct atoms that the host approved.
The collector keeps no other key name or value. The status counters add at
most 256 per event.

The evidence never costs the event. If the names would push the attributes
past Event v1's bound, the collector records the event with the counts alone.
If even those do not fit, it records the event without the evidence. When the
Recorder admits an event that way, the collector counts it in its
`omissions_unrecorded` status. Live reports that as the
`telemetry_omissions_unrecorded` gap. An event that the Recorder rejects is a
Recorder loss.

The event's own `redactions` stays empty. That field is the export manifest,
and the incident capsule boundary requires it to be empty on recorded events.
The event's severity is `error` for an exception phase or a failure shape
([Event severity](live/live-digest-filters-and-trends.md#event-severity)),
otherwise `info`.

## Ingress profiles and protected targets

### Collector ingress profiles

Collector ingress profiles are required, host-selected startup
configuration. Development, test, and CI can attach collectors. Staging and
production are explicitly denied.

The denied profiles mechanically keep only fixed structural Logger evidence.
They suppress payload, subject, wall time, domain, causality, and
message/metadata-derived semantic identifiers and fingerprints. Telemetry
requires its exact policy allowlists before any handler-side handoff.
Suppressed Logger payload/semantic events and unallowlisted Telemetry
measurement/metadata fields have bounded status counters. These counters keep
no names or values.

Targeted process observation uses a host-owned protected-target policy. It
denies fixed OTP registrations, Insider's bound collector/recorder session, and
additive host declarations before a provider runs. `SystemMonitor` stays
development/CI-only until a separate protected-subject ingress decision.

### Protected-target audit matrix

`Insider.Policy.ProtectedTargets.audit_matrix/1` derives a read-only
`insider.protected-target-audit-matrix/v1` map from the fixed inventory. For
each supported OTP major, it lists every registration name and control-target
class. Each entry has the denial decision and reason that `classify/2`
produces. The map also holds the inventory version and a fingerprint.

It resolves no names and contains no PIDs or timestamps. So the same options
give identical bytes on every toolchain.
`test/protected_target_audit_matrix_test.exs` pins the committed
[`docs/protected-target-audit-matrix.json`](https://github.com/hiivemarkets/insider/blob/main/docs/protected-target-audit-matrix.json)
byte-for-byte. Regenerate it after an inventory change:

```sh
mix run --no-start -e '{:ok, matrix} = Insider.Policy.ProtectedTargets.audit_matrix(); File.write!("docs/protected-target-audit-matrix.json", Insider.Event.Canonical.encode(matrix) <> "\n")'
```

The matrix describes policy data, not host registration state. A name that is
absent on a runtime is not protected there. Application targets stay
undeclared. The matrix adds no exception mechanism or review owner.

### Privacy corpus runner

The dossier requires a human to run an application-specific privacy corpus
through the exact Logger and Telemetry ingress allowlists and to review every
kept field. Lab ships the content-free mechanism for that gap. The corpus
content and the field review stay human work.

`Insider.Lab.PrivacyCorpus` takes two inputs. The first is a caller-supplied
`insider.privacy-corpus/v1` map: synthetic Logger and Telemetry items as
plain maps, plus a declared canary-token set. The second is an
`IngressProfile` environment. It hands every item to the real
`Insider.Collector.Logger.Handler` and `Insider.Collector.Telemetry.Handler`
code paths. It uses the profile-derived Logger settings and the caller's exact
Telemetry policy. It returns a canonical `insider.privacy-corpus-report/v1`:

```sh
(cd tools/insider_lab && mix insider.privacy_corpus \
  --corpus priv/privacy_corpus/example.json --environment production)
```

**Report.** The report lists per-item retained field paths and bounded
suppression counts. It lists the sorted union of retained paths, and
`canary_hits` as `{index, field}` coordinates. Beyond those paths and counts it
emits only:

- each item's source, disposition, and classified event `kind` (a bounded
  name the handler derives from the item, such as
  `supervisor_child_terminated`)
- the caller's Telemetry policy `id` and fingerprint
- the environment, Logger settings, and profile and corpus fingerprints
- bounds, and fixed control and limitation names

The runner never emits the values of retained fields.

**Mix task.** The Mix task accepts only `--environment production` or
`staging`. The function API accepts any `IngressProfile` environment. The task
reads a corpus file of at most 16 MiB. It exits `0` when no declared canary
token appears in projected output and `2` when one does. It exits `64` on
invalid input (an `insider.privacy-corpus-error/v1` document) and `70` on
failure.

**Bounds.** A corpus holds at most 4,096 items, 65,536 external bytes per
item, and 32 canary tokens of at most 128 bytes. Unknown item shapes,
undeclared keys, and tokens that occur nowhere in the items fail closed.

An embedded JSON `telemetry_policy` resolves event-name segments and
projection sources only to atoms that already exist after Lab loads Insider's
own modules. So supply an application's own policy as a
`%Insider.Collector.Telemetry.Policy{}` through the function API, from a VM
where that application is loaded.

The runner does not substring-match hashed, truncated, and charlist-encoded
derivatives. Recorder classification and lifecycle health are outside the
runner. A report with no hits is bounded evidence about the supplied items
only. It is not application coverage or approval.
