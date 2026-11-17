# Lab: ExUnit candidates and oracles

[Index](README.md) · [Glossary](glossary.md) · [Cheat sheet](cheat-sheet.md)

The Lab's static inventory of test-isolation candidates, the fixed value-free
oracles that can confirm one, the oracle runner, the actor differential, and
fault and rerun.

## Contents

- [Agent-requested ExUnit candidates](#agent-requested-exunit-candidates)
  - [Scan](#scan)
  - [Output](#output)
  - [Exit codes](#exit-codes)
  - [Signals](#signals)
- [Application-env oracle](#application-env-oracle)
  - [Value-free application-env oracle](#value-free-application-env-oracle)
- [Handler and global-state oracles](#handler-and-global-state-oracles)
  - [Value-free Telemetry dead-handler oracle](#value-free-telemetry-dead-handler-oracle)
  - [Value-free OpenTelemetry global-state oracle](#value-free-opentelemetry-global-state-oracle)
- [Run an oracle without editing the target](#run-an-oracle-without-editing-the-target)
  - [Oracle runner](#oracle-runner)
- [Probe-library oracles](#probe-library-oracles)
  - [Actor differential](#actor-differential)
  - [Fault and rerun](#fault-and-rerun)
- [Flaky tests: what Insider offers](#flaky-tests-what-insider-offers)

## Agent-requested ExUnit candidates

Lab can inventory an explicitly selected test tree for static isolation and
nondeterminism signals. An agent runs it before it spends time on runtime
investigation.

### Scan

```sh
(cd tools/insider_lab && mix compile)
(cd tools/insider_lab && mix insider.candidates --root /path/to/project)
(cd tools/insider_lab && mix insider.candidates --root /path/to/project \
  --path test/integration --max-files 1000 --max-bytes 33554432 \
  --max-candidates 100 --max-duration-ms 5000)
(cd tools/insider_lab && mix insider.candidates --root /path/to/project \
  --path test/first_test.exs --path test/second_test.exs)
```

Candidate inventory is Lab-only and development/CI-oriented. It reads only
exact file or directory selectors within the declared root. It rejects
missing or escaping selectors and does not follow symlinks. By default it
stops at 5,000 files, 64 MiB of source, 500 candidates, and 10 seconds of work.

The scan does not expand globs or load or evaluate target source. It does not
execute tests, read credentials, contact providers, or grant
staging/production authority. The selectors must refer to a stable local
checkout. Concurrent replacement of files or directories during a scan is
outside this slice's trust boundary.

### Output

The task writes one `insider.exunit-candidate-inventory/v2` JSON object to
stdout. A cold Mix project can write compilation progress before the task
starts. So agents that parse stdout must compile Lab as a separate setup step.

Every inventory carries a `completeness` state. Only a `complete` scan with no
candidates is clean. Incomplete inventories keep candidates within the
configured candidate bound. Each candidate has a stable content identity,
relative source path, score, reason codes, source lines, and bounded evidence.
The inventory includes source and configuration fingerprints. It also
includes file, byte, candidate, unsupported-source, and truncation accounting.
The [candidates guide](../guides/agents/candidates-cli.md) lists the exact
keys, signal weights, and switch bounds.

### Exit codes

| Exit | Meaning |
|---|---|
| `0` | Clean inventory |
| `2` | A complete scan found candidates |
| `3` | `empty_selection`: the selectors held no eligible `_test.exs` file |
| `4` | `unsupported_source`: the scanner could not analyze a file |
| `5` | `truncated`: the scan hit a file, byte, or candidate bound |
| `64` | Invalid arguments (an `insider.exunit-candidate-inventory-error/v1` document) |
| `70` | `infrastructure_failure`: the inventory cannot be completed |

### Signals

The scanner parses Elixir syntax and inspects executable AST. So it does not
treat source examples inside strings and quoted syntax as behavior. It
recognizes application-specific case templates. It tells apart cleanup for
the same application-env key or Telemetry handler in the same lexical
test/setup/function scope from unrelated cleanup.

Its ranking is a request-time heuristic. `candidate` never means confirmed
defect, runtime cause, security impact, or financial impact. The calling agent
chooses what to investigate next. Insider starts no background scan, queue,
scheduler, test process, or coding model.

**Targets.** When an application-environment mutation or Telemetry attachment
names literal target arguments, the candidate also carries those identities,
the operation, and call-site lines. The target kinds are:

- `application_env`: application, key, and operation.
- `telemetry_handler`: the literal handler id passed to `:telemetry.attach/4`
  or `:telemetry.attach_many/4`.
- `telemetry_event`: one entry per literal event path passed to
  `:telemetry.attach/4`, `:telemetry.attach_many/4`, or
  `:telemetry_test.attach_event_handlers/2`, as a list of segment strings. A
  dynamic event list or element produces one unresolved `telemetry_event`
  target.

`:telemetry_test.attach_event_handlers/2` attaches a VM-global handler. The
scanner ranks it with the same `global_telemetry_handler` signal. Its handler
id is the returned reference, which is not visible statically. So the scanner
never credits it with matching cleanup, even when the test detaches the bound
variable in `on_exit`.

**Resolution.** The scanner can resolve a root-qualified `Elixir.Application`
call. It labels an unqualified `Application` call `syntactic`, because a macro
could shadow it. It interprets simple, visible aliases in lexical declaration
order, without loading or expanding adopter code. It still marks the resulting
identity `syntactic`, because an unseen macro can alter the alias environment.
Local aliases are scoped to their enclosing test, setup, or function. Each
top-level `defmodule` in a file gets its own alias environment. Rebound
aliases, grouped multi-alias key forms, and other dynamic identities stay
unresolved. The scanner does not guess them.

**Oracle hints.** Each target carries an `oracle` field:

- For a resolved or syntactic `application_env` target, it names the fixed
  application-env artifact schema and its `INSIDER_ORACLE_APPLICATION` /
  `INSIDER_ORACLE_KEY` inputs.
- For a resolved `telemetry_event` target, it names the Telemetry
  dead-handler artifact schema and the comma-joined
  `INSIDER_ORACLE_TELEMETRY_EVENT` input.
- It is `null` for `telemetry_handler` targets, unresolved targets, and
  identities that the artifact would reject or reinterpret. These are a
  segment that contains a comma, names and paths beyond the artifact's byte
  and segment bounds, and any byte below `0x20` (which could not pass through
  the environment unchanged).

The hint is a static re-encoding of the identity already in the target. It
does not install, start, or authorize anything. An agent must still validate
a `syntactic` identity before use. The scanner deduplicates targets and keeps
at most 64 per candidate across all kinds, with visible truncation. It never
includes configured values, callbacks, or executable terms. These identities
tell an agent what a separate runtime oracle could observe. They do not read
the target or confirm a defect.

## Application-env oracle

### Value-free application-env oracle

After it validates a candidate's application and key, an agent installs the
fixed Lab-only oracle artifact from `test/test_helper.exs`. It goes after
`ExUnit.start/1` and after any intended suite-baseline configuration:

```elixir
Code.require_file(
  "/path/to/insider/tools/insider_lab/priv/oracles/application_env_test.exs"
)
```

Mix loads `test_helper.exs` before it requires test files. So this explicit
hook brackets test-file loading as well as setup and test callbacks. The agent
then runs one explicitly selected test command, naming one key:

```sh
INSIDER_ORACLE_APPLICATION=logger \
INSIDER_ORACLE_KEY=default_handler \
mix test test/path/to/selected_test.exs
```

or a comma-separated set of up to 16 distinct keys in one application:

```sh
INSIDER_ORACLE_APPLICATION=logger \
INSIDER_ORACLE_KEYS=default_handler,default_formatter \
mix test test/path/to/selected_test.exs
```

Set exactly one of `INSIDER_ORACLE_KEY` and `INSIDER_ORACLE_KEYS`. Both set
reports `conflicting_key_selectors`. Neither set reports
`missing_key_selector`. The whole `INSIDER_ORACLE_KEYS` value must fit 4,095
bytes, otherwise it reports `invalid_target_name`. Within that, each key
segment is 1 to 255 bytes of valid UTF-8, and the artifact rejects empty
segments. More than 16 segments reports `too_many_keys`. A repeated segment
reports `duplicate_key`.

**Context.** Each oracle also accepts an optional `INSIDER_ORACLE_CONTEXT`: up
to 1,024 bytes of printable UTF-8 without newlines or other control
characters. The artifact echoes a valid value verbatim as `context` in every
report, including operational failures. It emits `null` when the variable is
unset. An out-of-bound, empty, non-UTF-8, or control-character value reports
`operational_failure` with reason `invalid_context`. The artifact never parses
or acts on the context. It is a caller-supplied correlation handle. So a
report's `context` is unverified and does not by itself bind the output to any
test, revision, or ticket. The `context_is_caller_supplied_and_unverified`
limitation records this.

**Remove the hook.** The `test_helper.exs` hook is a temporary investigation
change. Remove it immediately after the selected command. Restore the file's
exact prior contents, and verify the target worktree against its recorded
pre-run state. Do not commit the hook to the adopter application.

**Report.** The artifact reads the selected entries before the suite and from
an ExUnit after-suite callback. When execution reaches that callback, it emits
one line prefixed with `INSIDER_APPLICATION_ENV_ORACLE=`. The line contains
versioned `insider.application-env-oracle/v1` JSON. Status is `changed`,
`unchanged`, `inconclusive`, or `operational_failure`.

A single-key report keeps `key`, `status`, `unchanged`, presence, observation,
and fingerprint fields at the top level. A multi-key report instead carries a
`targets` list, in request order, with one entry of the same per-key fields
for each requested key. It adds an aggregate top-level `status` and
`unchanged`. The aggregate is `changed` if any key changed, otherwise
`inconclusive` if any key is inconclusive, otherwise `unchanged`.

The report contains presence and per-run HMAC fingerprints, never a
configured value. The artifact does not export the random HMAC key. So
fingerprints are comparable only within that run, across keys as well as
across captures. The artifact does not serialize values whose external
representation exceeds 1 MiB, and these make that key's content comparison
inconclusive. Application and key names are bounded to 255 bytes. The artifact
resolves them only by comparing already-loaded atoms, so it does not intern
caller input.

**Limits.** This is a read-only observation, not a test runner. The agent
still selects and invokes the exact test and validates a `syntactic` candidate
target before use. It applies its own command deadline and output bound. The
artifact scans the selected application's environment twice. It can serialize
up to 1 MiB per key per capture for HMAC calculation. It is absent from the
root production artifact. It does not itself promote a source candidate to a
confirmed defect.

Its output is not bound to a test path or source revision. A state change
alone does not establish causality, so the agent must keep that provenance
separately. A compile/load failure can prevent ExUnit from invoking
after-suite callbacks. So missing oracle output is an infrastructure failure,
never a clean result. The installed path must identify the reviewed fixed
artifact. It must not come from untrusted environment input.

## Handler and global-state oracles

### Value-free Telemetry dead-handler oracle

The candidate inventory can emit a resolved `telemetry_event` target, for
example from `:telemetry_test.attach_event_handlers/2` capture of a literal
event. Then an agent can temporarily install a second fixed Lab-only artifact
from `test/test_helper.exs`, at the same post-baseline boundary:

```elixir
Code.require_file(
  "/path/to/insider/tools/insider_lab/priv/oracles/telemetry_dead_handlers_test.exs"
)
```

The event is an exact comma-separated atom path. Segments must not be empty
or contain commas:

```sh
INSIDER_ORACLE_TELEMETRY_EVENT=insider,example,event \
mix test test/path/to/selected_test.exs
```

The artifact compares the number of handlers for that exact event whose
function is `:telemetry_test.handle_event/4` and whose `dest_pid` is no longer
alive. It emits one `INSIDER_TELEMETRY_DEAD_HANDLERS_ORACLE=` JSON line with
`increased`, `unchanged`, `decreased`, `inconclusive`, or
`operational_failure` status. Output contains the selected event, counts,
delta, bounds, and limitations. It also contains the echoed optional
`INSIDER_ORACLE_CONTEXT` described above (`null` when unset, `invalid_context`
when out of bounds). It never contains handler IDs, PIDs, functions, function
environments, handler configuration, event payloads, measurements, or
metadata.

Event input is limited to 2,048 bytes, 16 segments, and 255 bytes per segment.
The artifact resolves segments only with `String.to_existing_atom/1`. If an
event atom does not exist at initial capture, its exact handler count is
necessarily zero. The artifact retries resolution after the test files have
loaded, and it never interns the input. Telemetry's public lookup enumerates
the selected event as a prefix. The artifact then counts only exact-event
descriptors. It inspects descendant handlers and counts them toward the
safety bounds. So descendant volume can make an otherwise small exact event
inconclusive. The lookup runs in an isolated worker capped at 262,144 heap
words and one second. More than 1,024 returned handlers, worker failure, or
timeout makes the observation inconclusive.

As with the application-env oracle, the fixed-path hook is temporary. Remove
it immediately after the selected command, restore the exact prior helper,
verify the target worktree, and never commit the hook. The agent supplies the
command deadline and output bound. Missing output after compile or load
failure is infrastructure failure, never evidence of unchanged state. A count
increase establishes retained dead destinations inside the bounded run. It
does not by itself prove causality, production impact, or a correct repair.
The output is not bound to the selected test or source revision.

### Value-free OpenTelemetry global-state oracle

A candidate can carry the `otel_global_capture` signal: a call to an
`OpenTelemetry`/`:otel*` `set_tracer_provider` or `set_text_map_propagator`,
or a `setup_otel_capture` helper. Then an agent can temporarily install a
third fixed Lab-only artifact from `test/test_helper.exs`, at the same
post-baseline boundary:

```elixir
Code.require_file(
  "/path/to/insider/tools/insider_lab/priv/oracles/otel_global_state_test.exs"
)
```

The observed globals are fixed, so the artifact takes no target selector. The
command is the selected test alone, optionally with the shared
`INSIDER_ORACLE_CONTEXT`:

```sh
INSIDER_ORACLE_CONTEXT='run=flaky-1 revision=0123abcd' \
mix test test/path/to/selected_test.exs
```

The artifact reads three process-globals before the suite and from an ExUnit
after-suite callback. These are the globals that the installed
`opentelemetry_api` exposes a reader for:

- the default tracer of the global tracer provider
  (`:opentelemetry.get_tracer/0`)
- the text-map injector (`get_text_map_injector/0`)
- the text-map extractor (`get_text_map_extractor/0`)

`set_text_map_propagator/1` writes the last two together. The API has no
tracer-provider accessor, so the artifact sees the provider only through its
default tracer.

It emits one `INSIDER_OTEL_GLOBAL_STATE_ORACLE=` line of
`insider.otel-global-state-oracle/v1` JSON. Its `targets` list names
`default_tracer`, `text_map_injector`, and `text_map_extractor` in that order.
Each target carries `status`, `unchanged`, observation flags, and per-run HMAC
fingerprints. The top-level `status` is `changed` if any global changed. It is
otherwise `inconclusive` if any global could not be read or exceeds 1 MiB of
external size, and otherwise `unchanged`. The report also records, as four
booleans, whether the `opentelemetry` SDK application was loaded and started
at each capture. These are informational and do not affect the status.

The report never contains the tracer or propagator module names or the tracer
configuration (which includes the SDK's provider PID, sampler, and ID
generator). It never contains propagator terms or the random HMAC key. So
fingerprints are comparable only within one run. If the `opentelemetry_api`
application is not loaded in the test VM, the artifact reports
`operational_failure` with reason `opentelemetry_api_not_loaded`. The adopter
must already depend on `opentelemetry_api` for the artifact to observe
anything. Lab has it as a test-only dependency for the artifact's own tests.
The root `:insider` application does not depend on it.

As with the other two oracles, the fixed-path hook is temporary. Remove it
immediately after the selected command, restore the exact prior helper, verify
the target worktree, and never commit the hook. The agent supplies the command
deadline and output bound. Missing output after compile or load failure is
infrastructure failure, never evidence of unchanged state. A fingerprint
change establishes that a global was left different inside the bounded run.
It does not by itself prove causality, production impact, or a correct
repair. The output is not bound to the selected test or source revision. The
candidate inventory emits `otel_global_capture` as a ranking signal only, with
no target and therefore no `oracle` hint for this artifact.

## Run an oracle without editing the target

### Oracle runner

`mix insider.oracle` runs one of the three oracles against one selected test
command without editing the target. So it is safe in a checkout that other
agents share:

```sh
(cd tools/insider_lab && mix compile)
(cd tools/insider_lab && mix insider.oracle --profile host.json \
  --root /path/to/project --output /tmp/oracle-runs/run-1 \
  --oracle application_env --application logger --key default_handler \
  -- test/path/to/selected_test.exs --seed 1)
```

**Launch.** The task starts `mix test` in the target with `MIX_EXS` naming a
fixed bootstrap file. The bootstrap compiles the target's own `mix.exs` and
marks the host's `test` alias as already run. It puts a run-local overlay
directory first in `:test_paths`. So no host `run` alias is involved, and the
target's build is reused. The overlay's helper requires the host's helpers and
then the oracle, the same load point as the manual `test_helper.exs` hook.

An explicit `insider.oracle-host-profile/v1` file declares the `mix` command
prefix and whether the host's `test` alias is bypassed or absent. It also
declares the environment variable names to pass through and the database
suffix. The runner infers none of them and removes every other variable from
the child environment. A profile cannot pass through `MIX_EXS`, `MIX_ENV`, or
any other runner-assigned name, and runner assignments always win. The run
directory must resolve, after symlinks, outside the target root and its Git
work tree.

**Output.** Each run writes a new directory with `run.json`
(`insider.oracle-run/v1`), `output.txt`, and copies of the oracle, bootstrap,
and overlay that ran. A test can print a passthrough value, so `output.txt` is
never the raw stream. The default `allowlisted` policy keeps only Mix and
ExUnit summary lines. `--output-policy redacted` keeps every line and replaces
each exact passthrough value. The runner replaces values in the raw bytes
before it splits lines, so it removes multiline values whole. Redaction is one
streaming scan, whatever the number of overlapping values.

In these cases `output.txt` holds only the reason, and `output.withheld` in
the record names it:

- The values exceed 64, 1 KiB each, or 16 KiB in all
  (`secret_count_exceeded`, `secret_bytes_exceeded`).
- More than 16,384 spans would be replaced (`redaction_count_exceeded`).
- The scan exhausts its work budget (`redaction_work_exceeded`).

**Record.** The record holds the oracle id and SHA-256, inputs, exact command,
target root, Git revision, and the fingerprint budget. It holds before/after
fingerprints of tracked and untracked, not-ignored files, with up to 32
changed paths. It also holds the profile and its SHA-256, timestamps, exit
status, the output policy, the oracle report, and a cleanup verdict. It ends
with a completeness state (`complete`, `empty_selection`,
`unsupported_source`, `truncated`, or `infrastructure_failure`) and an outcome
(`confirmed`, `not_reproduced`, `not_observed`, or `infrastructure_failure`).

Only a `complete` run exits `0`, `2`, or `6`. The other states exit `3`, `4`,
`5`, and `70`. Invalid input exits `64` without creating a directory.

**Infrastructure failures.** The runner reports each of these as an
infrastructure failure: a missing, repeated, malformed, or unbound result
line, and a report for a different application, key list, or event than
requested. A failing selected test, a deadline, and uncertain process cleanup
also count. So do an exhausted fingerprint budget (time, listing bytes, files,
or content bytes) and a changed target fingerprint. The decoder rejects a
record whose verdict contradicts its evidence, including its recorded command,
selection, child environment, and profile.

The fingerprint does not cover Git-ignored paths such as `_build/`. The runner
refuses a target with a Git submodule or nested repository
(`unsupported_source`, `target_has_nested_repository`), because Git lists none
of its files. It never fingerprints an unreadable path as clean
(`target_path_unreadable`). Before the run that is a refusal, and after it
that is an infrastructure failure. The bootstrap depends on two internal Mix
functions present in Elixir 1.17 through 1.20. The
[oracle guide](../guides/agents/oracles.md) lists the profile fields,
switches, and exit statuses.

## Probe-library oracles

### Actor differential

To ask whether a role may read or change a record, an agent writes its own
probe test. The test requires
`tools/insider_lab/priv/probes/actor_differential.exs` and calls
`InsiderLab.ActorDifferentialOracle.run/1` with a declaration. The declaration
holds:

- a fixture function rebuilt for each actor
- the actors with their declared access (`:allow` or `:deny`, some marked as
  controls) and how each authenticates
- the request and an `allowed?` predicate
- optionally, an id-free state projection and the keys a permitted request
  must change

Every function is a host adapter. Insider holds no host code. Controls run
first. An entitled control must be granted and produce the effect. A refusal
control must be refused without changing state. Otherwise the call is an
`infrastructure_failure` and no other actor runs.

A compared actor is `confirmed` when it is granted against a `:deny` rule or
changes state while refused. It is `not_reproduced` when it follows the rule.
It is `not_observed` when its attempt failed, or when its starting state
differs from the control's or cannot be compared.

The `insider.actor-differential-oracle/v1` report and its
`INSIDER_ACTOR_DIFFERENTIAL_ORACLE=` line hold field paths and kinds, GraphQL
type names, error codes, and keyed fingerprint equality. They never hold a
response or state value. The oracle fingerprints a value only within a
65,536-term, 1 MiB budget, checked before it sizes or serializes the value. It
never treats any other value as equal. See
[the oracle guide](../guides/agents/oracles.md#check-who-may-perform-one-operation-actor-differential)
and `decisions/2026-10-21_actor_differential_oracle_is_a_probe_library.md`.

### Fault and rerun

To ask whether a background worker's retry after a provider failure orphans or
repeats an external effect, an agent writes its own probe test. The test
requires `tools/insider_lab/priv/probes/fault_rerun.exs` and calls
`InsiderLab.FaultRerunOracle.run/1` with a declaration. The declaration holds:

- a fixture function and the worker invocation
- a stub installer (`&Mimic.stub/3` on a Mimic host)
- the provider functions with simulated responses
- the identity of what each call creates, and how many the control must make
- one fault at a provider call
- a projection of the provider ids that committed rows hold, grouped by the
  boundary that creates them

Every function is a host adapter. The oracle stubs every exported arity of
each provider function, so a default-argument call cannot escape. It refuses a
declared arity list that does not match.

The worker first runs once with no fault. It must succeed with exactly the
expected, referenced effects, or the call is an `infrastructure_failure`. It
then runs against a fresh fixture with the fault, and again as the retry. The
oracle decides as follows:

- `confirmed`: an effect that no committed row references, more distinct
  effects than the control, or a success without the effect.
- `not_reproduced`: a retry that converges with the expected effects.
- `not_observed`: an unreached fault, or a retry that never succeeds.

The `insider.fault-rerun-oracle/v1` report and its
`INSIDER_FAULT_RERUN_ORACLE=` line hold call counts per arity, result tags,
exception modules, and per-call labels of keyed effect and key fingerprints.
They never hold an argument, response, id, or key. See
[the oracle guide](../guides/agents/oracles.md#check-a-worker-retry-after-a-provider-fault-fault-and-rerun)
and `decisions/2026-10-21_fault_rerun_oracle_owns_the_provider_recorder.md`.

## Flaky tests: what Insider offers

Insider does not rerun a test N times. The oracle runner runs the selected
test command once. Its allowed test arguments are the selected paths and
`--seed`, `--max-cases`, `--max-failures`, `--timeout`, `--trace`, `--only`,
`--include`, and `--exclude`. It refuses any other `mix test` option,
including `--repeat-until-failure`.

What Insider offers for a flaky test:

- **Candidate inventory** ranks tests by static isolation and nondeterminism
  signals ([Agent-requested ExUnit candidates](#agent-requested-exunit-candidates)).
- **Value-free oracles** show whether one run leaves application env,
  Telemetry handlers, or OpenTelemetry globals changed
  ([Application-env oracle](#application-env-oracle),
  [Handler and global-state oracles](#handler-and-global-state-oracles)).
- **Actor differential** and **fault and rerun** check one permission or one
  worker retry deterministically ([Probe-library oracles](#probe-library-oracles)).

To reproduce the flake itself, run ExUnit's own repeat option. It exists in
Elixir 1.17 and later:

```sh
mix test test/path/to/selected_test.exs --repeat-until-failure 100
```

`--repeat-until-failure N` repeats the selected tests up to N times in one VM
and stops at the first failure. Add `--max-failures 1` to stop at the first
failing test. Leftover global state can cause unrelated failures on a repeat.
When a run fails, note the printed seed. Then pass it as `--seed` to the
[oracle runner](#oracle-runner) to check that seed for leaked global state.
