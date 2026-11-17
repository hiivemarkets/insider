# Insider Live: processes, calls and Telemetry

[Index](../README.md) · [Glossary](../glossary.md) · [Cheat sheet](../cheat-sheet.md)

Evidence about the node itself: process and ETS rankings, one-shot inspections, call traces, writes to watched in-memory
values, and Telemetry event discovery.

In the commands below, `N` holds the target flags (see [Observer
node](live-api-and-transports.md#observer-node-erlang-distribution)). Each observer flag is the option key with dashes,
such as `--top-processes` for `"top_processes"`.

## Contents

- [Process and ETS evidence](#process-and-ets-evidence)
  - [Start the poller](#start-the-poller)
  - [Poller event kinds](#poller-event-kinds)
  - [How a scan ranks processes](#how-a-scan-ranks-processes)
  - [Scan deadlines](#scan-deadlines)
  - [Insider footprint](#insider-footprint)
- [One-shot inspections](#one-shot-inspections)
  - [Run an inspection](#run-an-inspection)
  - [Inspection bounds and session records](#inspection-bounds-and-session-records)
  - [Inspection options and results](#inspection-options-and-results)
  - [Mailbox shapes](#mailbox-shapes)
  - [Native and recon implementations](#native-and-recon-implementations)
- [Call traces](#call-traces)
  - [Start a call trace](#start-a-call-trace)
  - [Call event kinds](#call-event-kinds)
  - [Call pairing and recorded values](#call-pairing-and-recorded-values)
  - [Trace limits](#trace-limits)
  - [Ingress byte bound](#ingress-byte-bound)
  - [Trace session and cleanup](#trace-session-and-cleanup)
- [Changes of in-memory values](#changes-of-in-memory-values)
  - [Watch the writes of a store](#watch-the-writes-of-a-store)
  - [Read the changes](#read-the-changes)
  - [Value changes in the digest](#value-changes-in-the-digest)
- [Telemetry discovery](#telemetry-discovery)
  - [Run discovery](#run-discovery)
  - [Static scan](#static-scan)
  - [Discovery bounds](#discovery-bounds)
  - [Prefix subscription](#prefix-subscription)
  - [Silent events](#silent-events)

## Process and ETS evidence

The `"poller"` component samples the node on a timer. Each poller interval records the events below, in the order of the
table.

### Start the poller

```bash
mix insider.live start "${N[@]}" --component poller --poller-interval-ms 5000 --top-processes 10 --top-ets-tables 10 --top-ports 10 --watch-process MyApp.Worker
```

| Flag | Option | Default and bounds |
|---|---|---|
| `--poller-interval-ms` | `"poller_interval_ms"` | 5,000 ms, 1,000 to 60,000 |
| `--top-processes` | `"top_processes"` | 5 entries per process ranking, 0 scans no processes |
| `--top-ets-tables` | `"top_ets_tables"` | 5 entries per ETS ranking, 0 scans no tables |
| `--top-ports` | `"top_ports"` | 5 entries per port ranking, 0 counts no ports |
| `--watch-process` | `"watch_processes"` | a registered name, repeatable |

### Poller event kinds

| Kind | `event.attributes.metrics` |
|---|---|
| `process_top` | Three rankings of the top `"top_processes"` entries. See the list below. |
| `ets_top` | Two rankings of the top `"top_ets_tables"` tables. See the list below. |
| `port_top` | A port census after `recon:port_types/0`. See the list below. |
| `vm_sample` | The VM totals, plus `insider_process_count`, `insider_processes_bytes`, `insider_ets_tables`, and `insider_ets_bytes` from this interval's scans. |
| `process_watch` | One event per `"watch_processes"` name. See the list below. |

**`process_top`.** It holds `by_message_queue_len` (only processes with waiting messages), `by_memory`, and
`by_reductions_delta` (only processes that did work). Each entry has these fields:

- `pid`.
- `name`: the registered name, in `MyApp.Worker` form.
- `initial_call`: `$initial_call`, else the spawn call, in `MyApp.Worker.init/1` form.
- `current_function`, `message_queue_len`, `memory_bytes`, and `reductions_delta`.

The event also holds `process_count`, `scanned`, `skipped_protected`, `window_ms`, `omitted`, and `insider`.

**`ets_top`.** It holds `by_memory` and `by_size` (only non-empty tables). Each entry has `table` (its name), `owner`
(the owner's registered name or initial call), `owner_pid`, `memory_bytes`, and `size` (objects). The event also holds
`table_count`, `omitted`, and `insider`.

**`port_top`.** It holds two rankings:

- `by_type`: the top `"top_ports"` port types by count. Each entry has `type`, `count`, `os_process_count` (ports with
  an OS pid), and `delta`. `delta` is the change since the previous census, `nil` on the first.
- `by_owner`: the processes that hold the most ports. Each entry has `owner`, `owner_pid`, `count`, and `top_type`.

A port's `type` is its program name without a directory, such as `cat` for `/bin/cat`, or `tcp_inet`. Insider splits the
name at its first whitespace or control character. The type is `other` when that program names a credential. The type is
also `other` when the program holds a backslash, a control character, `$`, or a backtick.

The event also holds `port_count`, `port_count_delta` and `window_ms` (the growth over the poll interval),
`os_process_count`, `type_count`, `scanned`, `omitted`, and `insider`. `insider` counts the ports that Insider's
processes own, and Insider never ranks them. Insider reads only each port's name, connected process, and OS pid. It
never records the arguments of a spawn command. Insider reads at most 50,000 ports (`unavailable` `scan_limit`) and
keeps 512 types. The other types count as `other`.

**`process_watch`.** It holds the process sample fields (`message_queue_len`, `memory_bytes`, `reductions_total`,
`current_function`, `status`, ...). It also holds `reductions_delta` since the previous sample of the same pid. That
value is `nil` on the first sample and after a restart. `event.subject.value` is the pid, and `attributes.watch_name` is
the name. A name with no process gets `probe_status` `not_registered`.

### How a scan ranks processes

The rankings follow `recon`. For `message_queue_len` and `memory`, `process_top` is `recon:proc_count/2`.
`by_reductions_delta` is `recon:proc_window(reductions, N, Ms)`. Its window is the poll interval (`window_ms`,
measured), not a sleep. As in `recon`, a process born during the window counts all of its reductions from zero. A
process that exited before the scan is not ranked. Insider does not depend on `recon`. The first scan has no window. So
its `by_reductions_delta` is empty, and `unavailable` lists `reductions_delta`.

A scan reads four scalar items of each process with `process_info/2`: `group_leader`, `message_queue_len`, `memory`, and
`reductions`. For the ranked processes only, it then reads `registered_name`, `current_function`, `initial_call`, and
the one dictionary key `$initial_call`. It never reads a message, another dictionary key, or an ETS object.

The protected-target policy covers the fixed OTP inventory and host declarations. The scan counts those processes in
`skipped_protected` and never reads them. It still ranks their tables, with names from the inventory. A scan reads at
most 50,000 processes. Beyond that, `unavailable` lists `scan_limit`. The Poller keeps one reductions count per process
between scans.

Each event has a 4 KiB attribute bound. The scan drops entries that would push the event past it from the end of the
longest ranking. It counts them in `omitted`, and `unavailable` lists `event_bytes`.

### Scan deadlines

Each `process_info/2` answer comes from its target process. On a busy node, a scan waits for every busy process to be
scheduled, and it can take seconds. So a scan stops issuing scan requests at 5/8 of its probe timeout. Then
`unavailable` lists `scan_deadline`, and `scanned` is below `process_count`. It stops issuing naming requests at 7/8 of
the timeout. Then unnamed entries keep their counters, and `unavailable` lists `process_names`. So the scan usually
records the rankings it reached instead of timing out.

This is best effort. The scan checks the deadlines between requests, so one outstanding request can still outlast the
probe timeout. That probe then times out with no rankings. An unfinished scan's Insider totals are incomplete. The next
scan gives no reductions delta (`nil`, `unavailable` `reductions_delta`) for a process that the unfinished scan did not
reach. It does not take that process for a new process.

### Insider footprint

Insider's own processes are its control plane and every process whose group leader is the `:insider` application master.
Insider never ranks them or the tables they own. It sums them under `metrics.insider` and copies them into the
interval's `vm_sample`. So `ets_bytes` and `insider_ets_bytes` sit side by side. The Recorder's buffer grows with every
session, and that growth is not an application leak.

A host declaration wins over Insider's own exemption. Insider never reads a process that the host protects, even when it
is Insider's. Insider copies the process totals only when they are complete (`metrics.insider.complete`). They are
incomplete (`unavailable` `insider_footprint`) in these cases:

- The scan limit cut the scan.
- The host protects an Insider control-plane process.
- The scan skipped a live host-declared process while Insider's application runs. Insider cannot learn whether that
  process belongs to Insider without reading it.

The `vm_sample` is then `partial`, with `insider_processes` unavailable, instead of a lower bound. Entries dropped for
the event bound leave the totals complete.

## One-shot inspections

`process/1`, `bin_leak/1`, `ports/1`, and `alloc/1` answer one question about the node now. They follow `recon`'s
functions of the same names. The Poller answers how the node changes over time.

### Run an inspection

```bash
mix insider.live process "${N[@]}" --name MyApp.Worker
mix insider.live process "${N[@]}" --pid '<0.200.0>' --frames 20 --messages 20
mix insider.live bin_leak "${N[@]}" --top 5
mix insider.live bin_leak "${N[@]}" --human
mix insider.live ports "${N[@]}" --type cat
mix insider.live ports "${N[@]}" --owner MyApp.Worker --top 50
mix insider.live alloc "${N[@]}" --load
```

### Inspection bounds and session records

Each inspection runs once in a worker under a 3 s deadline and a heap guard. At most two run at once. A third gets
`busy`. The exported result is at most 64 KiB of canonical JSON. That size includes its credential masks, metadata, and
session status. Insider cuts the result's lists, longest first, and counts them in `omitted`. It bounds free-form
strings where it reads them: source paths keep their last 256 bytes, port names their first 256, and shapes 160.
`bounds.inspect` in `capabilities/0` carries the bounds.

Every result carries these fields: `node`, `at`, `implementation` (`native`, or `recon` for `alloc`),
`disclosure_profile`, `redactions` (credential masks), `omitted`, and `session`.

When a session runs, Insider records the result's compact projection in it. The event kind is `inspect.process`,
`inspect.bin_leak`, `inspect.ports`, or `inspect.alloc`. It has source `inspect`, severity info, and at most 4 KiB.
Insider cuts its longest lists first and counts them in `omitted`. So inspections join the session's history, views
(`--view-source inspect`), and digest. An event holds no value that a stricter profile would withhold. Shapes carry no
values, and Insider never records port names. So a host that narrows to strict later exports the same history.

`session` is `nil` without a session. Otherwise it holds `session_id`, `recorded`, and `reason`. `reason` is
`session_ended`, `sealed`, or the Recorder's drop reason. A record carries a deadline. The session refuses a record that
arrives after it, before it calls the Recorder. A record that the session already handed to the Recorder can still
complete after the deadline, because it can wait for the Recorder's admission lock. So when the inspection stops waiting
for the session's answer, `recorded` is `nil` with `reason` `outcome_unknown`. The event may or may not be in the
history. `recorded` is `false` only when the session answered that it wrote nothing.

No inspection reads a protected process (`protected_process`). No inspection runs application code.

### Inspection options and results

| Operation | Options | Result schema |
|---|---|---|
| `process/1` | `"name"` (a registered name such as `"MyApp.Worker"`) or `"pid"` (a local pid such as `"<0.200.0>"`), `"frames"` (1 to 32, default 10), `"messages"` (0 to 50, default 10) | `insider.live-process/v1` |
| `bin_leak/1` | `"top"` (1 to 50, default 10), `"human"` | `insider.live-bin-leak/v1` |
| `ports/1` | `"type"` (a port type such as `"cat"`), `"owner"` (a registered name or pid), `"top"` (1 to 200, default 20, bounds `ports`, `types`, and `owners`) | `insider.live-ports/v1` |
| `alloc/1` | `"top"` (1 to 32, default 8) | `insider.live-alloc/v1` |

**`process/1` result.** It holds these fields:

- `pid`, `name`, and `insider`.
- `info`: `status`, `initial_call`, `current_function`, `message_queue_len`, `memory_bytes`, heap and stack sizes,
  `reductions`, `trap_exit`, `priority`, `links` by `processes` and `ports`, `monitors`, `monitored_by`, and
  `minor_gcs`.
- `stacktrace`: `frames` with `function`, `file`, and `line`, innermost first, and `depth`.
- `binaries`: `count` and `bytes` of the reference-counted binaries that the process holds.
- `mailbox`: see [Mailbox shapes](#mailbox-shapes).

**`bin_leak/1` result.** It holds these fields:

- `biggest_holder`: the process that still references the most binary bytes after the collection. It is the first
  `by_retained_bytes` entry, or `nil` when no process holds any. It sorts first among the result's fields, so the head
  of the document names it.
- `by_retained_bytes`: what each process still references after a garbage collection. A leak keeps these bytes.
- `by_freed_bytes`: what the collection released.
- Each entry has `pid`, `name`, `initial_call`, `current_function`, `binary_count_before`, `binary_bytes_before`,
  `binary_count_after`, `binary_bytes_after`, and `freed_bytes`.
- `scanned`, `skipped_protected`, `collected`, `gc_pending`, `vm_binary_bytes_before` and `_after`, `insider`,
  `truncated_by`, and `elapsed_ms`.

With `"human"`, the result adds `text`, at most 8 KiB. It lists the holders first and then what the collection freed.
Then it says whether the evidence is complete. It names a scan cut by its limit, collections that did not finish, and
protected processes that Insider did not read. It claims no absence. It counts the lines that do not fit. The observer's
`--human` prints it.

**`ports/1` result.** It holds these fields:

- `types`: counts by type, with `os_process_count`.
- `matched` and `matched_os_process_count` for the filter.
- `owners`: the processes that hold most of the matched ports.
- `ports`: each with `port`, `type`, `owner`, `owner_pid`, `os_pid`, `input_bytes`, `output_bytes`, and `queue_bytes`.
  In the rich profile only, each also has `name`.
- `port_count`, `scanned`, `os_process_count`, `insider`, and `truncated_by` (`scan_limit` past 50,000 ports). Every
  count comes from that one bounded read.

`name` is the full port name, a spawn command line, at most 256 bytes. Insider cannot parse a command line with
confidence, so its masking is structural. It splits the command once at its first whitespace or control character.
Everything after the program becomes `[REDACTED:credential_key]` in two cases. The first is a command that names a
credential anywhere, with quotes ignored. The second is a command that holds anything a shell can rewrite: a backslash,
any control character, `$`, or a backtick. Insider masks the whole command when the program itself names a credential or
holds such a character.

**`alloc/1` result.** Insider reads it through `recon_alloc`. It holds `allocated_bytes`, `used_bytes`, `usage_percent`,
`allocated_types` (bytes per allocator type), and `fragmentation`. `fragmentation` lists the instances with the largest
multiblock carriers. Each has `allocator`, `instance`, `sbcs_usage_percent`, `mbcs_usage_percent`, and block and carrier
bytes. Without recon, `alloc/1` returns `component_unavailable` with `component` `recon`.

### Mailbox shapes

`process` reads only `process_info/2` items. It never reads a message value, a dictionary key other than
`$initial_call`, or `sys:get_state/1`. Its `mailbox` has `length` and `read`. When Insider read the queue, it also has
these fields:

- `shapes`: the queued messages counted by shape and size class, most frequent first, at most 20.
- `first`: the shapes of the first `"messages"` messages.
- `distinct_shapes`.
- `calls`: the `count` of queued `$gen_call`s, with `callers_alive` and `callers_exited`. Exited callers show a server
  that answers callers that already timed out.

A shape is a message's structure with types in place of values, two tuple levels deep. Examples are `{:"$gen_call",
{pid, list}, {:price, binary}}` and `{port, {:data, binary}}`. In every profile, an atom shows only as a tuple's first
element (its tag). Any other atom, a bare atom message included, is `atom`. So a shape never carries a value such as the
atom in `{:password, :secret}`. A size class is `under_64b`, `under_1kib`, `under_64kib`, or `64kib_or_more` (external
term size).

Insider reads the queue only when it holds at most 10,000 messages. The process copies its queue to a separate reader
under the reader's own heap guard, and the reader keeps only the shapes. For a longer queue, or a reader over its guard
or the deadline, `read` is `false` with its `reason`: `queue_over_read_max`, `reader_heap_limit`, `deadline`, or
`process_exited`.

### Native and recon implementations

`bin_leak` garbage-collects every unprotected process once. It does this asynchronously and waits until the deadline.
`gc_pending` counts the processes it did not finish. It measures each process's binaries before and after. Insider
collects its own processes and sums them under `insider`, but never ranks them.

`bin_leak` is always Insider's own code, because `recon:bin_leak/1` reads and collects every process, protected ones
included. `ports` is Insider's own code too, because `recon:port_types/0` reads every port whatever the scan bound.
`process` is always native, because `recon:info/1` reads the process dictionary. Only `alloc` uses recon. The observer's
`--load` pushes recon (BSD-3-Clause) into a development, test, or ci target that cannot resolve it. Recon is then a
loaded library that is never started.

## Call traces

With the `"calls"` component, a session traces calls to the functions in `"calls"`. Each is `MOD.FUN/ARITY`, such as
`MyApp.Worker.handle_call/3` or `:ets.insert/2`, and a session takes at most 16. This works like `recon_trace`, but the
session owns the trace. Insider removes the trace when the session stops, when its lease expires, and when an amendment
replaces the segment. It never removes the trace when the process that asked for it exits.

A function must resolve to existing atoms and an already loaded module. Insider creates and loads nothing. Insider
refuses a runtime-preloaded module (`:erlang`, `:init`, ...) and its own modules. Each refusal is `untraceable_function`
with `function` and `reason`. The reason is `unknown_atom`, `not_loaded`, `not_found`, or `protected`.

### Start a call trace

```bash
mix insider.live start "${N[@]}" --component calls --calls MyApp.Worker.handle_call/3
mix insider.live start "${N[@]}" --component calls --calls MyApp.Worker.handle_call/3 --calls-results all --calls-max 500 --calls-rate-max 100 --calls-rate-ms 1000 --calls-max-bytes 2048
```

| Flag | Option | Default and bounds |
|---|---|---|
| `--calls` | `"calls"` | `MOD.FUN/ARITY`, repeatable, at most 16 |
| `--calls-results` | `"calls_results"` | `exceptions`, or `all` or `none` |
| `--calls-max` | `"calls_max"` | 100 calls, 1 to 10,000 |
| `--calls-rate-max` | `"calls_rate_max"` | 50 trace messages, 1 to 10,000 |
| `--calls-rate-ms` | `"calls_rate_ms"` | 1,000 ms, 1 to 60,000 |
| `--calls-max-bytes` | `"calls_max_bytes"` | 1,024 JSON bytes, 256 to 2,048 |

### Call event kinds

| Kind | Severity | `event.attributes` | `event.payload` (rich only) |
|---|---|---|---|
| `call` | info | `function`, `call_id` | `arguments` |
| `call.return` | info | `function`, `call_id`, `duration_us` | `result` |
| `call.exception` | error | `function`, `call_id`, `duration_us`, `class`, `exception`, `arguments_omitted` | `reason`, and `arguments` of the call that failed |
| `call.stopped` | warning | `reason`, `calls`, `calls_max`, `rate_max`, `rate_ms`, `open`, `results_still_recorded` | none |

- `class` is `error`, `exit`, or `throw`.
- `exception` is the module of the error as `rescue` sees it, such as `ArithmeticError` for `:badarith`. It is `nil` for
  exits and throws.
- `arguments_omitted` is `open_frames_limit`, in rich only, when Insider did not keep the call's arguments.
- The `call.stopped` `reason` is `calls_max`, `calls_rate`, `overload`, `ingress_bytes`, `pairing_limit`, or
  `pairing_lost`.

### Call pairing and recorded values

`event.subject.value` is the calling process. A result carries the `call_id` of its call. Each traced call waits on its
process's stack until its result arrives, so nested and recursive calls pair exactly. A call shed after `"calls_max"`
keeps its place on the stack. So Insider sheds its result too and never takes it for an outer call's result.

Insider never guesses a pairing. The whole trace stops in two cases: more than 16,384 waiting calls (`pairing_limit`),
or a result that does not match its stack (`pairing_lost`). Only the first 256 waiting calls keep their rendered
arguments. A later call's `call.exception` says `arguments_omitted`.

`"calls_results"` decides which results Insider records: `exceptions` (default), `all` (returns too), or `none` (calls
only). The rich renderer renders the values. It masks credentials, renders structs field by field, and runs no
application code. Each value is at most `"calls_max_bytes"` JSON bytes (default 1,024, at most 2,048). The strict
profile collects none of these values.

### Trace limits

The limits follow `recon_trace`. After `"calls_max"` calls (default 100), Insider removes the function patterns. So it
traces no new call, but it still records the results of calls that already run. The whole trace stops in two cases:

- More than `"calls_rate_max"` trace messages (calls and results, default 50) arrive within `"calls_rate_ms"` (default
  1,000).
- More than 1,024 messages wait in the collector.

Each stop is one `call.stopped` event. Insider counts the messages that arrive after a stop as the `calls_shed` gap.

### Ingress byte bound

Call-trace ingress has a soft byte bound, for development and test nodes only. The BEAM delivers every trace message
before any Erlang code can refuse it. So without a native tracer, nothing can admit or reject a message before the BEAM
copies it. The bound limits how much reaches the collector and stops the trace quickly. It does not limit how much the
runtime can copy first.

**What the bound covers.**

- In the strict profile, the safe default for shared nodes, a call message carries only the function's arity. So Insider
  copies no argument out of the calling process. The runtime's result trace messages still carry the result value, so
  the bound still charges those bytes. Under strict, Insider renders and records no result or reason (the payload is
  `nil`).
- Trace messages go first to a forwarding process. It measures each message as it reads it and forwards it to the
  collector. The size is the message's external size. For a top-level binary argument or result that is a sub-binary,
  the size also counts the larger binary that it keeps alive.
- The forwarding process drops a message that would take the bytes forwarded and not yet handled above 8 MiB. It then
  removes the trace itself, even while the collector is busy. The trace records `call.stopped` with reason
  `ingress_bytes`.
- Insider never traces the collector or the forwarding process.
- The collector's heap, shared binaries included, is limited to 64 MiB. Above it, the runtime kills the collector, which
  destroys its trace session. The session then ends as `cleanup_incomplete`.

**What the bound does not cover.**

- The forwarding process's own mailbox, before it reads a message.
- A sub-binary nested inside an argument or result. Insider charges only its own bytes.
- One message larger than the budget. The BEAM copies it once before the forwarding process drops it.

**Measured worst cases.** The measurements used OTP 29 on an Apple M-series laptop with a load average of about 30.

- 8 processes called a traced function in a tight loop: 400,000 calls in 35 to 63 ms with the default limits. The trace
  stopped at once. The forwarding process's mailbox peaked at 363,095 messages and about 100 MB in rich (167,861
  messages, about 49 MB in strict) before it drained. The collector peaked at 17.5 MB (4.4 MB strict).
- Four calls each passed a 65-byte sub-binary of a 16 MiB binary inside a tuple. Insider recorded them without stopping
  the trace, and they kept 64 MiB alive until the collector handled them.

On any node whose memory matters, trace only functions whose callers do not run in tight loops, and prefer the strict
profile.

### Trace session and cleanup

Tracing uses an isolated OTP trace session (OTP 28 and later). So another tool's tracing (`recon_trace`, `dbg`, another
trace session) is neither replaced nor cleared. On OTP 27, Insider refuses the component with `component_unavailable`
(`"reason" => "requires_otp_28"`) before anything starts. Insider never traces the collector itself.

The cleanup receipt carries `cleanup.call_trace` with these fields:

- `session`: `removed` by the collector, or `collector_exited`.
- `functions`.
- `traced_after`: how many of those functions the trace session still traces, by the runtime's own session inventory.
  The collector session checks it after removal. The receipt is `stopped` only when it is `0`.

The digest's `calls` lists, for each function, these fields:

- `calls`, `returns`, `exceptions`, and `timed` (results with a duration).
- The exact `max_us`, and `p50_us` over the window's first 1,000 results. `p50_sample` says how many results it used.
- Up to three `failures`, each with class and exception, `count`, `first_receipt`, `first_call_id`, and the disclosed
  `arguments` and `reason` of the first failure.
- Each `stopped` trace.

`--human` prints them as `Calls:` lines.

## Changes of in-memory values

Some values live only in memory, such as a dev feature-flag override, `:persistent_term`, an ETS table, or the
application environment. The store keeps only its current value. `changes` tells who changed such a value. It names a
writer only for writes through a function that you named with `--watch-write`. It cannot see any other write.

### Watch the writes of a store

```bash
mix insider.live start "${N[@]}" --component calls --component telemetry --watch-write 'MyApp.Flags.put/2'
```

The start option `"watch_writes"` (`--watch-write MOD.FUN/ARITY`, repeatable, at most 8) names the store's write
functions. It needs the `"calls"` component, and `"calls"` can then be omitted. Insider traces each write function as a
call trace, within the call trace's bounds and limits. Its `call` events carry `"write" => true` and `"key"`.

The key is the first argument. For `Application.put_env/3,4` and `:application.set_env/3,4`, the key is the application
and key joined by a space. Insider keeps the key when it is an atom or a binary of at most 128 bytes, and masks
credentials in it. Otherwise the key is `nil`. Insider still records the call and counts it toward the call trace's
limits.

In the strict profile, the trace copies only that key out of the calling process (a match-spec message), never the
value. In the rich profile, Insider renders the value as it renders call arguments. A value written under a
credential-named key, or a secret-shaped binary value, is recorded only as `[masked: N bytes]`. See
`decisions/2026-10-25_live_watched_writes_record_keys_under_strict_and_kept_mutations_outlive_the_recorder.md`.

Insider refuses a runtime-preloaded function such as `:persistent_term.put/2` or `:ets.insert/2`, as for any call trace
(`untraceable_function`, `protected`). Watch the application's own function that writes the value. FunWithFlags emits no
Telemetry for a write, so watch its writes the same way (`FunWithFlags.enable/2`).

### Read the changes

```bash
mix insider.live changes "${N[@]}" --session SESSION_ID --key 'new-checkout' --human
```

`changes(session_id, options)` returns `insider.live-changes/v1`. `writes` counts every write that Insider read.
`changes` holds the newest 256 of them, oldest first (`shown`, `omitted`). Each change has these fields:

- `key`, `function`, and `at`.
- `value`: the arguments after the key, rich only.
- `writer`: the `pid`, and the `operation`, `route`, `user_agent`, `user_id`, and `trace_id` of one request. `user_id`
  is a span's `user.id` or `usr.id` attribute or Logger `usr.id` metadata, rich only.
- `attribution`: where the writer facts came from.

`attribution` is one of these values:

- `covering`: the process's events whose time covers the write. Such an event is an `absinthe.execute.operation.stop`, a
  `bandit` or `cowboy` request stop, an OpenTelemetry span, or a Logger event.
- `following`: no event covers the write. Insider takes the nearest event of the process that ended within 60 s after
  the write, and only the events of that event's trace.
- `kept_record`: the session's kept mutation record of the process, when its trace agrees.
- `unattributed`: no event, or covering events of two traces. `unattributed` says which.

A later request of the same process never adds a fact. `repeated` groups keys written more than once over every write
read, with `complete`. `mutations` is the ring's accounting. `scan` and `gaps` say what the read reached. A gap (evicted
receipts, or older receipts that the budget left unread) makes the counts lower bounds (`complete: false`). `"key"`
keeps one key. `"reader"` and the view options are those of `timeline/2`. `--human` prints one line per write:

```text
Changes of new-checkout: 1 write
  21:04:11.532 new-checkout = true by mutation setFlag (POST /graphql, user 7d1e..., python-urllib/3.12), trace 5bf9..., pid <0.4211.0>
```

### Value changes in the digest

The digest's anomalies include `value_changes` after the request bursts. It names a watched key written more than once
in the window. It lists the key's distinct values (rich), its top writers, and the `changes --key` command. The digest
examines at most 1,024 writes. It can examine fewer writes than the window held, or the window can lose events. Then the
line says "written at least N times" and "some writes were evicted or not examined".

## Telemetry discovery

`discover/1` lists the Telemetry event names that the node can emit, so an agent need not guess them. It runs no
application code and starts nothing.

### Run discovery

```bash
mix insider.live discover "${N[@]}"
mix insider.live discover "${N[@]}" --prefix phoenix.router_dispatch
```

The result lists each name once, sorted. Each name has up to 8 `sources`, each a `source` and a `module`, and
`sources_truncated` (true when the name had more). The sources are these:

- `handler`: a handler is attached to the name (`:telemetry.list_handlers/1`). The module is the handler function's
  module. Insider leaves out its own session handlers.
- `execute` and `span`: a literal event list passed to `:telemetry.execute/2,3` or `:telemetry.span/3` in a loaded
  application module. A span name gives its `start`, `stop`, and `exception` events.

### Static scan

The static scan reads every loaded module with an object file, except two kinds. It skips Insider's own modules. It
skips the modules in the `ebin` directory of an OTP or Elixir application (`kernel`, `stdlib`, `elixir`, `logger`, and
the rest). It leaves out only those exact application directories. In a release, OTP, Elixir, and the application share
one `lib` directory under the release root, and the scan still reads the application's modules.

The scan reads a module's import table. It reads the debug info only of a module that imports one of those functions. It
reads it only when the file still holds the loaded code (the same MD5). Otherwise the module counts as `stale`. A
separate reader process decodes and walks each module's debug info as a plain term. The scan never calls the backend
module that the debug info names. It reads only Elixir definitions (`:elixir_erl`) and Erlang abstract code
(`:erl_abstract_code`). Anything else counts as `without_debug_info`. So does a module compiled without debug info, such
as one in a stripped release.

The scan finds a name built at run time, such as a prefix held in an option, only after a handler is attached. Some
names cannot be subscribed to: a segment that is not a lowercase identifier, or more than 8 segments. The scan counts
such a name under `modules.unsupported_names` and does not list it.

### Discovery bounds

The scan runs in a worker with a 2,000 ms deadline. It returns `timeout` if it overruns by 500 ms. At most two scans run
at once (`busy`). The worker and each module's reader have a 16 Mi-word heap guard. A reader over it is killed, and its
module counts as `too_large`. A worker over it is killed, and the call returns `unavailable`. `truncated_by` lists every
bound that dropped evidence, so a short list is never mistaken for a complete one:

| Reason | Bound |
|---|---|
| `deadline` | the 2,000 ms scan deadline: the module being read when it passed, and every later one, were not read |
| `modules` | more than 20,000 candidate modules |
| `names` | more than 4,096 distinct names |
| `too_large` | a module's object file (over 16 MiB) or debug info (over 2 MiB) was not read, or its heap guard killed its reader (`modules.too_large` counts them) |
| `walk` | a module's walk visited 2,000,000 nodes, or found 4,096 calls (`modules.walk_truncated` counts them) |
| `sources` | a name had more than 8 sources (`modules.sources_dropped` counts them, and the name has `sources_truncated`) |
| `events` | more than 512 names to return (`events_total` is the full count) |

`bounds.discovery` in `capabilities/0` carries the bounds.

### Prefix subscription

```bash
mix insider.live start "${N[@]}" --component telemetry --telemetry-event 'shop.*'
```

A `"telemetry_events"` entry that ends in `"*"` stands for every discovered name below the prefix, at any depth. Quote
it for the shell. `start/1` runs the same scan in the caller's process before it asks the owner. Explicit names come
first. Then come each prefix's names in sorted order, without repeats. The session's 64-event bound counts the names
after expansion. More names give `invalid_options` with `expanded` and `max`. A prefix that matches nothing gives
`unknown_telemetry_event` with `"discovered" => 0`.

The start result lists each prefix under `telemetry_event_prefixes`, with its `events` and `complete`. `complete` is
false when a bound dropped names, which is any `truncated_by` reason except `sources`. Insider expands each distinct
prefix once. It checks the shape of `"telemetry_events"` before any scan. A value that is not a proper list of at most
64 proper lists of at most 8 elements gives `invalid_options`, never a crash, and starts no scan. The names are fixed at
start. Insider does not add an event that first appears later.

### Silent events

Silence is unambiguous. `status/1` reports `telemetry_subscriptions`. For each subscribed event, it gives these fields:

- `state`: `subscribed` while this session's handler is attached to the event, else `detached`.
- `seen`: every emission that the record-time gate decided since the start or the last amendment, recorded or filtered.
  The record-time gate is the session's filter that decides each event when it is emitted. An amendment starts a new
  gate. `seen` is `nil` once the gate is gone.

`subscribed` with `seen` 0 means that the node has not emitted the event. `seen` above 0 with nothing in your reads
means that a filter dropped the event (see `filtered`) or that your view hid it. Counting `seen` adds one counter
increment to each recorded event. A dropped event also costs one.
