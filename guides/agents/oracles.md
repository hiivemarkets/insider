# ExUnit oracles

Fixed, value-free observation artifacts in `tools/insider_lab/priv/oracles/`.
Each is a single `.exs` file that, when required from a target project's
`test/test_helper.exs`, captures a bounded view of one kind of global state
before the suite, captures it again from an `ExUnit.after_suite/1` callback,
and prints exactly one JSON line. They do not select, start, or run tests. All
values below are copied from the artifacts at the current revision.

| Artifact | Schema | Output prefix | Selector inputs |
|---|---|---|---|
| `application_env_test.exs` | `insider.application-env-oracle/v1` | `INSIDER_APPLICATION_ENV_ORACLE=` | `INSIDER_ORACLE_APPLICATION` plus exactly one of `INSIDER_ORACLE_KEY` or `INSIDER_ORACLE_KEYS` |
| `telemetry_dead_handlers_test.exs` | `insider.telemetry-dead-handlers-oracle/v1` | `INSIDER_TELEMETRY_DEAD_HANDLERS_ORACLE=` | `INSIDER_ORACLE_TELEMETRY_EVENT` |
| `otel_global_state_test.exs` | `insider.otel-global-state-oracle/v1` | `INSIDER_OTEL_GLOBAL_STATE_ORACLE=` | none (fixed globals) |

All three accept an optional `INSIDER_ORACLE_CONTEXT`.

To check who may read or change a record, use the
[actor differential](#check-who-may-perform-one-operation-actor-differential)
instead. To check whether the retry of a worker after a provider failure orphans
or repeats an external effect, use the
[fault-and-rerun oracle](#check-a-worker-retry-after-a-provider-fault-fault-and-rerun).
Both are libraries that your own probe test calls, not suite observers.

## Run an oracle: `mix insider.oracle`

Use the runner. It does not edit the target, so it is safe in a checkout that
other agents share, and it saves every run.

1. Validate the target identity yourself (a `syntactic` candidate may be
   wrong).
2. Write a host profile once per target. It names things; it holds no secrets:

   ```json
   {
     "schema": "insider.oracle-host-profile/v1",
     "name": "example-host",
     "mix_command": ["mix"],
     "test_alias": "bypass",
     "passthrough_env": ["DATABASE_URL"],
     "db_suffix": {"variable": "MIX_TEST_PARTITION", "source": "environment"}
   }
   ```

   - `mix_command`: 1 to 8 elements; the first is an absolute path or a name
     looked up on `PATH`. It is executed, so the profile is trusted operator
     configuration.
   - `test_alias`: `bypass` when the host's `mix.exs` defines a `test` alias
     the runner must skip (for example Phoenix's default, which creates and
     migrates the test database), or `absent` when it defines none. A
     mismatch is refused.
   - `passthrough_env`: up to 64 variable names copied from your environment.
     The runner's own names, `PATH`, `HOME`, `MIX_ENV`, `MIX_EXS`, and
     `INSIDER_ORACLE_*`, are not allowed here or as the `db_suffix` variable,
     and the runner's assignments always win in the child.
   - `db_suffix`: `null`, `{"variable": NAME, "value": "_suffix"}`, or
     `{"variable": NAME, "source": "environment"}`, which requires `NAME` in
     your environment. Values match `[A-Za-z0-9_]{1,63}`.

   The child gets exactly `HOME`, `PATH`, `MIX_ENV=test`, `MIX_EXS`, the
   runner's own `INSIDER_ORACLE_RUNNER_*` variables, the oracle inputs, the
   suffix, and the declared names. Nothing else from your environment reaches
   it.
3. Compile Lab first so compiler output does not precede the JSON, then run
   one selected test command. The run directory must not exist yet and must
   resolve, after symlinks, outside the target and its Git work tree:

   ```sh
   (cd tools/insider_lab && mix compile)
   (cd tools/insider_lab && mix insider.oracle --profile host.json \
     --root /path/to/project --output /tmp/oracle-runs/run-1 \
     --oracle application_env --application logger --key default_handler \
     -- test/path/to/selected_test.exs --seed 1)
   ```

   `--oracle` is `application_env` (`--application` plus `--key` or
   `--keys`), `telemetry_dead_handlers` (`--event a,b,c`), or
   `otel_global_state`. Optional: `--context` (default
   `insider-oracle-run:<run_id>`; never put a secret in it), `--timeout-ms`
   (default 900,000; 1,000 to 7,200,000), `--max-output-bytes` (default
   1,048,576; 4,096 to 67,108,864), `--output-policy` (`allowlisted`, the
   default, or `redacted`), `--fingerprint-timeout-ms` (default 120,000; 1,000
   to 3,600,000), and `--fingerprint-max-bytes` (default 4 GiB). After `--`: 1
   to 16 paths inside the root, each optionally with `:line`, and only
   `--seed`, `--max-cases`, `--max-failures`, `--timeout`, `--trace`,
   `--only`, `--include`, or `--exclude`.
4. Read the exit status and the `run.json` printed on stdout:

   | Exit | `status` | Meaning |
   |---|---|---|
   | 0 | `not_reproduced` | Complete; the oracle reported `unchanged` or `decreased`. |
   | 2 | `confirmed` | Complete; the oracle reported `changed` or `increased`. |
   | 6 | `not_observed` | Complete; the oracle reported `inconclusive` or `operational_failure`. |
   | 3 | `empty_selection` | No selected test executed. |
   | 4 | `unsupported_source` | The target is not a Git-tracked, non-umbrella Mix project, contains a submodule or nested repository (`target_has_nested_repository`) or a path the runner cannot read (`target_path_unreadable`), or contradicts the profile. |
   | 5 | `truncated` | Saved output was cut; `outcome` still holds the oracle's result. |
   | 70 | `infrastructure_failure` | No usable evidence; `completeness_reason` says why. |
   | 64 | (error document) | Invalid input; no run directory was created. |

   Only exit 0, 2, and 6 are complete runs. `infrastructure_failure` reasons
   include `result_line_missing`, `duplicate_result_line`,
   `result_line_invalid` (not the named oracle's exact report shape, or a
   status its own evidence does not support), `context_mismatch`,
   `result_identity_mismatch` (the report observed a different application,
   key list, or event than requested), `test_command_failed` (a selected test failed; the
   oracle report is kept but is not evidence), `deadline_exceeded`,
   `process_cleanup_uncertain`, `target_fingerprint_budget_exceeded`, and
   `target_changed`. The runner never reports `contract_disproved`.

The run directory holds `run.json` (`insider.oracle-run/v1`), `output.txt`,
and the exact `oracle/`, `runner/mix.exs`, and `runner/overlay/test_helper.exs`
files that ran. The record names the oracle and its SHA-256, the exact command,
the target root, Git revision, fingerprint budget, before/after fingerprints of
every tracked and untracked, not-ignored file (with `changed_path_count` and up
to 32 `changed_paths`), the profile and its SHA-256, timestamps, exit status,
the output policy, and a cleanup verdict. Passthrough values are never
recorded. If the passthrough values are over the redaction bounds (more than
64, more than 1 KiB each, or more than 16 KiB in all), more than 16,384 spans
would be replaced, or redaction runs out of its work budget, no output is
saved: `output.txt` holds only the reason, and `output.withheld` in the record
is `secret_count_exceeded`, `secret_bytes_exceeded`,
`redaction_count_exceeded`, or `redaction_work_exceeded`. The decoder rejects
a record whose verdict contradicts its evidence,
including a complete record whose command, selection, or nested profile does
not match the report it accepts, and any record whose child environment is
not exactly the runner's own assignments (`MIX_ENV=test`, bootstrap, overlay,
and oracle under one run directory, the target's `mix.exs`, the profile's
alias mode), the oracle inputs, and the profile's suffix, or whose
passthrough lists do not partition the profile's declared names. A record whose
`oracle.source_file` or runner file names are not plain relative names (no
absolute path, no `.` or `..` segment) is rejected first, with `unsafe_path`;
the runner applies the same rule when it stages files into the run directory.

`output.txt` is never the raw stream, because a test can print a passthrough
value. `allowlisted` keeps only Mix and ExUnit summary lines (seed, tags,
`Finished in`, results, `Compiling`/`Generated`) and ends with the count of
withheld lines. `redacted` keeps every line with each exact passthrough value
replaced; it cannot catch an encoded value, so use it only to read a failure.
In both, at a `--max-output-bytes` cut any part of a value at the edges is
found in the original bytes and removed first, together with any complete
value straddling that edge and the partial lines on both sides; then every
occurrence of every value, overlapping ones included, is replaced in the raw
bytes before lines are split, so a value containing a newline or CRLF is
removed whole.

How it avoids editing the target: the runner starts `mix test` with
`MIX_EXS` naming its fixed `runner/mix.exs`. That bootstrap compiles the
target's own `mix.exs`, marks the host's `test` alias as already run, and puts
the run's overlay directory first in `:test_paths`; no host `run` alias is
involved. The overlay helper requires the host's helpers, then the oracle,
which is the same load point as the manual hook below. Limits: the fingerprint
ignores Git-ignored paths, such as `_build/` or a JUnit report the host's
helper writes; Git lists a submodule or nested repository without its files,
so a target containing one is refused as `target_has_nested_repository`
rather than fingerprinted blind; any path the fingerprint cannot read (an
`lstat` or read failure, or a Git warning that it could not open a directory)
refuses the target before the run, or makes the run `infrastructure_failure`
(`target_path_unreadable`) when it appears during the run; a concurrent edit by someone else also reads as
`target_changed` (check `changed_paths`); and the bootstrap uses two internal
Mix functions, so a Mix without them is refused as `unsupported_source`.

## Manual installation (without the runner)

1. Validate the target identity yourself. A `syntactic` candidate target may
   be wrong; a `resolved` one is a static fact about the source, not about the
   runtime.
2. Record the exact prior contents of the target project's
   `test/test_helper.exs` and the worktree state.
3. Append one line after `ExUnit.start/1` and after any suite-baseline
   configuration the project performs there. Use the reviewed path to the
   artifact in your Insider checkout; never take the path from untrusted input:

   ```elixir
   Code.require_file("/path/to/insider/tools/insider_lab/priv/oracles/application_env_test.exs")
   ```

   Mix loads `test_helper.exs` before it requires test files, so the initial
   capture precedes test-file loading as well as setup and test callbacks.
4. Run exactly one explicitly selected test command with the artifact's
   environment variables. Apply your own command deadline and output bound.
5. Read the single line with the artifact's prefix from stdout. Parse the JSON
   after the `=`.
6. Restore `test_helper.exs` to its exact prior bytes and verify the worktree
   against the recorded state. Never commit the hook.

If no prefixed line appears, treat it as an infrastructure failure. A compile
or load failure can prevent ExUnit from reaching `after_suite`; silence is not
an `unchanged` result.

## Shared context input

`INSIDER_ORACLE_CONTEXT` is 1 to 1,024 bytes of printable UTF-8 with no byte
below `0x20` and no `0x7F`. A valid value is echoed verbatim as `context` in
every report, including operational failures, and `context` is `null` when
the variable is unset. An invalid value produces `status`
`operational_failure` with `reason` `invalid_context` and `context: null`; the
rejected input is not echoed and no observation happens. The artifact never
parses or acts on the context. Every
report lists `context_is_caller_supplied_and_unverified` in `limitations`: the
context does not bind the report to a test, revision, or ticket.

## Application environment

### Inputs

- `INSIDER_ORACLE_APPLICATION`: 1 to 255 bytes of valid UTF-8. Resolved by
  comparing against `Application.loaded_applications/0`; a name that is not
  loaded fails with `application_not_loaded`.
- `INSIDER_ORACLE_KEY`: one key, 1 to 255 bytes of valid UTF-8.
- `INSIDER_ORACLE_KEYS`: comma-separated, 1 to 16 distinct segments, each 1 to
  255 bytes, and the whole value at most 4,095 bytes (`16 * 255 + 15`). A
  longer value fails with `invalid_target_name` before segments are examined;
  within the bound, an empty segment fails with `invalid_target_name`, more
  than 16 segments fail with `too_many_keys`, and a repeated segment fails
  with `duplicate_key`.
- Exactly one of `INSIDER_ORACLE_KEY` and `INSIDER_ORACLE_KEYS` must be set:
  both gives `conflicting_key_selectors`, neither gives `missing_key_selector`.

Key names are resolved by comparing `Atom.to_string/1` of each key in
`Application.get_all_env/1` against the input; the artifact never interns
caller input.

### Capture and comparison

For each key, a capture records `presence` (`present`, `missing`, or `unknown`
when the environment could not be read), whether the value's
`:erlang.external_size/1` is at most 1,048,576 bytes, and, when it is, an
`hmac-sha256:` fingerprint over `:erlang.term_to_binary(value, [:deterministic])`
keyed with 32 random bytes drawn at install time. The key is not exported, so
fingerprints are comparable only within one run (across keys and across the
two captures), and never to another run or another machine.

Per-key `unchanged` is `null` when either capture was unobserved, `false` when
presence differs, `true` when both are missing, the fingerprint equality when
both are comparable, otherwise `null`. Status is `unchanged` for `true`,
`changed` for `false`, `inconclusive` for `null`.

### Report fields

Always: `schema`, `status`, `context`, `limitations`, `value_byte_limit`
(1,048,576), `key_limit` (16), `context_byte_limit` (1,024). Observation
reports add `application`; an `operational_failure` report adds `reason` and
omits `application`.

Single key adds at top level: `key`, `status`, `unchanged`, `initial_presence`,
`final_presence`, `initial_observed`, `final_observed`, `initial_fingerprint`,
`final_fingerprint`.

Multiple keys adds `status` and `unchanged` as aggregates (`changed` if any key
changed, else `inconclusive` if any key is inconclusive, else `unchanged`), plus
`targets`: one entry per requested key in request order, each with `key` and
the same per-key fields.

Operational failure: `status` `operational_failure`, `reason`, `context`,
`limitations`, and the three limits. Reasons: `invalid_context`,
`invalid_target_name`, `conflicting_key_selectors`, `missing_key_selector`,
`too_many_keys`, `duplicate_key`, `application_not_loaded`. Input failures are
emitted at install time, before the suite runs.

Limitations: `caller_must_bind_test_and_revision`,
`context_is_caller_supplied_and_unverified`,
`fingerprints_comparable_within_run_only`,
`state_change_does_not_establish_causality`.

Never emitted: any configured value, the HMAC key, any key not requested.

## Telemetry dead handlers

### Input

`INSIDER_ORACLE_TELEMETRY_EVENT`: a comma-separated atom path of 1 to 2,048
bytes, 1 to 16 segments, each 1 to 255 bytes. Anything else, or an unset
variable, fails with `invalid_event_name`. Segments are resolved with
`String.to_existing_atom/1` at each capture; if any segment is not an existing
atom at a capture, the handler count for that capture is exactly zero, which
is the truth for an event no code has named yet.

### Capture and comparison

Each capture runs `:telemetry.list_handlers(event)` in a spawned worker with a
262,144-word `max_heap_size` and a 1,000 ms deadline. Telemetry's lookup
enumerates the event as a prefix, so descendants are returned and count
toward the handler bound. If more than 1,024 handlers come back the capture is
unobserved with reason `handler_limit_exceeded`; worker death is
`capture_failed`; the deadline is `capture_timeout`. Among the returned
handlers the artifact counts only those whose `event_name` equals the exact
event, whose function identity is `{:telemetry_test, :handle_event, 4}`, and
whose `config.dest_pid` is a PID that is no longer alive.

`delta` is `final - initial` when both captures were observed, else `null`.
Status: `increased` (delta > 0), `unchanged` (0), `decreased` (< 0),
`inconclusive` (`null`).

### Report fields

`schema`, `event` (the segment list as given), `context`, `limitations`,
`status`, `initial_dead_handler_count`, `final_dead_handler_count`, `delta`,
`initial_observed`, `final_observed`, `initial_truncated`, `final_truncated`,
`initial_reason`, `final_reason`, and the limits `event_byte_limit` (2,048),
`event_segment_limit` (16), `event_segment_byte_limit` (255),
`context_byte_limit` (1,024), `handler_limit` (1,024), `capture_timeout_ms`
(1,000), `capture_heap_words` (262,144).

Operational failure reasons: `invalid_context`, `invalid_event_name`.

Limitations: `caller_must_bind_test_and_revision`,
`context_is_caller_supplied_and_unverified`,
`only_telemetry_test_dead_destinations_are_counted`,
`prefix_lookup_descendants_affect_bounds`, `handler_snapshot_is_not_atomic`,
`count_change_does_not_establish_causality`.

Never emitted: handler ids, PIDs, functions, function environments, handler
configuration, event payloads, measurements, or metadata.

## OpenTelemetry global state

### Preconditions

The target test VM must have the `opentelemetry_api` application loaded; the
artifact checks `Application.loaded_applications/0` at install time and
otherwise emits `operational_failure` with reason `opentelemetry_api_not_loaded`.
The target project must therefore already depend on `opentelemetry_api`. Lab
depends on it only in `:test` for the artifact's own tests; the root `:insider`
application does not depend on it. There is no selector: the observed globals
are fixed.

### Capture and comparison

Three accessors on `:opentelemetry` are read at each capture, in this order:
`get_tracer/0` (reported as `default_tracer`), `get_text_map_injector/0`
(`text_map_injector`), and `get_text_map_extractor/0` (`text_map_extractor`).
The API has no tracer-provider accessor, so the global provider is observable
only through its default tracer; `set_text_map_propagator/1` writes the
injector and extractor together. Each value is fingerprinted exactly as the
application-env artifact does, with the same 1,048,576-byte external-size bound
and a per-run random key. A value that cannot be read is unobserved and makes
that global `inconclusive`.

Per-global `unchanged` is the fingerprint equality when both captures are
comparable, else `null`. The top-level `status` is `changed` if any global
changed, else `inconclusive` if any is `null`, else `unchanged`.

### Report fields

`schema`, `api_application` (`opentelemetry_api`), `sdk_application`
(`opentelemetry`), `context`, `limitations`, `value_byte_limit`,
`context_byte_limit`, `status`, `unchanged`, `targets` (three entries, each
with `global`, `status`, `unchanged`, `initial_observed`, `final_observed`,
`initial_fingerprint`, `final_fingerprint`), and four informational booleans
that do not affect status: `initial_sdk_loaded`, `initial_sdk_started`,
`final_sdk_loaded`, `final_sdk_started`.

Operational failure reasons: `invalid_context`, `opentelemetry_api_not_loaded`.

Limitations: `caller_must_bind_test_and_revision`,
`context_is_caller_supplied_and_unverified`,
`fingerprints_comparable_within_run_only`,
`global_state_change_does_not_establish_causality`,
`only_default_tracer_and_text_map_propagator_are_observed`.

Never emitted: tracer or propagator module names, tracer configuration (which
includes the SDK's provider PID, sampler, and id generator), propagator terms,
or the HMAC key.

## What an oracle result means

- `changed` / `increased`: the observed global was different after the suite
  than before it, inside this one bounded run. It does not say which test
  changed it, whether the change matters, whether it reaches production, or
  what a correct repair is.
- `unchanged` / `decreased`: no retained difference for the observed identity,
  within the artifact's bounds. Values the artifact could not compare are
  not covered.
- `inconclusive`: a bound or read failure prevented comparison for at least
  one target. Rerun with a narrower selection or investigate the bound.
- `operational_failure`: the artifact never observed anything. Fix the input
  or the environment and rerun.
- No line at all: infrastructure failure. Never record it as a clean result.

The report is not bound to a test path or source revision. You must retain the
command, selected test, revision, and inventory candidate id alongside the
report yourself; `INSIDER_ORACLE_CONTEXT` is a convenience for that, not a
proof of it.

## Check who may perform one operation: actor differential

Use this when the question is "may this role read or change that record?".
Your probe runs one operation as several actors, each against a fresh fixture,
and the oracle compares what happened with the rule you declare.

1. Write a disposable probe test in the target. Require the library at the top
   of the file, from your reviewed Insider checkout:

   ```elixir
   Code.require_file("/path/to/insider/tools/insider_lab/priv/probes/actor_differential.exs")
   ```

2. In one test, call `InsiderLab.ActorDifferentialOracle.run/1`. Every
   function is your host adapter; the oracle never calls host code itself:

   ```elixir
   report =
     InsiderLab.ActorDifferentialOracle.run(%{
       operation: "withdrawBid on a bidder's bid",         # label, echoed
       fixture: fn -> bid_placed(ctx) end,                 # fresh per actor
       actors: [
         %{name: "bidder", access: :allow, control: true, as: & &1.bidder},
         %{name: "stranger", access: :deny, control: true, as: fn _ -> create_user() end},
         %{name: "seller", access: :deny, as: & &1.seller}
       ],
       request: fn user, f -> post_withdraw(ctx.conn, user, f.bid.id) end,
       allowed?: &match?(%{"data" => %{"withdrawBid" => %{"__typename" => "WithdrawBidSuccess"}}}, &1),
       state: fn f -> b = Repo.reload!(f.bid); %{status: b.status, amount: b.amount} end,
       effect: [:status]                                   # keys a permitted request changes
     })
   ```

   - Declare at least one entitled control (`access: :allow, control: true`)
     and, so an over-broad `allowed?` is caught, one refusal control (an
     unrelated user or no session). Other actors are compared.
   - `as` gets the fixture and returns whatever `request` needs (a user, a
     conn). `allowed?` takes the response, or the response and the fixture,
     and returns a boolean.
   - `state` is optional (omit it and `effect` for reads). Return at most 16
     keys whose values are free of ids and timestamps: every actor's starting
     state must equal the control's. Keep each value under 1 MiB and 65,536
     terms and free of functions; anything else cannot be fingerprinted and
     is never treated as equal.
3. Run the probe through the host's normal test command and read the
   `INSIDER_ACTOR_DIFFERENTIAL_ORACLE=` line (one per call), or assert on the
   returned map, which is the same report.

Read `outcome` first:

| `outcome` | Meaning |
|---|---|
| `confirmed` | A compared actor broke the rule: `wrongly_granted`, `state_changed_while_refused`, `wrongly_refused`, or `granted_without_effect` (see each actor's `reason`). |
| `not_reproduced` | Every compared actor followed the rule. Covers only the declared actors. |
| `not_observed` | An attempt failed (`<stage>_failed`), a state value was not comparable (`state_not_comparable`), or an actor did not start from the control's state (`initial_state_differs_from_control`, or `initial_state_not_comparable` when a value could not be fingerprinted). |
| `infrastructure_failure` | No verdict. A control was unhealthy (`control_unhealthy`, `denial_control_unhealthy`; the control's `reason` says which check) or the declaration was malformed (`reason` names the field rule). |

`completeness` is `complete`, `truncated` (a response summary hit a bound; the
outcome still holds), or `infrastructure_failure`. The report never contains a
response or state value. Per actor it records `observed_access` (`granted`,
`refused`), the failing `stage` and exception module, the response's field
paths and kinds (`$.data.withdrawBid: null`), `__typename` values, error
codes under `errors` or `extensions`, whether the response equals the
control's, and per state key whether it `changed` and matches the control
before and after. Limits are in `limits`; the oracle runs in your test
process, so the ExUnit test timeout bounds it, and a database error inside one
attempt can abort the test's sandbox transaction and corrupt every attempt
after it; if one actor's `error` names a database exception, rerun without it.
Never print responses yourself in the same probe.

## Check a worker retry after a provider fault: fault and rerun

Use this when the question is "if this provider call fails, does the retry
create the remote object again, or leave one no local row points to?". Your
probe declares the provider functions and one fault; the oracle stubs them,
runs the worker once with no fault as a control, then with the fault and again
as the retry, and compares the effects with what the database kept.

1. Write a disposable probe test in the target and require the library:

   ```elixir
   Code.require_file("/path/to/insider/tools/insider_lab/priv/probes/fault_rerun.exs")
   ```

2. In one test, call `InsiderLab.FaultRerunOracle.run/1`. Every function is
   your host adapter:

   ```elixir
   report =
     InsiderLab.FaultRerunOracle.run(%{
       operation: "PaymentWorker, verify PUT fails once",
       fixture: &pending_order/0,                            # fresh per run
       perform: fn f -> perform_job(PaymentWorker, %{order_id: f.order.id}) end,
       stub: &Mimic.stub/3,                                  # module copied in test_helper
       boundaries: [
         %{name: "account_create", function: {MyApp.Payments.Http, :post},
           respond: fn _args, call -> %{status: 201, body: %{"id" => "acct-#{call.sequence}"}} end,
           effect: fn _args, %{body: %{"id" => id}} -> id end,   # identity of what it created
           expect: 1,                                            # the control makes exactly one
           key: fn args -> args |> Enum.at(3, []) |> Keyword.get(:idempotency_key) end},
         %{name: "account_verify", function: {MyApp.Payments.Http, :put},
           respond: fn _args, _call -> %{status: 200, body: %{}} end}
       ],
       fault: %{boundary: "account_verify", result: {:return, %{status: 500, body: %{}}}},
       references: fn f ->                                   # ids committed rows hold, per boundary
         id = Repo.reload!(f.order).payment_account_id
         %{account_create: [id && Repo.get!(Account, id).provider_id]}
       end
     })
   ```

   - The oracle stubs every exported arity of each `function`; `respond`,
     `effect`, and `key` get the argument list, so one function serves
     `put/3` and `put/4`. If you add `arities: [3, 4]`, it must name exactly
     the exported ones. Stub reads and updates that create nothing with Mimic
     yourself; declare only what you count or fault.
   - `respond` gets `%{sequence: n}`, unique per boundary across the call, for
     fresh provider ids. Return what the real client returns.
   - `effect` returns the provider id of what the call created, or `nil`.
     `expect` is the exact number of distinct ids the control makes. Use
     `referenced: false` for objects the host never stores (they are counted
     for repeats only). With `key`, a repeated non-nil key replays the first
     response, as a provider that honours idempotency keys does; a concurrent
     call with the same key waits up to 2 s for the first. Keep keys and keyed
     responses small (under 1 MiB and 65,536 terms, 8 MiB of responses and 512
     keys per scenario) and never call the same key from inside `respond`: a
     key that cannot be compared or replayed makes the run `key_not_comparable`.
   - `fault` takes `boundary`, `call` (the Nth call to it in an attempt,
     default 1), `attempts` (leading attempts faulted, default 1), `result`
     (`{:return, term}` or `{:raise, exception}`), and `lost_response: true`
     when the provider did the work but the reply was lost. Set `attempts`
     (2 to 8, default 2) for more retries; attempts stop at the first success.
   - `references` returns the provider ids that committed rows for this
     fixture hold, grouped by the effect boundary that creates them
     (`%{va_create: [...]}`; `nil` entries are ignored, at most 1,024 ids). An
     id matches only effects of its own boundary, so equal ids from two
     providers never stand for each other. Both fixtures share the test's
     sandbox, so scope the query to the fixture.
   - `perform` may take the attempt number as a second argument;
     `succeeded?` overrides the default success check (`:ok` or `{:ok, _}`).
     `perform` must run the jobs the worker enqueues and join any process it
     starts: a declared effect made outside an attempt (by left-over work, the
     fixture, or the projection) makes the run `effect_outside_attempt`, and
     work still running when `run/1` returns is not seen at all.
3. Run the probe through the host's normal test command and read the
   `INSIDER_FAULT_RERUN_ORACLE=` line, or assert on the returned map.

Read `outcome` first:

| `outcome` | Meaning |
|---|---|
| `confirmed` | The fault run left an effect no committed row references (`orphaned_effect`), made more distinct effects than the control (`repeated_effect`), or succeeded with fewer committed effects than expected (`missing_effect`). See `fault_run.reasons`. |
| `not_reproduced` | The retry converged with exactly the expected, referenced effects (`converged_once`). Covers only the declared boundaries and fault. |
| `not_observed` | An adapter failed (`<stage>_failed`), the fault was not reached (`fault_not_reached`), an idempotency key could not be compared or replayed (`key_not_comparable`), a declared effect happened outside an attempt (`effect_outside_attempt`; both outrank any confirmed reason), a value was not comparable (`effect_not_comparable`), the record was truncated with no confirmed reason (`recorder_truncated`), or no attempt succeeded (`retry_did_not_succeed`). |
| `infrastructure_failure` | No verdict. The control was unhealthy (`control_unhealthy`; `control.reasons` says which check, such as `control_orphaned_effect` when your projection misses where the host stores the id), a stub could not be installed (`stub_failed`), or the declaration was malformed (`reason` names the rule, such as `arity_not_covered`). |

`completeness` is `complete`, `truncated` (more than 512 calls in a scenario
or 64 listed effects; orphans and repeats are lower bounds and still confirm),
or `infrastructure_failure`. Per scenario the report lists each attempt
(`faulted`, `fault_reached`, the result `kind` and leading atom `tag`,
`succeeded`, calls per boundary and arity), up to 64 effects with their
attempt and per-call labels (`e1`, `k1`)
and whether a committed row references them, and per boundary the distinct,
referenced, and orphaned counts and idempotency keys seen. It never contains
an argument, response, id, key, or reference value. A boundary called after
`run/1` returns raises; the stubs stay installed until the test ends.
