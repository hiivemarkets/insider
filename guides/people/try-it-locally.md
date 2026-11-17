# Try it locally

Everything below runs on a development machine or CI host and touches nothing
outside the repository and the target checkout you point it at. Use a supported
Elixir/OTP pair: 1.17/27, 1.19/28, or 1.20/29. The maintainer-only analysis
tools need Elixir 1.18 or newer; `mix docs` is a `dev`-only dependency like them.

## Set up and run the quality gate

```sh
mix setup      # deps.get, then git config core.hooksPath .githooks
mix quality    # format, warnings-as-errors, full unit suite, prod compile,
               # production-artifact gate, Credo + ex_slop
```

`mix quality` compiles the root application in `test` and `prod`, runs the
unit suite, runs `scripts/verify-production-artifact` against the fresh prod
build, and finishes with strict Credo. `mix quality.deep` adds ex_dna and
Dialyzer. `mix test --cover` enforces the 90% coverage floor and writes
per-module reports to `cover/`.

Lab and Load are separate Mix projects that share the root lockfile:

```sh
(cd tools/insider_lab && mix deps.get --check-locked && mix test)
(cd tools/insider_load && mix deps.get --check-locked)
```

## Generate this documentation

```sh
mix docs           # writes doc/index.html for the root application and guides
(cd tools/insider_lab && mix docs)   # Lab-only API reference in tools/insider_lab/doc/
```

## Look for test-isolation candidates in another project

Compile Lab once, then point the inventory at a test tree. Compile first so
compilation output cannot land in the JSON you parse:

```sh
(cd tools/insider_lab && mix compile)
(cd tools/insider_lab && mix insider.candidates --root /path/to/project --path test)
```

The command prints one JSON object and exits `0` (complete scan, no
candidates), `2` (complete scan, candidates present), `3` (no `_test.exs` file
in the selection), `4` (a file could not be analyzed), `5` (a scan bound was
hit), `64` (invalid arguments), or `70` (inventory could not complete). Only
`0` means clean. A candidate is a static hint ranked by weighted signals such
as `async: false`, application-environment mutation without visible cleanup,
VM-global Telemetry handlers, OpenTelemetry global capture, and timer-based
synchronization. It is not a confirmed defect. The full contract is in
[`mix insider.candidates`](../agents/candidates-cli.md).

## Confirm a candidate with an oracle

Each candidate target may carry an `oracle` hint naming one of three fixed
artifacts in `tools/insider_lab/priv/oracles/`. To use one, add a single
`Code.require_file/1` line to the target project's `test/test_helper.exs`
after `ExUnit.start/1`, run exactly one selected test command with the named
environment variables, read the one `INSIDER_*_ORACLE=` line it prints, then
restore the helper to its exact prior contents. For example, for an
`application_env` target on `logger` / `default_handler`:

```sh
INSIDER_ORACLE_APPLICATION=logger \
INSIDER_ORACLE_KEY=default_handler \
mix test test/path/to/selected_test.exs
```

The report says whether the key was `changed`, `unchanged`, or `inconclusive`
between before-suite and after-suite captures, using per-run HMAC fingerprints
and never the configured value. A state change does not by itself establish
causality; the agent or engineer still owns that inference. Details, bounds,
and failure modes for all three artifacts are in [Oracles](../agents/oracles.md).

## Inspect a process in the same BEAM

```sh
(cd tools/insider_lab && mix insider capabilities)
(cd tools/insider_lab && mix insider inspect --name Elixir.MyApp.Supervisor)
```

`inspect` starts the current Mix project, resolves the registered name in the
same VM, and returns a bounded `process.describe` result: status, reductions,
memory, heap sizes, queue length, registered name, and current function. It
refuses textual PIDs because a PID copied from another BEAM can alias an
unrelated local process. In IEx the same operation is
`Insider.Runtime.describe(pid, [environment: :development], host_policy)`.

## Run the load harness

```sh
cd tools/insider_load
mix insider.load --profile config/load.json \
  --output ../../_build/insider_load/evidence/load
cd ../..
bash scripts/verify-load-evidence _build/insider_load/evidence/load
```

The harness compares a fixed-seed synthetic workload without and with a
collector session and writes a canonical `report.json`, `profile.json`, and
`manifest.json` to a new output directory. The verify script recomputes the
digests and identities offline and prints one JSON verdict line per
directory. Every report records `production_capacity=false` and
`budget_evaluation=not_approved`; these are development and CI measurements,
not budgets.

## Run the privacy corpus example

```sh
(cd tools/insider_lab && mix insider.privacy_corpus \
  --corpus priv/privacy_corpus/example.json --environment production)
```

The example corpus has fake values and exists to show the schema. The report
names which fields the production ingress profile would retain and where any
declared canary token surfaced; it never prints retained values. Exit `0` means
no declared canary appeared in projected output; exit `2` means one did. A
clean exit is bounded evidence about the supplied items, not approval.
