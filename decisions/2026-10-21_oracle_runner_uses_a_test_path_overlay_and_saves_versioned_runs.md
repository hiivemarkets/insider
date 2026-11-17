# Oracle runner uses a test-path overlay and saves versioned runs

## Context

The three fixed Lab oracle artifacts were installed by hand: an agent appended
a `Code.require_file/1` line to the target's `test/test_helper.exs`, exported
`INSIDER_ORACLE_*` variables, worked around host `test` aliases that drop and
rebuild a database, parsed one JSON line, and restored the helper. Nothing was
kept, and several agents often share one target checkout, so editing the
helper raced with their runs.

## Decision

Lab adds `mix insider.oracle`. One invocation runs one fixed oracle against one
selected test command in a target Mix project and writes a new run directory
that the caller names.

- **No target edits, and no host alias but `test`'s own.** The runner starts
  `mix test <test arguments>` in the target with `MIX_EXS` naming the run's
  fixed bootstrap file. Mix loads that file in place of the target's
  `mix.exs` before any task or alias runs. The bootstrap compiles the target's
  own `mix.exs`, so the project, its file identity, and its build stay the
  target's, and then refuses (as `unsupported_source`) an umbrella project, a
  non-`test` environment, a `test` alias that contradicts the profile, or a Mix
  without the two internal functions it uses. Otherwise it marks the host's
  `test` alias as already run (`Mix.TasksServer.run({:alias, "test",
  project})`) and prepends the run's overlay directory to `:test_paths`
  (`Mix.ProjectStack.merge_config/1`). The command-line task is `test`, so a
  host `run` alias is never involved. The overlay's `test_helper.exs` requires
  the host's own helpers, prints a marker, and then requires the oracle, which
  therefore loads at the same point as an appended helper line: after the
  host's suite baseline, before any test file.
- **Containment by resolved location.** The target root, the nearest existing
  ancestor of the run directory, and the target's Git work tree are compared
  by their symlink-resolved locations before anything is created. A run
  directory inside the root or its work tree is refused as invalid input.
- **Explicit host profile.** `insider.oracle-host-profile/v1` declares exactly
  the `mix` command prefix, whether the host's `test` alias must be bypassed or
  absent, the environment variable names to pass through, and the database
  suffix variable with a literal value or an explicit "take it from the
  invoking environment". The child environment is exactly `HOME`, `PATH`,
  `MIX_ENV=test`, `MIX_EXS`, the runner's own variables, the oracle inputs, the
  suffix, and the declared passthrough names. Every other variable is removed.
  `MIX_EXS`, `MIX_ENV`, `HOME`, `PATH`, and `INSIDER_ORACLE_*` cannot be
  declared as passthrough or suffix variables, and when the child environment
  is built a runner assignment always wins over any same-named entry: a
  passthrough `MIX_EXS` would otherwise replace the bootstrap and run the
  host's `test` alias. Values of passthrough and inherited variables are never
  recorded.
- **Fail-closed output.** The child can print anything, including a
  passthrough value. `output.txt` is never the raw stream. The default
  `allowlisted` policy keeps only lines that match fixed, value-free Mix and
  ExUnit summary formats and counts the rest as withheld. The opt-in
  `redacted` policy keeps every line after replacing each exact passthrough
  value. In both, at a head/tail cut, any end of the head that could begin a
  value and any start of the tail that could end one are found in the original
  captured bytes, before any replacement could change them, and removed
  together with any complete value straddling that edge and the partial line
  on each side. Then every occurrence of every value, overlapping ones
  included, is replaced as one merged span in the raw bytes before anything is
  split into lines or normalized, so a value containing a newline or CRLF is
  matched whole and overlapping values leave no fragment.
- **Bounded identity.** Every Git call has a deadline and an output bound, and
  an overdue Git process is killed. A target fingerprint has a wall-clock,
  listing-byte, file-count, and content-byte budget (defaults 120 s, 16 MiB,
  200,000 files, 4 GiB; the time and content budgets are caller-settable). An
  exhausted budget is reported as `target_fingerprint_budget_exceeded`, and
  the record names the budget and the error.
- **Saved run record.** Each run directory holds `run.json`
  (`insider.oracle-run/v1`, canonical JSON), `output.txt`, and copies of the
  oracle, bootstrap, and overlay that actually ran. The record carries the
  oracle id, schema, inputs, and source SHA-256; the exact executable and
  arguments; the target root, Git revision, fingerprint budget, and a
  before/after content fingerprint of every tracked and untracked, not-ignored
  path, with the count and the first 32 paths that differ; the profile document
  and its SHA-256; start and finish times; exit status; the output policy,
  withheld lines, and redaction count; the parsed oracle report; a cleanup
  verdict; a completeness state; and an outcome.
- **States and outcomes.** Completeness is one of `complete`,
  `empty_selection`, `unsupported_source`, `truncated`, or
  `infrastructure_failure`, with a closed reason per state. Only `complete` is
  a clean run. The outcome uses the shared vocabulary: `changed`/`increased`
  map to `confirmed`, `unchanged`/`decreased` to `not_reproduced`,
  `inconclusive` and an oracle `operational_failure` to `not_observed`.
  `unsupported_source` and `empty_selection` are `not_observed`, and an
  `infrastructure_failure` run has outcome `infrastructure_failure`. No result
  line, a repeated, oversized, or malformed line, a report that is not the
  named oracle's exact shape, a context that does not echo the run's context, a
  missing runner marker, a failing selected test, a deadline, uncertain process
  cleanup, an exhausted fingerprint budget, or a changed target fingerprint is
  an infrastructure failure. The runner never emits `contract_disproved`: an
  oracle observation cannot show that code meets its contract. Exit statuses
  are `0`, `2`, and `6` for a complete run with outcome `not_reproduced`,
  `confirmed`, and `not_observed`; `3`, `4`, `5`, and `70` for the other
  states; and `64` for invalid input, which creates no run directory.
- **Coherent, bound records only.** The live run and the v1 decoder accept an
  oracle report only when it has the named oracle's exact shape, its statuses
  follow that artifact's own comparison rules (an observed, present key
  without comparable fingerprints is `inconclusive`, never `changed`), it
  echoes the run's context, and it observed exactly the requested
  application and key or ordered key list, or the requested event path;
  otherwise the run is `result_line_invalid`, `context_mismatch`, or
  `result_identity_mismatch`. A `complete` or `truncated` record must also show
  an exit status of 0, a nonempty, failure-free suite, runtime markers, an
  unchanged fingerprint, process cleanup, and an outcome equal to the mapping
  of the report's status, and its command must agree with that report: a
  resolved executable for the profile's first element, `cwd` equal to the
  target root, a valid nonempty selection, and arguments equal to the profile
  prefix followed by `test` and the selection. Every record's nested profile
  must pass profile validation, and its oracle inputs must use exactly the
  named oracle's selectors, with no conflicting pair, and equal the oracle
  variables in the recorded child environment. That environment's `set` must
  be exactly the runner's assignments (`MIX_ENV=test`, `MIX_EXS`, overlay, and
  oracle paths under one run directory, the target root's `mix.exs`, and the
  profile's alias mode), the oracle inputs, and the profile's database suffix;
  its passthrough lists must be unique, disjoint, in profile order, and
  together exactly the profile's declared names; and `inherited` must be a
  subset of `HOME` and `PATH`. The command deadline takes
  precedence over output or an exit status already queued when it passes.

## Why

The appended-helper procedure is the only documented installation point, so
the overlay reproduces it exactly instead of inventing a new capture boundary.
Alternatives were rejected:

- `mix run --no-start <driver>` (this record's first draft): Mix dispatches a
  host `run` alias before the driver can inspect it, so the alias body runs
  and may write into the target. Refusing after the fact does not preserve the
  no-mutation invariant.
- Requiring the oracle before `Mix.Task.run("test")` captures before the host
  application starts and before the helper's baseline configuration.
- Passing the oracle as a test file loads it concurrently with the selected
  tests, so the initial capture would race test-file loading.
- An overlay `mix.exs` that defines its own project would become the
  project file and, being newer than the build manifest, recompile a shared
  target's `_build`. The bootstrap defines no project: `use Mix.Project` in the
  target's compiled `mix.exs` pushes the target's own file, so the build is
  reused (checked on Elixir 1.17.3/OTP 27 and 1.20.3/OTP 29 by manifest mtime).
- Starting a new BEAM with `elixir -r` runs before Mix configures the project.
- Placing the overlay last in `:test_paths` fails on Elixir 1.19 and later,
  whose test task stops requiring helpers after the first helper that emits a
  warning. Placing it first and requiring the host helpers from the overlay
  keeps the host's order and diagnostics on every supported Elixir.
- Saving the raw output, even with exact-value redaction, as the default: a
  test can print a passthrough value in a transformed form that no redactor
  matches, so only an allowlist is fail-closed.

`MIX_EXS` is a documented Mix variable. The two Mix functions are internal.
They exist unchanged in Elixir 1.17 through 1.20 and the integration tests
exercise them on the CI matrix; the bootstrap checks for them and refuses
rather than guessing. The earlier hand-run procedure already relied on the
same alias bypass.

A host profile, rather than inference, keeps credentials, database names, and
setup commands with the operator who owns them. The profile is trusted
operator configuration: its `mix_command` is executed. It stores names, not
secret values, so it can be reviewed and fingerprinted.

## Consequences

- An agent can run the documented oracles against a shared checkout without
  touching it and keep a self-describing record of each run. The record is
  evidence about one bounded run; it still does not establish causality, and a
  caller-supplied `--context` remains unverified and must not carry secrets.
- The default output keeps summaries only. A failing run's diagnostics need
  `--output-policy redacted`, whose limitation is recorded: it removes exact
  passthrough values, not encodings of them.
- The fingerprint covers paths Git does not ignore. Writes to ignored paths
  are outside it: Mix's `_build/`, and anything the host's own test
  configuration writes there (for example a JUnit formatter that writes a
  report under `cover/` on every run, as any `mix test` may).
  A concurrent edit by another agent makes the run an `infrastructure_failure`
  (`target_changed`); the record lists the changed paths but cannot say who
  changed them. Containment is checked before the run starts; a symlink
  swapped in afterwards is outside this boundary. Git lists a submodule or an
  untracked nested repository as one entry without its files, so a target
  containing one is refused as `unsupported_source`
  (`target_has_nested_repository`) rather than fingerprinted blind;
  fingerprinting submodule contents within the shared budgets is a later
  change. Likewise a path the fingerprint cannot read (a failed `lstat` or
  read, or a Git listing that exits 0 but reports on stderr that it could not
  open a directory) could hide a change behind it, so it is never fingerprinted
  as clean: before the run the target is `unsupported_source`, after it the run
  is `infrastructure_failure`, both with `target_path_unreadable`.
- Port children are their own process-group leaders. The runner terminates the
  group at the deadline and reaps descendants left in it after exit, but not
  descendants that start their own group. When the group cannot be inspected
  the run is an `infrastructure_failure`.
- A `mix_command` wrapper such as a version manager's `exec` may add
  environment variables the runner cannot see; the record says so in
  `limitations`.
- `insider.oracle-run/v1` and `insider.oracle-host-profile/v1` are versioned
  contracts with a committed fixture. A field change needs a new schema
  version. Running several oracles in one test VM, selecting tests for the
  agent, and retaining runs anywhere other than the caller's directory remain
  later decisions.
